-- ═══════════════════════════════════════════════════════════════
-- agent.subagent — subagent protocol support (Phase 3 split).
--
-- Verbatim move of the old agent.lua:
--   Section 3's SUBAGENT_* constants + wait_modem_message
--   Section 8's session family (session_path / load_session_history /
--   append_session_history / rebuild_session_history)
--
-- The old code referenced the WRITABLE_BASE local and the session
-- module's trim_history directly; here those come from agent.config
-- (writable_base) and agent.session (trim_history).
-- ═══════════════════════════════════════════════════════════════

local json = require("agent.json")
local fs = require("filesystem")
local config_mod = require("agent.config")
local session_mod = require("agent.session")

-- Subagent protocol constants (used by the subagent_call tool)
local SUBAGENT_LISTEN_PORT = 9090  -- subagent's task intake port
local SUBAGENT_REPLY_PORT = 9091   -- master's reply port
-- 默认任务超时（v0.3.104: 240→300s）: explorer 任务含多轮 chat（每轮
-- 30-60s）+ 多次工具调用（文件代理经 modem 往返），240s 完不成——
-- 真机 gist 三次 subagent_call 全 240s 超时（用户: "始终在执行，也没
-- 超时"——实为任务确实没跑完）。300s 给足 explorer 探索任务余量。
local SUBAGENT_TIMEOUT = 300       -- seconds to wait for a subagent reply
-- 文件服务端口（v0.3.84 新增，explorer 子代理读主代理硬盘）:
-- 主代理空闲时监听 FILE_PORT；explorer 子代理的 read_file/search_files
-- 通过 modem 代理到主代理执行，实现"内网读主代理文件"。
local FILE_PORT = 9092
local FILE_TIMEOUT = 60  -- 子代理等文件回复超时（主代理 chat 中时排队）
-- 文件服务回复最大字节（v0.3.92）: 无线 modem 最大包 8192B——超过则
-- modem.send 抛错（被 pcall 吞）→ 子代理等超时 → 显示空结果。回复前
-- 截断到安全长度 + truncated 标记（子代理侧可提示"结果已截断"）。
-- 留 512B 余量给 JSON 结构（{v,ok,content,truncated} + 转义膨胀）。
local FILE_REPLY_MAX = 8192 - 512

-- 文件代理: 子代理 explorer 用它把文件工具转发到主代理执行。
-- exec 签名与本地工具一致 (name, args, deps)。返回与本地工具同格式
-- （read_file → 文件内容字符串; 错误 → "Error: ..."）。
local function file_proxy(name, args, deps, master_addr)
  local ok_m, modem = pcall(function()
    local comp = require("component")
    return comp.modem
  end)
  if not ok_m or not modem then return "Error: file proxy: no modem component" end
  local req = {v = 1, op = name}
  if type(args) == "table" then
    for k, v in pairs(args) do req[k] = v end
  end
  local ok_open = pcall(modem.open, FILE_PORT)
  local ok_send = pcall(modem.send, master_addr, FILE_PORT, deps.json.encode(req))
  if not ok_send then return "Error: file proxy: send failed" end
  local sender, port, payload = deps.wait_modem_message(FILE_TIMEOUT, FILE_PORT)
  if not sender then return "Error: file proxy: no reply from master within " .. FILE_TIMEOUT .. "s" end
  local ok_d, reply = pcall(deps.json.decode, payload)
  if not ok_d or type(reply) ~= "table" then return "Error: file proxy: bad reply" end
  if reply.ok then
    -- 截断标记（v0.3.92）: 主代理侧回复超 modem 包长上限时已截断——
    -- 附标记让模型知道结果不完整（可缩小范围重试），避免误判"目录
    -- 就这样/文件就这些内容"。
    local content = reply.content or ""
    if reply.truncated then
      return content .. "\n[truncated: 结果超过 modem 包长上限, 已截断——缩小范围重试 (如 read_file 用 offset/limit)]"
    end
    return content
  end
  return "Error: " .. tostring(reply.error or "unknown")
end

