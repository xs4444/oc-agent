-- ═══════════════════════════════════════════════════════════════
-- remote_client.lua v1.2 — 主控侧远控客户端库（仅 v6 协议）
--
-- 服务器:
--   - remote_host v6.0 (消息 ID 多路复用, 流式 exec, 分块读写, cancel)
--   默认端口 8100 (opts.port 可覆盖)。
--   连接即探测: connect() 发探针 "v6|1|ping|"——回复以 "v6|" 开头 → v6 模式;
--   以 ok|/err| 开头 → 对端是已退役的 v5 守护 (v5 支持已移除, 需升级对端);
--   无回复 → 连接即失败 (REMOTE_OFFLINE)。
--
-- 用法 (主控机, 文件放 /home/remote_client.lua):
--   local remote = dofile("/home/remote_client.lua")
--   local h, err = remote.connect("84f13777-...",
--                     {modem = "3272384f-...", port = 8100})
--   if not h then error(err) end
--   local r = h:exec("lua /home/probe.lua", 120)
--   if r.offline then print("远端离线（没电?超距?）")
--   elseif not r.ok then print("执行失败: " .. r.err)
--   else print(r.out) end
--   h:close()
--
-- v6 特性 (调用方 API):
--   - exec: out/err 真流分离 (r.out=stdout, r.stderr=stderr); 无截断
--     (truncated 恒 false); 命令含管道 '|' 恒放行 (payload 转义承载)
--   - read: 分块重组, 文件 ≤1MB
--   - write: 分块传输, content ≤1MB
--   - cancel(id): 杀远端指定 id 的 exec
--
-- 硬规则 (docs/REMOTE_PROTOCOL.md §8 实证坑清单):
--   1. 所有 deadline 用 computer.uptime() (墙钟)。os.clock 是 CPU 时间,
--      等回复时线程挂起 → deadline 永不触发 (c110 事故)。
--   2. 无回复 = 主机可能没电/超距 → 显式 offline=true (绝不返回 nil)。
--   3. modem 单包 8192B: v6 块 ≤7000B。
--   4. opts.keepalive=true 起后台心跳线程 (10s ping, 3 连失 → _alive=false)
--      —— 它从机器事件队列拉事件, 会"偷"宿主脚本的事件: 主控机自身跑
--      事件循环 (如 agent) 时保持默认 false, 自己定期 h:ping() 探测。
--
-- 结果形状 (全部 table, ok 字段必有):
--   {ok=true, ...}            成功
--   {ok=false, err=...}       失败 (含服务器 err 信封)
--   {ok=false, offline=true, err="REMOTE_OFFLINE (...)"}  超时无回复
-- ═══════════════════════════════════════════════════════════════

local M = {}
local M_h = {}  -- handle 方法表（__index）

local V6_CHUNK = 7000           -- v6 单帧载荷 (modem 8192B 单包 - 信封余量)
local V6_WRITE_MAX = 1048576    -- v6 单文件上限 (对齐服务器 MAX_WRITE_SIZE)
local KEEPALIVE_INTERVAL = 10   -- s, 后台心跳周期
local KEEPALIVE_MAX_MISSES = 3  -- 连续失帧 → _alive=false

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

-- 统一把超时映射为对外的结果 table（规则 2: offline 显式）
local function offline_result(timeout)
  return {
    ok = false,
    offline = true,
    err = "REMOTE_OFFLINE (no reply within " .. tostring(timeout)
      .. "s — host may be powered off / out of modem range)",
  }
end

-- ── v6 协议层 (remote_host v6.0) ─────────────────────────────
-- 信封: v6|<id>|<op>|<rest>; rest = "status|payload...";
-- payload 内 '|' 转义为 '\|' (先 \\ 后 \|)。

local function v6_escape(s)
  return (s:gsub("\\", "\\\\"):gsub("|", "\\|"))
end
local function v6_unescape(s)
  return (s:gsub("\\|", "\001"):gsub("\\\\", "\\"):gsub("\001", "|"))
end

