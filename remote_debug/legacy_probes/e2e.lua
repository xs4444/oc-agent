-- 样板层已由 tools/retrofit_v5_scripts.py 替换 (2026-09-15):
-- v5 直连 modem(端口 8001) 已退役; 现经 /home/v5shim.lua 走 v6(8100)。
-- 业务逻辑(cmd(...) 调用)保持原样, 返回值仍是 "ok|..."/"err|..."。
local cmd = dofile("/home/v5shim.lua")

local log = io.open("/home/e2e.out", "w")
local function lg(s) log:write(s .. "\n"); log:flush() end


-- 1. ping
local r1 = cmd("ping", 10)
lg("PING: " .. tostring(r1))

-- 2. exec echo (关键: 验证 /home 重定向)
local r2 = cmd("exec|echo exec_recovered_v51", 15)
lg("EXEC echo: " .. tostring(r2))

-- 3. exec ls
local r3 = cmd("exec|ls /home", 15)
lg("EXEC ls /home: " .. tostring(r3 and r3:sub(1, 150)))

-- 4. exec ls /tmp (看残留)
local r4 = cmd("exec|ls /tmp", 15)
lg("EXEC ls /tmp: " .. tostring(r4 and r4:sub(1, 300)))

-- 5. info
local r5 = cmd("info", 10)
lg("INFO: " .. tostring(r5 and r5:sub(1, 200)))

log:close()