-- 处理单条 modem 文件请求（推模式，TUI readInput 事件回调用）。
-- exec_fn 由 init.lua 注入（execute_tool 包装），签名 exec_fn(name, args_table)
-- 返回 (ok, result_string)。
local function handle_file_message(exec_fn, sender, port, payload)
  local ok_c, comp = pcall(require, "component")
  if not ok_c or not comp.modem then return false end
  local modem = comp.modem
  local json = require("agent.json")
  if port ~= FILE_PORT or type(payload) ~= "string" then return false end
  local ok_j, req = pcall(json.decode, payload)
  local reply
  if not ok_j or type(req) ~= "table" or not req.op then
    reply = json.encode({v = 1, ok = false, error = "bad file request"})
  else
    local op = req.op:match("^file:(.+)$") or req.op
    -- 只服务只读文件工具（安全边界: 文件服务绝不执行写工具）
    -- v0.3.124: list_directory/glob 工具已删，代理 op 同步缩减
    if op == "read_file" or op == "search_files" then
      local args = {}
      for k, v in pairs(req) do
        if k ~= "v" and k ~= "op" then args[k] = v end
      end
      local ok_exec, result = exec_fn(op, args)
      if ok_exec and type(result) == "string" then
        -- 包长保护（v0.3.92）: 无线 modem 最大包 8192B——list_directory /
        -- 大目录/read_file 大文件结果超限时 modem.send 抛错被 pcall 吞
        -- → 子代理等 60s 超时。回复前截断到安全长度 + 标记。
        local content = result
        local truncated = false
        if #content > FILE_REPLY_MAX then
          content = content:sub(1, FILE_REPLY_MAX)
          truncated = true
        end
        reply = json.encode({v = 1, ok = true, content = content, truncated = truncated})
      else
        reply = json.encode({v = 1, ok = false, error = tostring(result)})
      end
    else
      reply = json.encode({v = 1, ok = false, error = "op not allowed: " .. tostring(op)})
    end
  end
  pcall(modem.send, sender, FILE_PORT, reply)
  return true
end

-- 主代理侧文件服务: 非阻塞处理所有 pending 文件请求（event.pull 0s 轮询，
-- 在 REPL/TUI 空闲时调用；chat 阻塞期间请求排队，恢复空闲后处理）。
local function serve_file_requests(exec_fn)
  local ok_e, event = pcall(require, "event")
  local ok_c, comp = pcall(require, "component")
  if not ok_e or not ok_c or not comp.modem then return end
  while true do
    local sig = {event.pull(0, "modem_message")}
    if not sig[1] then break end
    handle_file_message(exec_fn, sig[3], sig[4], sig[6])
  end
end

