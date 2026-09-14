-- 样板层已由 tools/retrofit_v5_scripts.py 替换 (2026-09-15):
-- v5 直连 modem(端口 8001) 已退役; 现经 /home/v5shim.lua 走 v6(8100)。
-- 业务逻辑(cmd(...) 调用)保持原样, 返回值仍是 "ok|..."/"err|..."。
local cmd = dofile("/home/v5shim.lua")

local log = io.open("/home/dirt2.out", "w")
local function lg(s) log:write(s .. "\n"); log:flush() end


local r0 = cmd("ping", 10)
lg("PING: " .. tostring(r0))

-- 全槽位扫描
local probe = [[
local robot = require("robot")
local inv = require("component").inventory_controller
local total = robot.inventorySize()
print("TOTAL_SLOTS: " .. total)
local found = {}
for slot = 1, total do
  local s = inv.getStackInInternalSlot(slot)
  if s then
    table.insert(found, slot .. ":" .. s.name .. "x" .. s.size)
  end
end
if #found > 0 then
  print("ITEMS: " .. table.concat(found, " "))
else
  print("ITEMS: none")
end
-- 当前选中槽位
local sel = robot.getSelectedSlot()
local selItem = inv.getStackInInternalSlot(sel)
print("SELECTED_SLOT: " .. sel .. " = " .. (selItem and (selItem.name .. "x" .. selItem.size) or "empty"))
]]
local e = serialization.serialize(probe):gsub("\\", "\\\\"):gsub("|", "\\|")
local rw = cmd("write|/home/probe_dirt2.lua|" .. e, 20)
lg("WRITE: " .. tostring(rw))
local r1 = cmd("exec|lua /home/probe_dirt2.lua", 30)
lg("PROBE: " .. tostring(r1))

log:close()
