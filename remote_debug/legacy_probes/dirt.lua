-- 样板层已由 tools/retrofit_v5_scripts.py 替换 (2026-09-15):
-- v5 直连 modem(端口 8001) 已退役; 现经 /home/v5shim.lua 走 v6(8100)。
-- 业务逻辑(cmd(...) 调用)保持原样, 返回值仍是 "ok|..."/"err|..."。
local cmd = dofile("/home/v5shim.lua")

local log = io.open("/home/dirt.out", "w")
local function lg(s) log:write(s .. "\n"); log:flush() end


-- 1. 确认远端在线
local r0 = cmd("ping", 10)
lg("PING: " .. tostring(r0))

-- 2. 探测机器人物品栏里的泥土 (用 lua 脚本读 inventory)
local probe = [[
local robot = require("robot")
local inv = require("component").inventory_controller
local found = {}
for slot = 1, robot.inventorySize() do
  local s = inv.getStackInInternalSlot(slot)
  if s and s.name == "minecraft:dirt" then
    table.insert(found, slot .. "=" .. s.size)
  end
end
if #found > 0 then
  print("DIRT_SLOTS: " .. table.concat(found, ","))
else
  print("DIRT_SLOTS: none")
end
-- 顺便列出前10格物品
local items = {}
for slot = 1, math.min(10, robot.inventorySize()) do
  local s = inv.getStackInInternalSlot(slot)
  table.insert(items, slot .. ":" .. (s and (s.name .. "x" .. s.size) or "empty"))
end
print("SLOTS: " .. table.concat(items, " "))
]]
local serialization = require("serialization")
local e = serialization.serialize(probe):gsub("\\", "\\\\"):gsub("|", "\\|")
local rw = cmd("write|/home/probe_dirt.lua|" .. e, 20)
lg("WRITE probe: " .. tostring(rw))
local r1 = cmd("exec|lua /home/probe_dirt.lua", 30)
lg("PROBE: " .. tostring(r1))

log:close()