-- Wait for a modem_message event (with timeout). Returns
-- (sender, port, arg1) or nil on timeout. Uses event.pull which yields.
-- on_other（v0.3.85）: 非 reply_port 的 modem 消息转发给回调（完整 sig
-- 表）——主代理 subagent_call 等待回复期间，explorer 子代理的文件服务
-- 请求经它处理。不转发就丢弃（event.pull 消费即失），形成死锁: 子代理
-- 等文件回复 60s，主代理等任务回复 240s，互相等待直到超时（真机 gist
-- 现场: explorer 子代理执行 list_directory/read_file 卡 thinking）。
-- v0.3.86: interrupted 事件（Ctrl+C）设中断标志提前返回——返回 nil
-- 前清除标志; 调用方（subagent_call）把 nil + 中断转成 "interrupted"
-- 错误，用户可 Ctrl+C 终止 subagent_call 等待。
local function wait_modem_message(timeout, reply_port, on_other)
  local event = require("event")
  local interrupt = require("agent.interrupt")
  -- 超时基准（v0.3.104 修复）: 原实现用 waited 累计（每轮 +step），
  -- 非目标事件到达时 event.pull 立即返回但 waited 仍 +0.5——事件稀疏
  -- 时 waited 落后真实时间 → 实际超时 >> 配置值（用户实证 subagent_call
  -- 240s 配置但"始终在执行，也没超时"）。改用 computer.uptime()
  -- deadline（与 OpenOS event.pullFiltered 同基准）——事件到达不重置
  -- deadline，真实墙钟超时准时生效。uptime 不可用时回退 waited 累计。
  local ok_c, comp = pcall(require, "computer")
  local use_uptime = ok_c and comp and comp.uptime ~= nil
  local deadline = use_uptime and (comp.uptime() + (timeout or math.huge)) or nil
  local waited = 0
  local step = 0.5
  while timeout == nil
      or (use_uptime and comp.uptime() < deadline)
      or (not use_uptime and waited < timeout) do
    -- 无过滤 pull + 自判事件名（v0.3.89 修复）: OpenOS event.pull 的
    -- 多过滤语义是"事件名 match 参数1 且 参数N 匹配事件第 N 参数"（AND
    -- 位置匹配），不是匹配多个事件名——("modem_message","interrupted")
    -- 要求事件名含 modem_message 且参数1=="interrupted"，interrupted
    -- 事件（{"interrupted", <time>}）永远被拒，Ctrl+C 在此失效
    -- （probe_pullmulti 实证）。改无过滤 pull，非目标事件忽略重拉。
    local sig = {event.pull(step)}
    if sig[1] == "modem_message" then
      local sender = sig[3]
      local port = sig[4]
      -- sig[2] is receiver address, sig[3] sender, sig[4] port
      if reply_port == nil or port == reply_port then
        return sender, port, sig[6]
      end
      if on_other then
        on_other(sig)
      end
    elseif sig[1] == "interrupted" then
      interrupt.set()
      return nil
    end
    waited = waited + step
  end
  return nil
end

-- Subagent sessions: each subagent keeps per-session append-only histories
-- on its own disk (<writable>/subagent_sessions/<session>/history.jsonl).
-- Reusing the same session id continues the conversation; omitting it
-- starts fresh.

local function session_path(session)
  local safe = tostring(session):gsub("[^%w_%-]", "_"):sub(1, 64)
  return config_mod.writable_base .. "/subagent_sessions/" .. safe .. "/history.jsonl"
end

-- Load session history (JSONL lines, same format as main history).
local function load_session_history(session)
  local p = session_path(session)
  local fs = require("filesystem")
  if not fs.exists(p) then return {} end
  local f = io.open(p, "r")
  if not f then return {} end
  local content = f:read("*a")
  f:close()
  local messages = {}
  for line in content:gmatch("[^\r\n]+") do
    local ok2, msg = pcall(json.decode, line)
    if ok2 and type(msg) == "table" and msg.role then
      messages[#messages + 1] = msg
    end
  end
  return session_mod.trim_history(messages)
end

-- Append one message to a session history.
local function append_session_history(session, msg)
  local p = session_path(session)
  local fs = require("filesystem")
  local dir = p:match("^(.*)/[^/]+$")
  if dir then pcall(fs.makeDirectory, dir) end
  local f = io.open(p, "a")
  if not f then return end
  f:write(json.encode(msg), "\n")
  f:close()
end

-- Rebuild a session history (after compaction/trim).
local function rebuild_session_history(session, messages)
  local p = session_path(session)
  local fs = require("filesystem")
  local dir = p:match("^(.*)/[^/]+$")
  if dir then pcall(fs.makeDirectory, dir) end
  local f = io.open(p, "w")
  if not f then return end
  for _, m in ipairs(messages) do
    f:write(json.encode(m), "\n")
  end
  f:close()
end

return {
  wait_modem_message = wait_modem_message,
  session_path = session_path,
  load_session_history = load_session_history,
  append_session_history = append_session_history,
  rebuild_session_history = rebuild_session_history,
  file_proxy = file_proxy,
  serve_file_requests = serve_file_requests,
  handle_file_message = handle_file_message,
  SUBAGENT_LISTEN_PORT = SUBAGENT_LISTEN_PORT,
  SUBAGENT_REPLY_PORT = SUBAGENT_REPLY_PORT,
  SUBAGENT_TIMEOUT = SUBAGENT_TIMEOUT,
  FILE_PORT = FILE_PORT,
  FILE_TIMEOUT = FILE_TIMEOUT,
}
