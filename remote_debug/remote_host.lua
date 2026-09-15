-- remote_host.lua v6.0 — v6 协议服务器 (Phase 2, 运行在远控机/机器人)
-- 配套客户端: remote_client.lua (主控侧, v6 自动探测)
-- 协议规范: docs/REMOTE_PROTOCOL.md §4
--
-- 协议代际: v5 一次性协议 (remote_debug.lua / 端口 8001) 已于 2026-09-14
--   整体退役 (它是本协议的严格子集, 且同机双守护会互抢事件) ——
--   本文件是当前唯一守护。以下为相对 v5 的能力差异 (历史记录):
--   - 消息 ID 多路复用: 信封 v6|<id>|<op>|<payload>, 每条回复回显 id,
--     多个 op 可同时在飞 (对照 ssh 通道 ID; session.c:2344)
--   - exec 流式: out/err 真流分离 (cmd > out 2> err), ≤7000B 分块
--     exec_chunk + 终帧 exec_done (对照 ssh: 流数据先于 exit-status 帧)
--   - read/write 分块: file_chunk/file_done, write_start/write_chunk/
--     write_done —— 大文件不再受 v5.2 一次性 6000B 限制
--   - cancel: 杀指定 id 的 exec 线程 + 清理临时文件 (对照 ssh signal
--     通道请求, session.c:2350)
--   - auth (v6.1): AUTH_TOKEN 非空时, 对端首帧必须 auth|<token>
--
-- 硬约束 (docs §2/§8 实证坑清单):
--   - modem 单包 8192B → 块载荷 ≤7000B (留信封余量)
--   - 1MB RAM → 并发文件传输 ≤4、并发 exec ≤4 (块逐块进出, 不整文件进内存)
--   - 全墙钟 computer.uptime() (os.clock 是 CPU 时间, 坑 #1)
--   - fs.remove or fs.delete 跨版本 (坑 #2); 本版本无 fs.move → 流式拷贝实现
--   - 纯文本 + 转义 (JSON 解析有 bug, 坑 #5); payload 内管道转义为 \|
--   - lua 脚本崩溃 ≠ shell.execute 失败 (坑 #12): exec_done code 只是
--     shell 层信号, 崩溃行在 out/err 流里

local component = require("component")
local event = require("event")
local thread = require("thread")
local computer = require("computer")

-- 墙钟辅助 (坑 #1: os.clock 是 CPU 时间)
local function computer_uptime() return computer.uptime() end
local function computer_address() return computer.address() end
local function computer_freeMemory() return computer.freeMemory() end
local function computer_totalMemory() return computer.totalMemory() end

local function find_modem()
  for addr, ctype in pairs(component.list()) do
    if ctype == "modem" then
      return addr
    end
  end
  return nil
end

local modemAddr = find_modem()
if not modemAddr then
  print("ERROR: no modem found")
  os.exit(1)
end

local PORT = 8100  -- v6 唯一守护端口 (v5/8001 已退役; 9090/9091/9092 = subagent)
component.invoke(modemAddr, "open", PORT)
local isWireless = component.invoke(modemAddr, "isWireless")

-- v6.1 auth: 对端首帧必须 auth|<token>; 空 = 关闭认证 (启动时打印告警)
local AUTH_TOKEN = ""

local CHUNK = 7000            -- 单帧载荷上限 (8192B 单包 - 信封余量)

-- ⚠ 二进制安全 (2026-09-15 实证修复): 所有 io.open 一律带 "b" (rb/wb/ab)。
--   OpenOS 的 buffer 按 mode.b 决定 f:read(n) 的 n 是**字节**还是**字符**
--   (lib/core/full_buffer.lua:134-143 readBytesOrChars: mode.b → rawlen/string.sub,
--    否则 unicode.len/unicode.sub)。文本模式下 f:read(7000) 读 7000 个*字符*,
--   含中文时单块可达 ~21KB > modem 8192B 单包 → 静默截断。
--   实测: 31500B 的中文文件 io.open(path,"r") 读回只剩 15962B (而机器上文件
--   完好, 机器人自校验 len=31500)。write 侧同理会劈开多字节字符 → U+FFFD。
--   这正是本文件自身的注释被写坏(─ e29480 → efbfbd, 等长替换, size 校验查不出)
--   的原因 —— 非 ASCII 内容经 v6 read/write 必损坏, 而本项目文件满是中文。
local MAX_TRANSFERS = 4       -- 并发文件传输 (write 在飞)
local MAX_EXECS = 4           -- 并发 exec
local WRITE_GAP_TIMEOUT = 120 -- s, write_chunk 间隙超时 (墙钟)
local MAX_WRITE_SIZE = 1048576  -- 单文件 1MB 上限 (流式落盘, RAM 无压力)

-- ── 转义 (与 v5.2 write / 客户端一致: 先 \\ 后 \|) ──────────────
local function escape(s)
  return (s:gsub("\\", "\\\\"):gsub("|", "\\|"))
end
local function unescape(s)
  return (s:gsub("\\|", "\001"):gsub("\\\\", "\\"):gsub("\001", "|"))
end

-- 信封切分: 前 3 个未转义 '|' 为 v6|id|op, 其余全部 = payload
-- (payload 内可含转义 '|' —— exec 管道 / write_chunk 内容)
local function split_envelope(s)
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
  return parts  -- {v6, id, op, payload}
end

-- payload 内再切第一个未转义 '|' (write: path|size; write_chunk: seq|data)
local function split_first_unescaped(s)
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

local function send_reply(sender, payload)
  if #payload > 8000 then
    payload = payload:sub(1, 8000)  -- 不应触发 (块 ≤7000B + 信封 < 8192B)
  end
  pcall(component.invoke, modemAddr, "send", sender, PORT, payload)
end

-- ── 状态 ─────────────────────────────────────────────────────────
local authenticated = {}  -- sender -> true (auth 开启时)
local running_exec = {}   -- sender..":"..id -> {thread, outpath, errpath}
local active_writes = {}  -- sender..":"..id -> {path, size, received, temp, last_wall, sender, id}

local function exec_count()
  local n = 0
  for _ in pairs(running_exec) do n = n + 1 end
  return n
end
local function write_count()
  local n = 0
  for _ in pairs(active_writes) do n = n + 1 end
  return n
end

local fs_remove
local function cleanup_file(path)
  if not fs_remove then
    local fs = require("filesystem")
    fs_remove = fs.remove or fs.delete
  end
  pcall(fs_remove, path)
end

-- 无 fs.move 的流式 move (块拷贝 + 删源, RAM 峰值 ~14KB)
local function move_file(src, dst)
  local inf = assert(io.open(src, "rb"))
  local outf = assert(io.open(dst, "wb"))
  while true do
    local chunk = inf:read(CHUNK)
    if not chunk then break end
    outf:write(chunk)
  end
  inf:close()
  outf:close()
  cleanup_file(src)
end

local function abort_write(key, w, reason)
  active_writes[key] = nil
  cleanup_file(w.temp)
  send_reply(w.sender, string.format("v6|%s|write_done|err|%s", w.id, escape(reason)))
end

-- 启动清理: 上次运行残留的 rh_* 临时文件 (所有在飞 op 随进程死亡)
local function startup_cleanup()
  local fs = require("filesystem")
  for name in fs.list("/home") do
    if name:sub(1, 3) == "rh_" then
      cleanup_file("/home/" .. name)
    end
  end
end

-- ── ops ──────────────────────────────────────────────────────────

-- exec: 工作线程跑 shell.execute (阻塞式), 完成后流式回传 out/err 两块
local function handle_exec(sender, id, payload)
  local cmd = unescape(payload or "")
  if cmd == "" then
    send_reply(sender, string.format("v6|%s|exec_done|err|exec: empty command", id))
    return
  end
  if exec_count() >= MAX_EXECS then
    send_reply(sender, string.format("v6|%s|exec_done|err|busy (max %d concurrent execs)", id, MAX_EXECS))
    return
  end
  local key = sender .. ":" .. id
  local outpath = "/home/rh_out_" .. sender .. "_" .. id
  local errpath = "/home/rh_err_" .. sender .. "_" .. id
  -- 先注册再 create: 若先 create, 快命令的工作线程可能在主线程写表前
  -- 完成并清表 → 主线程再写入表留下僵尸条目
  local entry = { outpath = outpath, errpath = errpath }
  running_exec[key] = entry
  local t = thread.create(function()
    local ok, res = pcall(function()
      local shell = require("shell")
      -- 真流分离 (2> 单独重定向 stderr; OpenOS sh 支持, full_sh.lua:42)
      local ok2, err2 = shell.execute(cmd .. " > " .. outpath .. " 2> " .. errpath)
      local function stream(path, tag)
        local f = io.open(path, "rb")
        if not f then return end
        while true do
          local chunk = f:read(CHUNK)
          if not chunk then break end
          send_reply(sender, string.format("v6|%s|exec_chunk|ok|%s|%s", id, tag, escape(chunk)))
        end
        f:close()
      end
      stream(outpath, "out")
      stream(errpath, "err")
      cleanup_file(outpath)
      cleanup_file(errpath)
      if not ok2 then
        error("exec failed: " .. tostring(err2))
      end
    end)
    if running_exec[key] == entry then
      running_exec[key] = nil
    end
    if ok then
      send_reply(sender, string.format("v6|%s|exec_done|ok|code=0", id))
    else
      -- 已捕获的 out/err 流先于终帧发出 (对照 ssh 流数据先于 exit-status)
      send_reply(sender, string.format("v6|%s|exec_done|err|code=1|%s", id, escape(tostring(res))))
    end
  end)
  entry.thread = t
end

-- read: 事件循环内联流式回传 (块逐块, 不整文件进内存)
local function handle_read(sender, id, payload)
  local path = unescape(payload or "")
  if write_count() + exec_count() >= MAX_TRANSFERS then
    send_reply(sender, string.format("v6|%s|file_done|err|busy (max %d concurrent transfers)", id, MAX_TRANSFERS))
    return
  end
  local f = io.open(path, "rb")
  if not f then
    send_reply(sender, string.format("v6|%s|file_done|err|cannot open %s", id, escape(path)))
    return
  end
  local total = 0
  while true do
    local chunk = f:read(CHUNK)
    if not chunk then break end
    total = total + #chunk
    send_reply(sender, string.format("v6|%s|file_chunk|ok|%s", id, escape(chunk)))
  end
  f:close()
  send_reply(sender, string.format("v6|%s|file_done|ok|size=%d", id, total))
end

-- write: 首帧声明 path|size → 建临时文件 → write_chunk 逐块追加 →
-- 收满 size 流式 move 到目标 → write_done
local function handle_write(sender, id, payload)
  local path, size_s = split_first_unescaped(payload or "")
  local size = tonumber(size_s or "0") or 0
  if path == "" or size <= 0 then
    send_reply(sender, string.format("v6|%s|write_done|err|write: bad path/size", id))
    return
  end
  if size > MAX_WRITE_SIZE then
    send_reply(sender, string.format("v6|%s|write_done|err|write: size > %d (max)", id, MAX_WRITE_SIZE))
    return
  end
  if write_count() + exec_count() >= MAX_TRANSFERS then
    send_reply(sender, string.format("v6|%s|write_done|err|busy (max %d concurrent transfers)", id, MAX_TRANSFERS))
    return
  end
  local temp = "/home/rh_wt_" .. sender .. "_" .. id
  local f = io.open(temp, "wb")
  if not f then
    send_reply(sender, string.format("v6|%s|write_done|err|cannot create temp %s", id, escape(temp)))
    return
  end
  f:close()
  active_writes[sender .. ":" .. id] = {
    sender = sender, id = id, path = path, size = size,
    received = 0, temp = temp, last_wall = computer_uptime(),
  }
  send_reply(sender, string.format("v6|%s|write_start|ok", id))
end

-- write_chunk: seq|<escaped ≤CHUNK B>; 无逐块 ack (modem 可靠有序),
-- 客户端等 write_done 终帧
local function handle_write_chunk(sender, id, payload)
  local key = sender .. ":" .. id
  local w = active_writes[key]
  if not w then
    send_reply(sender, string.format("v6|%s|write_done|err|no write in progress", id))
    return
  end
  local _, data_s = split_first_unescaped(payload or "")
  local data = unescape(data_s or "")
  if w.received + #data > w.size then
    abort_write(key, w, "write aborted (oversize: got more than declared size)")
    return
  end
  local f = io.open(w.temp, "ab")
  if not f then
    abort_write(key, w, "write aborted (cannot append to temp)")
    return
  end
  f:write(data)
  f:close()
  w.received = w.received + #data
  w.last_wall = computer_uptime()
  if w.received == w.size then
    active_writes[key] = nil
    local ok_move, err_move = pcall(move_file, w.temp, w.path)
    if not ok_move then
      cleanup_file(w.temp)
      send_reply(sender, string.format("v6|%s|write_done|err|move failed: %s", id, escape(tostring(err_move))))
      return
    end
    send_reply(sender, string.format("v6|%s|write_done|ok|remote: %d bytes written to %s", id, w.size, escape(w.path)))
  end
  -- seq 字段当前协议不用 (modem 可靠有序, 无需按序校验); 保留信封字段供 v6.1 扩展
end

local function handle_delete(sender, id, payload)
  local path = unescape(payload or "")
  local ok, err = pcall(function()
    local fs = require("filesystem")
    local remove = fs.remove or fs.delete
    remove(path)
  end)
  if ok then
    send_reply(sender, string.format("v6|%s|delete|ok|remote: deleted %s", id, escape(path)))
  else
    send_reply(sender, string.format("v6|%s|delete|err|cannot delete %s: %s", id, escape(path), escape(tostring(err))))
  end
end

-- cancel: 杀指定 id 的 exec 线程 + 清临时文件 + 补发该 exec 的终帧
local function handle_cancel(sender, id, payload)
  local target_id = payload or ""
  local r = running_exec[sender .. ":" .. target_id]
  if r then
    running_exec[sender .. ":" .. target_id] = nil
    pcall(r.thread.kill, r.thread)
    cleanup_file(r.outpath)
    cleanup_file(r.errpath)
    -- exec 侧终帧 (客户端 exec 收集器等待它, 不必干等超时)
    send_reply(sender, string.format("v6|%s|exec_done|err|cancelled", target_id))
    send_reply(sender, string.format("v6|%s|cancel|ok|cancelled", id))
    return
  end
  -- 也可能是被客户端放弃的**文件传输**。原先只认 exec, 于是传输槽位只能等
  -- 自然结束或 WRITE_GAP_TIMEOUT(=120s) 才释放 —— 与 exec 同类的槽位泄漏。
  -- 客户端超时后统一用 cancel 回收, 故这里也要覆盖 write 在飞的情形。
  local wkey = sender .. ":" .. target_id
  local w = active_writes[wkey]
  if w then
    -- 复用统一的中止路径: 清 active_writes + 删临时文件 + 发 write_done(err)
    abort_write(wkey, w, "cancelled")
    send_reply(sender, string.format("v6|%s|cancel|ok|cancelled", id))
    return
  end
  send_reply(sender, string.format("v6|%s|cancel|err|no running op %s", id, escape(target_id)))
end

local function get_info_payload()
  local comps = {}
  for _, ctype in pairs(component.list()) do
    comps[#comps + 1] = ctype
  end
  table.sort(comps)
  return "id=" .. tostring(computer_address())
    .. "|uptime=" .. string.format("%.1f", computer_uptime())
    .. "|freeMem=" .. tostring(computer_freeMemory())
    .. "|totalMem=" .. tostring(computer_totalMemory())
    .. "|components=" .. table.concat(comps, ",")
    .. "|pd=6.0"
end

-- ── 主循环 ───────────────────────────────────────────────────────
startup_cleanup()
print("Remote Host v6.0: " .. (isWireless and "wireless" or "wired"))
print("Addr: " .. modemAddr)
print("Port " .. PORT .. " open: " .. tostring(component.invoke(modemAddr, "isOpen", PORT)))
if AUTH_TOKEN == "" then
  print("WARNING: auth disabled (AUTH_TOKEN empty) — any machine in modem range can exec")
end
print("Waiting for commands... (Ctrl+C to stop)")

while true do
  -- 墙钟: 中止卡死的 write (write_chunk 间隙超时)
  local now = computer_uptime()
  for key, w in pairs(active_writes) do
    if now - w.last_wall > WRITE_GAP_TIMEOUT then
      abort_write(key, w, "write aborted (gap timeout " .. WRITE_GAP_TIMEOUT .. "s)")
    end
  end
  local sig = { event.pull(0.5) }
  if sig[1] == "modem_message" then
    local sender, port, data = sig[3], sig[4], sig[6]
    if port == PORT and type(data) == "string" then
      local parts = split_envelope(data)
      local magic, id, op, payload = parts[1], parts[2], parts[3], parts[4]
      if magic ~= "v6" then
        send_reply(sender, string.format("v6|0|boot|err|unknown envelope: %s", escape(tostring(magic))))
      elseif AUTH_TOKEN ~= "" and not authenticated[sender] then
        if op == "auth" then
          if unescape(payload or "") == AUTH_TOKEN then
            authenticated[sender] = true
            send_reply(sender, string.format("v6|%s|auth|ok", id))
          else
            send_reply(sender, string.format("v6|%s|auth|err|bad token", id))
          end
        else
          send_reply(sender, string.format("v6|%s|auth|err|auth required (send auth first)", id))
        end
      elseif op == "ping" then
        send_reply(sender, string.format("v6|%s|pong|ok", id))
      elseif op == "info" then
        send_reply(sender, string.format("v6|%s|info|ok|%s", id, get_info_payload()))
      elseif op == "exec" then
        handle_exec(sender, id, payload)
      elseif op == "read" then
        handle_read(sender, id, payload)
      elseif op == "write" then
        handle_write(sender, id, payload)
      elseif op == "write_chunk" then
        handle_write_chunk(sender, id, payload)
      elseif op == "delete" then
        handle_delete(sender, id, payload)
      elseif op == "cancel" then
        handle_cancel(sender, id, payload)
      else
        send_reply(sender, string.format("v6|%s|%s|err|unknown op", id, escape(tostring(op))))
      end
    end
  elseif sig[1] == "interrupted" then
    print("Interrupted, exiting (rh_* 临时文件下次启动时清理)")
    break
  end
end
