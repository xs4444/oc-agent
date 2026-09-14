-- 样板层已由 tools/retrofit_v5_scripts.py 替换 (2026-09-15):
-- v5 直连 modem(端口 8001) 已退役; 现经 /home/v5shim.lua 走 v6(8100)。
-- 业务逻辑(cmd(...) 调用)保持原样, 返回值仍是 "ok|..."/"err|..."。
local cmd = dofile("/home/v5shim.lua")

local log = io.open("/home/scan.out", "w")
local function lg(s) log:write(s .. "\n"); log:flush() end


local probe = [[
local robot = require("robot")
local inv = require("component").inventory_controller
local size = robot.inventorySize()
local nonempty = {}
for slot = 1, size do
  local s = inv.getStackInInternalSlot(slot)
  if s then
    table.insert(nonempty, string.format("[%d] %s x%d", slot, s.name, s.size))
  end
end
if #nonempty == 0 then
  print("INVENTORY: ALL EMPTY (size=" .. size .. ")")
else
  print("INVENTORY (" .. #nonempty .. " nonempty / " .. size .. "):")
  for _, line in ipairs(nonempty) do
    print("  " .. line)
  end
end
]]
local e = serialization.serialize(probe):gsub("\\", "\\\\"):gsub("|", "\\|")
cmd("write|/home/scan_inv.lua|" .. e, 20)
local r = cmd("exec|lua /home/scan_inv.lua", 30)
lg(r or "nil")
log:close()