-- 前 3 个未转义 '|' 切信封 → {v6, id, op, rest} (rest 可含转义 '|')
local function v6_split_envelope(s)
  local parts, cur = {}, {}
  local i, n, splits = 1, #s, 0
  while i <= n do
    local ch = s:sub(i, i)
    if ch == "\\" and i < n and s:sub(i + 1, i + 1) == "|" then
      cur[#cur + 1] = ch
      cur[#cur + 1] = s:sub(i + 1, i + 1)
      i = i + 2
    elseif ch == "|" and splits < 3 then
      parts[#parts + 1] = table.concat(cur)
      cur = {}
      splits = splits + 1
      i = i + 1
    else
      cur[#cur + 1] = ch
      i = i + 1
    end
  end
  parts[#parts + 1] = table.concat(cur)
  return parts
end

-- 切第一个未转义 '|' → (a, b|nil)
local function v6_split_first(s)
  local i, n = 1, #s
  while i <= n do
    local ch = s:sub(i, i)
    if ch == "\\" then
      i = i + 2
    elseif ch == "|" then
      return s:sub(1, i - 1), s:sub(i + 1)
    else
      i = i + 1
    end
  end
  return s, nil
end

-- 解析一帧 v6 回复 → {id, op, status, payload} | nil
local function v6_parse_frame(data)
  if type(data) ~= "string" or data:sub(1, 3) ~= "v6|" then
    return nil
  end
  local parts = v6_split_envelope(data)
  if parts[1] ~= "v6" then
    return nil
  end
  local rest = parts[4] or ""
  local status, payload = v6_split_first(rest)
  return {
    id = tonumber(parts[2]) or parts[2],
    op = parts[3] or "",
    status = status or "ok",
    payload = payload or "",
  }
end

local function v6_send(h, req)
  local comp = require("component")
  return pcall(comp.invoke, h.modem, "send", h.addr, h.port, req)
end

local function v6_next_id(h)
  h._id = (h._id or 1) + 1
  return h._id
end

-- 等本 op 的帧。terminal_op 帧 (或 err 拒绝帧) → 返回; 中间帧 (chunk) →
-- 交给 on_frame。其他 id 的滞留旧帧自动忽略 (消息 ID 多路复用, 自排空)。
local function v6_wait(h, my_id, timeout, terminal_op, on_frame)
  local event = require("event")
  local computer = require("computer")
  local deadline = computer.uptime() + timeout
  while computer.uptime() < deadline do
    local sig = { event.pull(0.25) }
    if sig[1] == "modem_message" and sig[3] == h.addr and sig[4] == h.port then
      local frame = v6_parse_frame(sig[6])
      if frame and frame.id == my_id then
        local is_chunk = frame.op == "exec_chunk" or frame.op == "file_chunk"
        if frame.op == terminal_op or (frame.status == "err" and not is_chunk) then
          h._alive = true
          return frame
        end
        if on_frame and is_chunk then
          on_frame(frame)
        end
      end
    end
  end
  return nil
end

-- 协议探测: 发 "v6|1|ping|" 并等任意回复 (墙钟 deadline)。
-- 返回 (reply_string | nil)。nil = 无回复 (离线)。
local function probe_protocol(h)
  local comp = require("component")
  local event = require("event")
  local computer = require("computer")
  local ok_send, send_err = pcall(comp.invoke, h.modem, "send", h.addr, h.port, "v6|1|ping|")
  if not ok_send then
    return nil, "send failed: " .. tostring(send_err)
  end
  local deadline = computer.uptime() + h.probe_timeout
  while computer.uptime() < deadline do
    local sig = { event.pull(0.25) }
    if sig[1] == "modem_message" and sig[3] == h.addr and sig[4] == h.port then
      return sig[6]
    end
  end
  return nil
end

-- 后台心跳线程 (opts.keepalive=true)。10s 周期 ping, 连续 3 次无回复 →
-- _alive=false。op 在飞 (_inflight>0) 时跳过本轮: 避免抢帧。注意: 本线程
-- 从机器事件队列拉事件 (会"偷"宿主脚本的事件)——主控机自身跑事件循环时
-- 不要开, 自己定期 h:ping()。
local function start_keepalive(h)
  local thread = require("thread")
  local event = require("event")
  local computer = require("computer")
  local comp = require("component")
  thread.create(function()
    local misses = 0
    while not h.closed do
      local wake = computer.uptime() + KEEPALIVE_INTERVAL
      while not h.closed and computer.uptime() < wake do
        event.pull(0.5)
      end
      if h.closed then
        break
      end
      if h._inflight > 0 then
        -- op 在飞: 跳过本轮
      else
        local id = v6_next_id(h)
        pcall(comp.invoke, h.modem, "send", h.addr, h.port, string.format("v6|%d|ping|", id))
        local frame = v6_wait(h, id, h.ping_timeout, "pong")
        if frame and frame.status == "ok" then
          misses = 0
        else
          misses = misses + 1
        end
      end
      if misses >= KEEPALIVE_MAX_MISSES then
        h._alive = false
      end
    end
  end)
end

-- 连接远端 (打开本端 modem 端口，记住远端地址，协议探测)。
-- opts: {modem=<本端 modem 地址?>, port=8100, op_timeout=30, ping_timeout=5,
--        exec_timeout=120, probe_timeout=5, token=<v6 auth?>, keepalive=<bool?>}
-- v1.2 变化: 仅 v6 协议——无回复直接返回 nil,"REMOTE_OFFLINE (...)"。
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
  local port = opts.port or 8100
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
    exec_timeout = opts.exec_timeout or 120,
    probe_timeout = opts.probe_timeout or 5,
    _alive = nil,  -- 第一次有回复后 true; 超时后 false（实例字段遮蔽同名方法
    -- → 必须带下划线前缀，否则第一次 op 后 h:alive() 变成 call boolean）
    _id = 1,         -- v6 消息 id (探针用 1)
    _inflight = 0,   -- 在飞 v6 op 数 (keepalive 跳过判据)
    _authed = nil,
    closed = false,
  }
  setmetatable(h, { __index = M_h })

  -- 协议探测: "v6|1|ping|" → v6 服务器回 "v6|1|pong|ok"; v5 服务器把
  -- op 当 "v6" 回 "err|unknown op: v6"; 无回复 → 离线。
  local reply, why = probe_protocol(h)
  if why then
    return nil, why
  end
  if reply == nil then
    return nil, "REMOTE_OFFLINE (no reply to protocol probe within "
      .. tostring(h.probe_timeout) .. "s — host may be powered off / out of modem range)"
  end
  if type(reply) == "string" and reply:sub(1, 3) == "v6|" then
    h._alive = true
    if opts.token then
      -- v6.1 auth: 首帧 auth|<token>
      local id = v6_next_id(h)
      local ok_auth, err_auth = v6_send(h, string.format("v6|%d|auth|%s", id, v6_escape(opts.token)))
      if not ok_auth then
        return nil, "auth send failed: " .. tostring(err_auth)
      end
      local frame = v6_wait(h, id, h.ping_timeout, "auth")
      if not frame or frame.status ~= "ok" then
        return nil, "auth failed: " .. (frame and frame.payload or "no reply")
      end
      h._authed = true
    end
  else
    return nil, "protocol probe rejected (peer replied " .. tostring(reply):sub(1, 32)
      .. "): the peer is running the retired v5 daemon; v5 support was removed, upgrade the peer to remote_host v6.0 (port 8100)"
  end

  if opts.keepalive == true then
    start_keepalive(h)
  end
  return h
end

-- ping → {ok=true} | {ok=false, offline=true, err=...} | {ok=false, err=...}
-- (亦是"同步离线探测": 返回前完成一次墙钟 ping)
function M_h:ping()
  local id = v6_next_id(self)
  local ok, err = v6_send(self, string.format("v6|%d|ping|", id))
  if not ok then
    return { ok = false, err = "send failed: " .. tostring(err) }
  end
  local frame = v6_wait(self, id, self.ping_timeout, "pong")
  if not frame then
    self._alive = false
    return offline_result(self.ping_timeout)
  end
  if frame.status ~= "ok" then
    return { ok = false, err = frame.payload }
  end
  return { ok = true }
end

-- info → {ok=true, info="id=..|..|pd=<版本>", pd=<版本?>}
-- pd 字段: v6 服务器回 pd=6.0。缓存 self._pd。
function M_h:info()
  local id = v6_next_id(self)
  local ok, err = v6_send(self, string.format("v6|%d|info|", id))
  if not ok then
    return { ok = false, err = "send failed: " .. tostring(err) }
  end
  local frame = v6_wait(self, id, self.ping_timeout, "info")
  if not frame then
    self._alive = false
    return offline_result(self.ping_timeout)
  end
  if frame.status ~= "ok" then
    return { ok = false, err = frame.payload }
  end
  self._pd = frame.payload:match("pd=(%S+)")
  return { ok = true, info = frame.payload, pd = self._pd }
end

-- exec → {ok=true, code=0, out=..., stderr=..., truncated=false}
--       | {ok=false, code=1, err=..., out=..., stderr=...}   (服务器 err 信封)
--       | {ok=false, offline=true, err=...}                  (超时)
-- v6: out/err 真流分离, 管道恒放行。
function M_h:exec(cmd, timeout)
  if type(cmd) ~= "string" or cmd == "" then
    return { ok = false, err = "exec: cmd must be a non-empty string" }
  end
  if cmd:find("\n", 1, true) then
    return { ok = false, err = "exec: multi-line cmd not supported (single-line shell semantics)" }
  end
  local id = v6_next_id(self)
  local ok, err = v6_send(self, string.format("v6|%d|exec|%s", id, v6_escape(cmd)))
  if not ok then
    return { ok = false, err = "send failed: " .. tostring(err) }
  end
  self._inflight = self._inflight + 1
  local out_buf, err_buf = {}, {}
  local frame = v6_wait(self, id, timeout or self.exec_timeout, "exec_done",
    function(f)
      local tag, chunk = v6_split_first(f.payload)
      local data = v6_unescape(chunk or "")
      if tag == "out" then
        out_buf[#out_buf + 1] = data
      else
        err_buf[#err_buf + 1] = data
      end
    end)
  self._inflight = self._inflight - 1
  local out = table.concat(out_buf)
  local serr = table.concat(err_buf)
  if not frame then
    self._alive = false
    return offline_result(timeout or self.exec_timeout)
  end
  if frame.status == "ok" then
    return {
      ok = true, code = 0, out = out,
      stderr = serr ~= "" and serr or nil, truncated = false,
    }
  end
  -- 终帧 err: payload = "code=1|<escaped reason>" (或 "code=1")
  local code_s, reason_s = v6_split_first(frame.payload)
  local code = 1
  if code_s then
    local c = code_s:match("code=(%d+)")
    if c then code = tonumber(c) end
  end
  return {
    ok = false, code = code,
    err = reason_s and v6_unescape(reason_s) or frame.payload,
    out = out ~= "" and out or nil,
    stderr = serr ~= "" and serr or nil,
    truncated = false,
  }
end

-- read → {ok=true, content=..., size=n, truncated=false}
--        | {ok=false, err="cannot open <path>"} | offline
-- v6: 分块重组 ≤1MB。
function M_h:read(path, timeout)
  if type(path) ~= "string" or path == "" then
    return { ok = false, err = "read: path must be a non-empty string" }
  end
  local id = v6_next_id(self)
  local ok, err = v6_send(self, string.format("v6|%d|read|%s", id, v6_escape(path)))
  if not ok then
    return { ok = false, err = "send failed: " .. tostring(err) }
  end
  self._inflight = self._inflight + 1
  local buf = {}
  local frame = v6_wait(self, id, timeout or 60, "file_done",
    function(f)
      buf[#buf + 1] = v6_unescape(f.payload)
    end)
  self._inflight = self._inflight - 1
  if not frame then
    self._alive = false
    return offline_result(timeout or 60)
  end
  if frame.status ~= "ok" then
    return { ok = false, err = frame.payload }
  end
  local content = table.concat(buf)
  local size = tonumber(frame.payload:match("size=(%d+)")) or #content
  return { ok = true, content = content, size = size, truncated = false }
end

-- write → {ok=true, bytes=n} | {ok=false, err=...} | offline
-- v6: 分块传输 ≤1MB。
function M_h:write(path, content, timeout)
  if type(path) ~= "string" or path == "" then
    return { ok = false, err = "write: path must be a non-empty string" }
  end
  if type(content) ~= "string" then
    return { ok = false, err = "write: content must be a string" }
  end
  if #content > V6_WRITE_MAX then
    return { ok = false, err = "write: v6 supports ≤" .. V6_WRITE_MAX
      .. "B (1MB) per file" }
  end
  local id = v6_next_id(self)
  local ok, err = v6_send(self, string.format("v6|%d|write|%s|%d", id, v6_escape(path), #content))
  if not ok then
    return { ok = false, err = "send failed: " .. tostring(err) }
  end
  self._inflight = self._inflight + 1
  local start = v6_wait(self, id, 15, "write_start")
  if not start then
    self._inflight = self._inflight - 1
    self._alive = false
    return offline_result(15)
  end
  if start.status ~= "ok" then
    self._inflight = self._inflight - 1
    return { ok = false, err = start.payload }
  end
  -- 分块发送 (无逐块 ack, modem 可靠有序; 等 write_done 终帧)
  local pos, seq = 1, 0
  while pos <= #content do
    local piece = content:sub(pos, pos + V6_CHUNK - 1)
    local okc, errc = v6_send(self, string.format("v6|%d|write_chunk|%d|%s", id, seq, v6_escape(piece)))
    if not okc then
      self._inflight = self._inflight - 1
      return { ok = false, err = "write send failed: " .. tostring(errc) }
    end
    pos = pos + #piece
    seq = seq + 1
  end
  local done = v6_wait(self, id, timeout or 300, "write_done")
  self._inflight = self._inflight - 1
  if not done then
    self._alive = false
    return offline_result(timeout or 300)
  end
  if done.status ~= "ok" then
    return { ok = false, err = done.payload }
  end
  local n = done.payload:match("remote: (%d+) bytes written to")
  return { ok = true, bytes = n and tonumber(n) or #content }
end

-- delete → {ok=true} | {ok=false, err=...} | offline
function M_h:delete(path, timeout)
  if type(path) ~= "string" or path == "" then
    return { ok = false, err = "delete: path must be a non-empty string" }
  end
  local id = v6_next_id(self)
  local ok, err = v6_send(self, string.format("v6|%d|delete|%s", id, v6_escape(path)))
  if not ok then
    return { ok = false, err = "send failed: " .. tostring(err) }
  end
  local frame = v6_wait(self, id, timeout or 15, "delete")
  if not frame then
    self._alive = false
    return offline_result(timeout or 15)
  end
  if frame.status ~= "ok" then
    return { ok = false, err = frame.payload }
  end
  return { ok = true }
end

-- cancel(target_id) → {ok=true, cancelled=id} | {ok=false, err=...} | offline
-- 杀远端指定 id 的 exec 工作线程 (服务器补发该 exec 的终帧)。
function M_h:cancel(target_id, timeout)
  local id = v6_next_id(self)
  local ok, err = v6_send(self, string.format("v6|%d|cancel|%s", id, tostring(target_id)))
  if not ok then
    return { ok = false, err = "send failed: " .. tostring(err) }
  end
  local frame = v6_wait(self, id, timeout or self.ping_timeout, "cancel")
  if not frame then
    self._alive = false
    return offline_result(timeout or self.ping_timeout)
  end
  if frame.status ~= "ok" then
    return { ok = false, err = frame.payload }
  end
  return { ok = true, cancelled = target_id }
end

-- 最近一次操作后主机是否在线（nil=尚无回复记录）
function M_h:alive()
  return self._alive
end

-- 关闭（关本端端口；keepalive 线程见 closed 自行退出）。幂等。
function M_h:close()
  if not self.closed then
    local comp = require("component")
    pcall(comp.invoke, self.modem, "close", self.port)
    self.closed = true
  end
end

-- ── v6 原始帧原语导出（测试/调试钩子; 正式代码请用公开方法）────────
-- e2e 的 cancel 测试需要"先发起长 exec 拿到 id, 再 cancel 该 id",
-- 公开 API 的 exec 是同步阻塞的, 故导出底层原语:
--   remote._v6.next_id(h)      → 下一个消息 id
--   remote._v6.send(h, req)    → (ok, err) 发一帧原始 v6 请求
--   remote._v6.wait(h, id, timeout, terminal_op, on_frame) → 帧 | nil
--   remote._v6.escape/unescape(s)
--   remote._v6.split_first(s)  → (a, b|nil) 切第一个未转义 '|'
M._v6 = {
  next_id = v6_next_id,
  send = v6_send,
  wait = v6_wait,
  escape = v6_escape,
  unescape = v6_unescape,
  parse_frame = v6_parse_frame,
  split_first = v6_split_first,
}

return M
