-- ═══════════════════════════════════════════════════════════════
-- remote_client.lua v1.0 — 主控侧远控客户端库（Phase 1）
--
-- 服务器: remote_debug v5.2（一次性 op|args → "ok|data" / "err|msg"，
--   REPLY_MAX=7680B 超长按 "...[TRUNCATED]" 截断）
--
-- 用法（主控机, 文件放 /home/remote_client.lua）:
--   local remote = dofile("/home/remote_client.lua")
--   local h, err = remote.connect("84f13777-676d-4c8d-b608-6f5f1346b602",
--                     {modem = "3272384f-0749-4530-8b60-73eaf963d3ed"})
--   if not h then error(err) end
--   local r = h:exec("lua /home/probe.lua", 120)
--   if r.offline then print("远端离线（没电?超距?）")
--   elseif not r.ok then print("执行失败: " .. r.err)
--   else print(r.out) end
--   h:close()
--
-- 硬规则（docs/REMOTE_PROTOCOL.md §8 实证坑清单）:
--   1. 所有 deadline 用 computer.uptime()（墙钟）。os.clock 是 CPU 时间，
--      等回复时线程挂起、CPU 时间不走 → deadline 永不触发（2026-09-14
--      c110 事故: 机器人没电 + os.clock deadline = 探测线程永久挂起）。
--   2. 无回复 = 主机可能没电/超距 → 显式 offline=true（绝不返回 nil 让
--      调用方猜）。
--   3. modem 单包 8192B: read/exec 回复由服务器截断（尾部 ...[TRUNCATED]）
--      → truncated=true; write 载荷 ≤6000B（转义膨胀后仍 <8192B）。
--   4. exec 命令不得含 '|'——v5.2 服务器用 split_unescaped 重切并只取
--      parts[2]，命令里第一个 '|' 之后的内容会静默丢失（shell 管道不可用）
--      → 显式报错，不静默截断。v5.2.1 服务器（取第一个 '|' 后原文）可解除。
--   5. path 不得含 '|'（同样会被服务器协议层切碎）。
--
-- 结果形状（全部是 table, ok 字段必有）:
--   {ok=true, ...}            成功
--   {ok=false, err=...}       失败（含服务器 err 信封）
--   {ok=false, offline=true, err="REMOTE_OFFLINE (...)"}  超时无回复
-- ═══════════════════════════════════════════════════════════════

local M = {}
local M_h = {}  -- handle 方法表（__index）

local TRUNC_MARK = "...[TRUNCATED]"
local WRITE_MAX = 6000  -- v5.2 一次性写上限（serialization+转义膨胀后 <8192B）

-- 找 modem 组件地址。opts.modem 指定则精确匹配（主控机可能有多 modem，
-- 机器人网络在哪个 modem 上以实测为准——真机: 3272384f-0749-4530-8b60-
-- 73eaf963d3ed）；缺省取第一个 modem。
local function find_modem(want_addr)
  local comp = require("component")
  for addr, ctype in comp.list() do
    if ctype == "modem" and (not want_addr or addr == want_addr) then
      return addr
    end
  end
  return nil
end

-- 等远端回复: event.pull 循环 + 墙钟 deadline（规则 1）
local function recv_reply(h, timeout)
  local event = require("event")
  local computer = require("computer")
  local deadline = computer.uptime() + timeout
  while computer.uptime() < deadline do
    local sig = { event.pull(0.25) }
    -- modem_message: sig[1]=事件名 sig[3]=远程地址 sig[4]=端口 sig[6]=数据
    if sig[1] == "modem_message" and sig[3] == h.addr and sig[4] == h.port then
      return sig[6]
    end
  end
  return nil
end

