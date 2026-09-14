-- v5shim.lua — 让 v5 时代的探针脚本在 v6-only 远控栈上照常工作
--
-- 背景: 2026-09-14 v5 一次性协议(端口 8001)整体退役, 真机 /home 上遗留了
--   13 个自研探针脚本(scan/dirt*/cln*/verify*/e2e/pr/probe_run/big2/placedirt)。
--   它们的"样板层"直连 modem 打 8001 —— 该端口已无人监听, 且它们的
--   deadline 用 os.clock()(挂起期间不推进, 永不触发)。两处都会挂死。
--
--   这些脚本的业务逻辑(探测机器人物品栏/放置泥土/校验文件)本身没问题,
--   坏掉的只是样板层。本 shim 只替换样板层: 业务逻辑里的 cmd("op|args")
--   调用原样保留, 由本文件翻译成 v6 调用, 并把结果还原成 v5 的
--   "ok|<data>" / "err|<msg>" 字符串格式 —— 脚本的解析代码无需改动。
--
-- 用法: 把脚本头部的样板(v5 样板层)替换为一行:
--     local cmd = dofile("/home/v5shim.lua")
--   然后 cmd("ping") / cmd("exec|ls /tmp", 15) / cmd("write|/p|" .. encoded)
--   等调用全部照旧可用。
--
-- 支持的 op(与 v5.2.2 语义逐条对齐, 依据 remote_debug.lua @b36fdf70):
--   ping            -> "ok|pong"
--   info            -> "ok|id=..|uptime=..|freeMem=..|totalMem=..|components=..|pd=.."
--   exec|<cmd>      -> "ok|<output of cmd>"; 空输出 -> "ok|(no output)";
--                      失败 -> "err|exec failed: <err> | output: <captured>"
--   read|<path>     -> "ok|<content>"; 空文件 -> "ok|(empty file)";
--                      打不开 -> "err|cannot open <path>"
--   write|<path>|<escaped> -> "ok|remote: <n> bytes written to <path>"
--                      解码失败 -> "err|decode failed: <err>"
--                      打不开 -> "err|cannot open <path> for write"
--   delete|<path>   -> "ok|remote: deleted <path>" / "err|cannot delete .."
--   未知 op         -> "err|unknown op: <op>"
--
-- 与 v5 的差异(刻意):
--   1. 不做 7680B 截断 —— v6 流式读取无此上限, 大文件现在能完整读回。
--      (v5 旧行为: 超长回复截断并附 "...[TRUNCATED]"。依赖截断的脚本
--       本来就是在处理"读不全"的降级路径, 现在会拿到完整内容。)
--   2. exec 不经 shell 重定向到 /home/exec_out_* 临时文件 —— v6 自己流式
--      捕获 stdout/stderr。旧临时文件不再产生(也不再泄漏)。
--   3. exec 失败时仍附已捕获输出(对齐 v5.2.2 的 "| output: ..." 行为)。
--
-- 计时: 一律 computer.uptime()(墙钟)。绝不用 os.clock —— 线程挂在
--   event.pull 里时 CPU 时间不推进, deadline 永不触发(本次事故根因)。

local remote_lib = "/home/remote_client.lua"
local DEFAULT_PORT = 8100

local M = {}

-- 连接惰性建立并复用(一个脚本内多次 cmd 共用一个 v6 会话)
local _h, _conn_err

local function get_handle()
  if _h then return _h end
  if _conn_err then return nil, _conn_err end
  local ok, remote = pcall(dofile, remote_lib)
  if not ok then
    _conn_err = "cannot load " .. remote_lib .. ": " .. tostring(remote)
    return nil, _conn_err
  end
  -- 远端地址/端口: 允许脚本用环境变量覆盖, 默认 = 机器人 + 8100
  local addr = os.getenv and os.getenv("REMOTE_ADDR") or nil
  local modem = os.getenv and os.getenv("REMOTE_MODEM") or nil
  addr = addr or "84f13777-676d-4c8d-b608-6f5f1346b602"
  local opts = {port = tonumber(os.getenv and os.getenv("REMOTE_PORT") or "") or DEFAULT_PORT}
  if modem and modem ~= "" then opts.modem = modem end
  local h, err = remote.connect(addr, opts)
  if not h then
    _conn_err = err
    return nil, err
  end
  _h = h
  return _h
end

