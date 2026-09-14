-- 样板层已由 tools/retrofit_v5_scripts.py 替换 (2026-09-15):
-- v5 直连 modem(端口 8001) 已退役; 现经 /home/v5shim.lua 走 v6(8100)。
-- 业务逻辑(cmd(...) 调用)保持原样, 返回值仍是 "ok|..."/"err|..."。
local cmd = dofile("/home/v5shim.lua")

local log = io.open("/home/placedirt.out", "w")
local function lg(s) log:write(s .. "\n"); log:flush() end


local r0 = cmd("ping", 10)
lg("PING: " .. tostring(r0))

-- 写放置脚本到远端
local script = io.open("/home/place_dirt.lua", "r"):read("*a")
local e = serialization.serialize(script):gsub("\\", "\\\\"):gsub("|", "\\|")
local rw = cmd("write|/home/place_dirt.lua|" .. e, 20)
lg("WRITE script: " .. tostring(rw))

-- 执行
local r1 = cmd("exec|lua /home/place_dirt.lua", 60)
lg("EXEC: " .. tostring(r1))

-- 验证：再探测一次槽1（应该空了）
local probe = [[
local inv = require("component").inventory_controller
local s = inv.getStackInInternalSlot(1)
print("SLOT1: " .. (s and (s.name .. "x" .. s.size) or "empty"))
]]
local ep = serialization.serialize(probe):gsub("\\", "\\\\"):gsub("|", "\\|")
cmd("write|/home/probe2.lua|" .. ep, 20)
local r2 = cmd("exec|lua /home/probe2.lua", 30)
lg("VERIFY SLOT1: " .. tostring(r2))

log:close()

