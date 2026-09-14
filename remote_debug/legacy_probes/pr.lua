-- 样板层已由 tools/retrofit_v5_scripts.py 替换 (2026-09-15):
-- v5 直连 modem(端口 8001) 已退役; 现经 /home/v5shim.lua 走 v6(8100)。
-- 业务逻辑(cmd(...) 调用)保持原样, 返回值仍是 "ok|..."/"err|..."。
local cmd = dofile("/home/v5shim.lua")

local log = io.open("/home/pr.out", "w")
local function lg(s) log:write(s .. "\n"); log:flush() end


local r = cmd("exec|lua /home/probe_pos.lua", 60)
lg("EXEC: " .. tostring(r))
local r2 = cmd("read|/home/probe_result.txt", 30)
lg("RESULT FILE: " .. tostring(r2))
log:close()