-- v6 的 exec 返回 {ok, code, out, stderr}; 还原 v5 的字符串语义
local function do_exec(cmd, timeout)
  local h, err = get_handle()
  if not h then return "err|" .. tostring(err) end
  local r = h:exec(cmd, timeout)
  if r == nil then return "err|exec failed: no result (timeout?)" end
  local combined = r.out or ""
  if r.stderr and r.stderr ~= "" then
    combined = (combined ~= "" and (combined .. "\n") or "") .. r.stderr
  end
  if r.ok then
    if combined == "" then return "ok|(no output)" end
    return "ok|" .. combined
  end
  -- 失败: 附已捕获输出(对齐 v5.2.2 的 "err|exec failed: <err> | output: <out>")
  -- 注意: v6 客户端返回的 err 自身可能已带 "exec failed: ..." 前缀,
  -- 直接拼接会得到 "exec failed: exec failed: nil" —— 去重。
  local reason = tostring(r.err or r.code or "nil")
  reason = reason:gsub("^exec failed:%s*", "")
  return "err|exec failed: " .. reason
    .. (combined ~= "" and (" | output: " .. combined) or "")
end

local function do_read(path)
  local h, err = get_handle()
  if not h then return "err|" .. tostring(err) end
  local r = h:read(path)
  if not r or not r.ok then
    return "err|cannot open " .. tostring(path)
  end
  local content = r.content or ""
  if content == "" then return "ok|(empty file)" end
  return "ok|" .. content
end

local function do_write(path, escaped)
  local serialization = require("serialization")
  local ok, content = pcall(function()
    local unesc = escaped:gsub("\\|", "\001"):gsub("\\\\", "\\"):gsub("\001", "|")
    return serialization.unserialize(unesc)
  end)
  if not ok or type(content) ~= "string" then
    return "err|decode failed: " .. tostring(content)
  end
  local h, err = get_handle()
  if not h then return "err|" .. tostring(err) end
  local w = h:write(path, content)
  if not w or not w.ok then
    return "err|cannot open " .. tostring(path) .. " for write"
  end
  return "ok|remote: " .. #content .. " bytes written to " .. path
end

local function do_delete(path)
  local h, err = get_handle()
  if not h then return "err|" .. tostring(err) end
  local d = h:delete(path)
  if d and d.ok then
    return "ok|remote: deleted " .. tostring(path)
  end
  return "err|cannot delete " .. tostring(path) .. ": " .. tostring(d and d.err or "unknown")
end

local function do_info()
  local h, err = get_handle()
  if not h then return "err|" .. tostring(err) end
  local i = h:info()
  if not i or not i.ok then return "err|info failed" end
  return "ok|" .. tostring(i.info or "")
end

-- cmd("op|arg1|arg2", timeout) —— v5 调用形状原样保留
function M.run(req, timeout)
  if type(req) ~= "string" then return "err|bad request" end
  local op, rest = req:match("^([^|]*)|?(.*)$")
  op = op or req
  timeout = timeout or 20

  if op == "ping" then
    local h = get_handle()
    if not h then return "err|" .. tostring(_conn_err) end
    local p = h:ping()
    if p and p.ok then return "ok|pong" end
    return "err|ping failed"
  elseif op == "info" then
    return do_info()
  elseif op == "exec" then
    return do_exec(rest, timeout)
  elseif op == "read" then
    return do_read(rest)
  elseif op == "write" then
    local path, escaped = rest:match("^([^|]*)|(.*)$")
    if not path then return "err|decode failed: malformed write" end
    return do_write(path, escaped)
  elseif op == "delete" then
    return do_delete(rest)
  end
  return "err|unknown op: " .. tostring(op)
end

-- 兼容旧脚本可能的 require 形态
M.connect = get_handle
M.close = function()
  if _h then pcall(_h.close, _h) end
  _h, _conn_err = nil, nil
end
-- 便于诊断: shim.version 让调用方确认走的是新栈
M.version = "v5shim/1.0 (v6-only backend, port " .. DEFAULT_PORT .. ")"
M.run = M.run

-- 返回 callable 表: 旧脚本写 `local cmd = dofile("/home/v5shim.lua")` 后直接
-- cmd("...") 调用。Lua 的函数值不能挂字段, 故用 __call 元表包一层,
-- 同时把辅助面挂在表上 (cmd.close() / cmd.version)。
return setmetatable(M, {__call = function(_, req, timeout) return M.run(req, timeout) end})
