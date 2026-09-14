-- 样板层已由 tools/retrofit_v5_scripts.py 替换 (2026-09-15):
-- v5 直连 modem(端口 8001) 已退役; 现经 /home/v5shim.lua 走 v6(8100)。
-- 业务逻辑(cmd(...) 调用)保持原样, 返回值仍是 "ok|..."/"err|..."。
local cmd = dofile("/home/v5shim.lua")

local log = io.open("/home/probe.out", "w")
local function lg(s) log:write(s .. "\n"); log:flush() end


local r0 = cmd("ping", 10)
lg("PING: " .. tostring(r0))

local script = io.open("/home/probe_pos.lua", "r"):read("*a")
local e = serialization.serialize(script):gsub("\\", "\\\\"):gsub("|", "\\|")
local rw = cmd("write|/home/probe_pos.lua|" .. e, 20)
lg("WRITE: " .. tostring(rw))
local r1 = cmd("exec|lua /home/probe_pos.lua", 60)
lg("PROBE: " .. tostring(r1))
log:close()