-- 排空迟到回复: 上一 op 超时（_stale）后，服务器可能只是"慢"而非离线——
-- 旧回复稍后到达会被下一个 op 的 recv_reply 误当成本 op 的回复（错配）。
-- ssh 用通道 ID 根治，v6 消息 ID 同理；Phase 1 一次性协议无 ID，发送前
-- 先排空 grace 秒内的滞留消息。残余风险: 迟到超过 grace 的旧回复仍会
-- 错配（v6 才彻底解决）。
local function drain_stale(h, grace)
  local event = require("event")
  local computer = require("computer")
  local deadline = computer.uptime() + (grace or 2)
  while computer.uptime() < deadline do
    local sig = { event.pull(0.1) }
    if sig[1] == "modem_message" and sig[3] == h.addr and sig[4] == h.port then
      -- 滞留的旧回复, 丢弃
    end
  end
  h._stale = false
end

-- 发一条 op 请求并等回复。返回 data | nil,"offline" | nil,其他错误
local function send_op(h, req, timeout)
  if h.closed then
    return nil, "handle closed"
  end
  if h._stale then
    drain_stale(h)
  end
  local comp = require("component")
  local ok_send, send_err = pcall(comp.invoke, h.modem, "send", h.addr, h.port, req)
  if not ok_send then
    return nil, "send failed: " .. tostring(send_err)
  end
  local data = recv_reply(h, timeout)
  if data == nil then
    h._alive = false
    h._stale = true
    return nil, "offline"
  end
  h._alive = true
  return data
end

