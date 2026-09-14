-- e2e_t11.lua — 单独验证 cancel（让出式长 exec, 不依赖 computer.sleep）
local remote = dofile("/home/remote_client.lua")
local v6 = remote._v6
local ROBOT = "84f13777-676d-4c8d-b608-6f5f1346b602"
local MOD = "3272384f-0749-4530-8b60-73eaf963d3ed"
local computer = require("computer")
local event = require("event")

local h, err = remote.connect(ROBOT, { modem = MOD, port = 8100, probe_timeout = 8 })
if not h then return "FATAL: " .. tostring(err) end

-- 先探机器人 computer.sleep/uptime 是否可用 (诊断)
local wp = h:write("/home/e2e_probe.lua",
  'local c=require("computer"); io.stdout:write("sleep="..tostring(type(c.sleep)).." uptime="..tostring(type(c.uptime)).."\\n")', 20)
local ep = h:exec("lua /home/e2e_probe.lua", 20)
local probe = string.format("probe: w=%s out=[%s] err=[%.40s]", tostring(wp.ok), tostring(ep.out), tostring(ep.err or ep.stderr))
h:delete("/home/e2e_probe.lua", 10)

-- 让出式 60s sleep (每 0.1s yield, 可被 cancel kill; 不依赖 computer.sleep)
local sleep_code = 'local c=require("computer") local e=require("event") local t=c.uptime() while c.uptime()-t<60 do e.pull(0.1) end io.stdout:write("slept-60s\\n")'
local ws = h:write("/home/e2e_sleep.lua", sleep_code, 20)
if not ws.ok then
  return probe .. " | T11 FAIL: write sleep failed: " .. tostring(ws.err)
end

local t0 = computer.uptime()
local id = v6.next_id(h)
local ok_send, send_err = v6.send(h, string.format("v6|%d|exec|%s", id, v6.escape("lua /home/e2e_sleep.lua")))
if not ok_send then
  h:delete("/home/e2e_sleep.lua", 10)
  return probe .. " | T11 FAIL: send exec: " .. tostring(send_err)
end

-- 等 1.5s 让 exec 真正跑起来 (期间用 event.pull, 但 exec 无输出→无帧可丢)
local wake = computer.uptime() + 1.5
while computer.uptime() < wake do event.pull(0.2) end

local cid = v6.next_id(h)
v6.send(h, string.format("v6|%d|cancel|%d", cid, id))

-- 单循环收双终帧
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
local dt = computer.uptime() - t0
h:delete("/home/e2e_sleep.lua", 10)
h:close()

local ok = (cancel_frame ~= nil and cancel_frame.status == "ok") and (exec_frame ~= nil)
return string.format("%s | T11 cancel=%s exec=%s exec_payload=[%.40s] dt=%.1fs → %s",
  probe,
  tostring(cancel_frame and cancel_frame.status),
  tostring(exec_frame and exec_frame.status),
  tostring(exec_frame and exec_frame.payload),
  dt,
  ok and "PASS" or "FAIL")
