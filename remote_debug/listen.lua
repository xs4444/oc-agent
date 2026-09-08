-- listen.lua (fixed) — 参考 agent/subagent.lua wait_modem_message 模式
-- 关键修复: modem_message 事件参数顺序 (subagent.lua:162-168 真机验证):
--   sig[1]=事件名 sig[2]=本地地址 sig[3]=远程地址 sig[4]=端口 sig[5]=距离 sig[6]=数据
-- 旧版 bug: 用 b==port 判断, 但 b 是远程地址不是端口 → 永远不回复
local event = require("event")
local component = require("component")

-- 找到 modem
local modemAddr = nil
for addr, ctype in pairs(component.list()) do
  if ctype == "modem" then
    modemAddr = addr
    break
  end
end
if not modemAddr then
  print("ERROR: no modem found")
  os.exit(1)
end

local PORT = 8001
component.invoke(modemAddr, "open", PORT)
local isWireless = component.invoke(modemAddr, "isWireless")
print("Modem: " .. (isWireless and "wireless" or "wired"))
print("Addr: " .. modemAddr)
print("Port " .. PORT .. " open: " .. tostring(component.invoke(modemAddr, "isOpen", PORT)))
print("Listening... (Ctrl+C to stop)")

-- 无过滤 pull + 自判事件名 (subagent.lua:162 模式)
while true do
  local sig = {event.pull(0.5)}
  if sig[1] == "modem_message" then
    local sender = sig[3]   -- 远程地址
    local port = sig[4]     -- 端口
    local data = sig[6]     -- 数据
    if port == PORT then
      print("PING from " .. tostring(sender) .. " -> " .. tostring(data))
      component.invoke(modemAddr, "send", sender, port, "pong:" .. tostring(os.clock()))
      print("REPLIED pong")
    end
  elseif sig[1] == "interrupted" then
    print("Interrupted, exiting")
    break
  end
end

