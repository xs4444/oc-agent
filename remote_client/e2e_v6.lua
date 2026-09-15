-- ═══════════════════════════════════════════════════════════════
-- e2e_v6.lua — v6 协议真机 e2e（游戏机/主控侧运行, 经 modem 打机器人 8100）
-- 覆盖: ping/info/简单exec/大输出流式/管道/失败命令/小文件/大文件分块/删除/离线/cancel
-- 返回紧凑摘要 "PASS n/N | fails: ..."
-- ═══════════════════════════════════════════════════════════════
local remote = dofile("/home/remote_client.lua")
local v6 = remote._v6
local ROBOT = "84f13777-676d-4c8d-b608-6f5f1346b602"
local MOD = "3272384f-0749-4530-8b60-73eaf963d3ed"

local results = {}
local function record(name, ok, detail)
  results[#results + 1] = { name = name, ok = ok, detail = detail }
  print(string.format("[%s] %s %s", ok and "PASS" or "FAIL", name, detail or ""))
end

local function sleep_wall(sec)
  -- 游戏机 OpenOS 无 computer.sleep (实测 nil) → event.pull 循环等墙钟
  local ev = require("event")
  local deadline = require("computer").uptime() + sec
  while require("computer").uptime() < deadline do
    ev.pull(0.2)
  end
end

local h, err = remote.connect(ROBOT, { modem = MOD, port = 8100, probe_timeout = 8 })
if not h then
  return "FATAL: v6 connect failed: " .. tostring(err)
end

-- T1 ping
local p = h:ping()
record("T1 ping", p.ok, tostring(p.err))

-- T2 info (pd=6.0)
local inf = h:info()
record("T2 info pd=6.0", inf.ok and inf.pd == "6.0", "pd=" .. tostring(inf.pd))

-- T3 exec 简单命令 (写脚本文件, lua 不支持 -e)
do
  local w = h:write("/home/e2e_t3.lua", "print(6*7)", 20)
  local e = h:exec("lua /home/e2e_t3.lua", 20)
  record("T3 exec simple", w.ok and e.ok and tostring(e.out):find("42", 1, true) ~= nil,
    string.format("w=%s out=[%s]", tostring(w.ok), tostring(e.out)))
  h:delete("/home/e2e_t3.lua", 10)
end

-- T4 exec 大输出 (~12KB, 验证流式分块无截断)
do
  local code = "for i=1,500 do io.stdout:write(string.format('line%03d-%s\\n', i, string.rep('x', 20))) end"
  local w = h:write("/home/e2e_t4.lua", code, 20)
  local e = h:exec("lua /home/e2e_t4.lua", 30)
  record("T4 exec large output", w.ok and e.ok and #tostring(e.out) > 10000 and e.truncated == false,
    string.format("len=%d truncated=%s", #tostring(e.out or ""), tostring(e.truncated)))
  h:delete("/home/e2e_t4.lua", 10)
end

-- T5 exec 管道 (命令体含字面 '|', 验证 v6 payload 转义)
do
  local e = h:exec("echo abcdef | grep cd", 20)
  record("T5 exec pipe", e.ok and tostring(e.out):find("abcdef", 1, true) ~= nil,
    "out=[" .. tostring(e.out) .. "]")
end

-- T6 exec 失败命令 (lua 崩溃 → stderr 含崩溃行; 崩溃≠shell失败, code=0)
do
  local w = h:write("/home/e2e_t6.lua", 'error("boom-e2e")', 20)
  local e = h:exec("lua /home/e2e_t6.lua", 20)
  local blob = tostring(e.stderr) .. tostring(e.out) .. tostring(e.err)
  record("T6 exec fail (crash→stderr)", blob:find("boom-e2e", 1, true) ~= nil,
    string.format("ok=%s code=%s stderr=[%.60s]", tostring(e.ok), tostring(e.code), tostring(e.stderr)))
  h:delete("/home/e2e_t6.lua", 10)
end

-- T7 write+read 小文件
do
  local small = "hello v6 e2e " .. string.rep("a", 100)
  local w = h:write("/home/e2e_small.txt", small, 30)
  local r = h:read("/home/e2e_small.txt", 30)
  record("T7 write+read small", w.ok and r.ok and r.content == small,
    string.format("w=%s r=%s len=%d", tostring(w.ok), tostring(r.ok), #tostring(r.content or "")))
end

-- T8 write+read 大文件 (50KB, 分块)
do
  local parts = {}
  for i = 1, 50 do
    parts[#parts + 1] = string.format("chunk%02d:", i) .. string.rep(string.char(65 + (i % 26)), 1000)
  end
  local big = table.concat(parts)  -- 50 * 1008 = 50400 bytes
  local w = h:write("/home/e2e_big.txt", big, 120)
  local r = h:read("/home/e2e_big.txt", 120)
  record("T8 write+read large (50KB)", w.ok and r.ok and r.content == big and r.truncated == false,
    string.format("w_bytes=%s r_len=%d match=%s", tostring(w.bytes), #tostring(r.content or ""), tostring(r.content == big)))
end

-- T9 delete
do
  local d1 = h:delete("/home/e2e_small.txt", 20)
  local d2 = h:delete("/home/e2e_big.txt", 20)
  local r = h:read("/home/e2e_small.txt", 20)
  record("T9 delete", d1.ok and d2.ok and (not r.ok),
    string.format("del=%s/%s read_after=%s", tostring(d1.ok), tostring(d2.ok), tostring(r.ok)))
end

-- T10 离线检测 (8101 无守护 → REMOTE_OFFLINE)
do
  local ho, eo = remote.connect(ROBOT, { modem = MOD, port = 8101, probe_timeout = 6 })
  record("T10 offline", ho == nil and tostring(eo):find("REMOTE_OFFLINE", 1, true) ~= nil, tostring(eo))
  if ho then ho:close() end
end

-- T11 cancel 长 exec (低层: 发长 exec 拿 id → sleep → cancel → 收双终帧)
do
  local computer = require("computer")
  local event = require("event")
  local ws = h:write("/home/e2e_sleep.lua",
    'local c=require("computer"); local e=require("event"); local t=c.uptime() while c.uptime()-t<60 do e.pull(0.1) end io.stdout:write("slept-60s\\n")', 20)
  if not ws.ok then
    record("T11 cancel", false, "write sleep script failed: " .. tostring(ws.err))
  else
    local id = v6.next_id(h)
    local ok_send, send_err = v6.send(h, string.format("v6|%d|exec|%s", id, v6.escape("lua /home/e2e_sleep.lua")))
    if not ok_send then
      record("T11 cancel", false, "send exec failed: " .. tostring(send_err))
    else
      sleep_wall(1.5)
      local cid = v6.next_id(h)
      v6.send(h, string.format("v6|%d|cancel|%d", cid, id))
      -- 单循环收双终帧 (避免 v6_wait 丢弃异 id 帧)
      local cancel_frame, exec_frame
      local deadline = computer.uptime() + 15
      while (not cancel_frame or not exec_frame) and computer.uptime() < deadline do
        local sig = { event.pull(0.25) }
        if sig[1] == "modem_message" and sig[3] == h.addr and sig[4] == h.port then
          local frame = v6.parse_frame(sig[6])
          if frame then
            if frame.id == cid and frame.op == "cancel" then cancel_frame = frame end
            if frame.id == id and frame.op == "exec_done" then exec_frame = frame end
          end
        end
      end
      record("T11 cancel", (cancel_frame ~= nil) and (exec_frame ~= nil),
        string.format("cancel=%s exec=%s exec_payload=[%.40s]",
          tostring(cancel_frame and cancel_frame.status),
          tostring(exec_frame and exec_frame.status),
          tostring(exec_frame and exec_frame.payload)))
    end
    h:delete("/home/e2e_sleep.lua", 10)
  end
end

-- T12 转义透明: 全 '|' 文件 (escape 膨胀 -> 曾超单包被静默截断)
do
  local n = 7000
  local mysum = 0
  for i = 1, n do mysum = (mysum * 31 + 124) % 4294967296 end  -- 0x7C = '|'
  local w = h:write("/home/e2e_pipes.txt", string.rep("|", n), 60)
  local r = h:read("/home/e2e_pipes.txt", 60)
  local got = r.ok and r.content or nil
  local gsum = 0
  if got then for i = 1, #got do gsum = (gsum * 31 + got:byte(i)) % 4294967296 end end
  record("T12 escape-pipe", w.ok and r.ok and #got == n and gsum == mysum,
    string.format("sent=%d got=%s sum_ok=%s", n, got and #got or "nil", tostring(gsum == mysum)))
  h:delete("/home/e2e_pipes.txt", 20)
end

-- T13 二进制安全: 多字节 UTF-8 (文本模式读按"字符"计数 -> 曾超单包被截断)
do
  -- 用机器人的 write 造文件 (客户端 write 本身就是字节安全的发送侧)
  local unit = "-- " .. string.rep("\226\148\128", 14) .. " 中文 " .. string.rep("\226\148\128", 14) .. "\n"
  local content = string.rep(unit, 300)   -- ~31.5KB, 3 字节/字
  local w = h:write("/home/e2e_utf8.txt", content, 90)
  local r = h:read("/home/e2e_utf8.txt", 90)
  local got = r.ok and r.content or ""
  local gs, ws2 = 0, 0
  for i = 1, #got do gs = (gs * 31 + got:byte(i)) % 4294967296 end
  for i = 1, #content do ws2 = (ws2 * 31 + content:byte(i)) % 4294967296 end
  local fffd = 0
  for i = 1, #got - 2 do
    if got:byte(i) == 0xEF and got:byte(i + 1) == 0xBF and got:byte(i + 2) == 0xBD then fffd = fffd + 1 end
  end
  record("T13 utf8-binary", w.ok and r.ok and got == content and fffd == 0,
    string.format("sent=%d got=%d sum_ok=%s fffd=%d", #content, #got, tostring(gs == ws2), fffd))
  h:delete("/home/e2e_utf8.txt", 20)
end

-- T14 超时语义: 慢命令超时须报 REMOTE_TIMEOUT (对端在线), 不是 REMOTE_OFFLINE
do
  local ws = h:write("/home/e2e_slow.lua",
    'local c=require("computer") local t=c.uptime() while c.uptime()-t<8 do os.sleep(0.2) end io.stdout:write("done")', 20)
  if not ws.ok then
    record("T14 timeout-vs-offline", false, "write slow script failed")
  else
    local r = h:exec("lua /home/e2e_slow.lua", 2)
    record("T14 timeout-vs-offline",
      (not r.ok) and r.timeout == true and not r.offline
        and tostring(r.err):find("REMOTE_TIMEOUT", 1, true) ~= nil,
      string.format("timeout=%s offline=%s err=%s", tostring(r.timeout), tostring(r.offline), tostring(r.err):sub(1, 40)))
    -- 超时后客户端应已回收槽位: 连续多次仍可用
    local ok_after = true
    for i = 1, 4 do
      local rr = h:exec("lua /home/e2e_slow.lua", 2)
      if not rr.timeout then ok_after = false end
    end
    local probe = h:exec("echo SLOT_OK", 15)
    record("T15 slot-reclaim", ok_after and probe.ok and tostring(probe.out):find("SLOT_OK", 1, true) ~= nil,
      string.format("4x超时后仍可 exec=%s out=%s", tostring(probe.ok), tostring(probe.out):gsub("\n", "")))
    h:delete("/home/e2e_slow.lua", 20)
  end
end

h:close()

local pass, fail, fails, statuses = 0, 0, {}, {}
for _, r in ipairs(results) do
  statuses[#statuses + 1] = string.format("%s=%s", r.name, r.ok and "OK" or "FAIL")
  if r.ok then
    pass = pass + 1
  else
    fail = fail + 1
    fails[#fails + 1] = r.name .. "(" .. tostring(r.detail) .. ")"
  end
end
return string.format("PASS %d/%d | %s | %s", pass, #results,
  fail == 0 and "ALL GREEN" or ("FAILS: " .. table.concat(fails, "; ")),
  table.concat(statuses, " "))