-- 解析 v5.2 回复信封: "ok|data" / "err|msg"
local function parse_reply(data)
  local tag, payload = data:match("^(%a+)|(.*)$")
  if tag == "ok" then
    local truncated = payload:sub(-#TRUNC_MARK) == TRUNC_MARK
    return { ok = true, data = payload, truncated = truncated }
  elseif tag == "err" then
    return { ok = false, err = payload }
  end
  return { ok = false, err = "unrecognized reply: " .. tostring(data):sub(1, 80) }
end

-- 统一把 send_op 结果映射为对外的结果 table（规则 2: offline 显式）
local function op_result(h, req, timeout)
  local data, why = send_op(h, req, timeout)
  if why == "offline" then
    return {
      ok = false,
      offline = true,
      err = "REMOTE_OFFLINE (no reply within " .. tostring(timeout)
        .. "s — host may be powered off / out of modem range)",
    }
  end
  if why then
    return { ok = false, err = why }
  end
  return parse_reply(data)
end

local function check_path(path)
  if type(path) ~= "string" or path == "" then
    return "path must be a non-empty string"
  end
  if path:find("|", 1, true) then
    return "path contains '|' — would break the v5.2 protocol framing"
  end
  return nil
end

-- 连接远端（打开本端 modem 端口，记住远端地址）。
-- opts: {modem=<本端 modem 地址?>, port=8001, op_timeout=30, ping_timeout=5}
function M.connect(remote_addr, opts)
  if type(remote_addr) ~= "string" or remote_addr == "" then
    return nil, "remote_addr must be a non-empty string"
  end
  opts = opts or {}
  local modem_addr = find_modem(opts.modem)
  if not modem_addr then
    return nil, "remote_client: no modem component"
      .. (opts.modem and (" (wanted " .. tostring(opts.modem) .. ")") or "")
  end
  local port = opts.port or 8001
  local comp = require("component")
  local ok_open, err_open = pcall(comp.invoke, modem_addr, "open", port)
  if not ok_open then
    return nil, "remote_client: cannot open port " .. tostring(port) .. ": "
      .. tostring(err_open)
  end
  local h = {
    addr = remote_addr,
    port = port,
    modem = modem_addr,
    op_timeout = opts.op_timeout or 30,
    ping_timeout = opts.ping_timeout or 5,
    _alive = nil,  -- 第一次有回复后 true; 超时后 false（实例字段遮蔽同名方法
    -- → 必须带下划线前缀，否则第一次 op 后 h:alive() 变成 call boolean）
    _stale = false,  -- 上一 op 超时后为 true → 下一个 op 前先排空滞留旧回复
    closed = false,
  }
  setmetatable(h, { __index = M_h })
  return h
end

-- ping → {ok=true} | {ok=false, offline=true, err=...} | {ok=false, err=...}
function M_h:ping()
  local r = op_result(self, "ping", self.ping_timeout)
  if r.ok then
    return { ok = true }
  end
  return r
end

-- info → {ok=true, info="id=..|uptime=..|freeMem=..|totalMem=..|components=.."}
function M_h:info()
  local r = op_result(self, "info", self.ping_timeout)
  if r.ok then
    return { ok = true, info = r.data }
  end
  return r
end

-- exec → {ok=true, code=0, out=..., truncated=bool}
--       | {ok=false, code=1, err=...}          (服务器 err 信封)
--       | {ok=false, offline=true, err=...}    (超时)
function M_h:exec(cmd, timeout)
  if type(cmd) ~= "string" or cmd == "" then
    return { ok = false, err = "exec: cmd must be a non-empty string" }
  end
  if cmd:find("\n", 1, true) then
    return { ok = false, err = "exec: multi-line cmd not supported (single-line shell semantics)" }
  end
  if cmd:find("|", 1, true) then
    return { ok = false, err = "exec: command contains '|' — v5.2 server truncates at the first '|'"
      .. " (shell pipes lost); use v5.2.1 server or avoid pipes (docs/REMOTE_PROTOCOL.md §3)" }
  end
  local r = op_result(self, "exec|" .. cmd, timeout or self.op_timeout)
  if r.offline then
    return r
  end
  if not r.ok then
    r.code = 1
    return r
  end
  return { ok = true, code = 0, out = r.data, truncated = r.truncated }
end

-- read → {ok=true, content=..., size=n, truncated=bool}
--        | {ok=false, err="cannot open <path>"} | offline
function M_h:read(path, timeout)
  local perr = check_path(path)
  if perr then
    return { ok = false, err = "read: " .. perr }
  end
  local r = op_result(self, "read|" .. path, timeout or 15)
  if r.offline or r.err then
    return r
  end
  if r.data == "(empty file)" then
    return { ok = true, content = "", size = 0 }
  end
  return { ok = true, content = r.data, size = #r.data, truncated = r.truncated }
end

-- write → {ok=true, bytes=n} | {ok=false, err=...} | offline
-- v5.2 一次性写: content ≤6000B（serialization + \| 转义后仍 <8192B 单包）
function M_h:write(path, content, timeout)
  local perr = check_path(path)
  if perr then
    return { ok = false, err = "write: " .. perr }
  end
  if type(content) ~= "string" then
    return { ok = false, err = "write: content must be a string" }
  end
  if #content > WRITE_MAX then
    return { ok = false, err = "write: v5.2 one-shot write supports ≤" .. WRITE_MAX
      .. "B (modem 8192B packet limit); larger files → v6 chunked transfer (Phase 2)" }
  end
  local serialization = require("serialization")
  local ok_ser, enc = pcall(serialization.serialize, content)
  if not ok_ser then
    return { ok = false, err = "write: serialize failed: " .. tostring(enc) }
  end
  -- 与 remote_debug.lua write_file 的转义规则一致: 先 \\ 后 \|
  local escaped = enc:gsub("\\", "\\\\"):gsub("|", "\\|")
  local r = op_result(self, "write|" .. path .. "|" .. escaped, timeout or 15)
  if r.offline or r.err then
    return r
  end
  local n = r.data:match("remote: (%d+) bytes written to")
  return { ok = true, bytes = n and tonumber(n) or #content }
end

-- delete → {ok=true} | {ok=false, err=...} | offline
function M_h:delete(path, timeout)
  local perr = check_path(path)
  if perr then
    return { ok = false, err = "delete: " .. perr }
  end
  local r = op_result(self, "delete|" .. path, timeout or 15)
  if r.offline then
    return r
  end
  if not r.ok then
    return { ok = false, err = r.err }
  end
  return { ok = true }
end

-- 最近一次操作后主机是否在线（nil=尚无回复记录）
function M_h:alive()
  return self._alive
end

-- 关闭（关本端端口）。幂等。
function M_h:close()
  if not self.closed then
    local comp = require("component")
    pcall(comp.invoke, self.modem, "close", self.port)
    self.closed = true
  end
end

return M
