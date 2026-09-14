-- 样板层已由 tools/retrofit_v5_scripts.py 替换 (2026-09-15):
-- v5 直连 modem(端口 8001) 已退役; 现经 /home/v5shim.lua 走 v6(8100)。
-- 业务逻辑(cmd(...) 调用)保持原样, 返回值仍是 "ok|..."/"err|..."。
local cmd = dofile("/home/v5shim.lua")

local log = io.open("/home/cln2.out", "w")
local function lg(s) log:write(s .. "\n"); log:flush() end


-- 用 exec rm 清理 /tmp 残留
local r1 = cmd("exec|rm -f /tmp/chunk_*", 20)
lg("RM chunk_*: " .. tostring(r1))

local r2 = cmd("exec|rm -f /tmp/exec_out_*", 20)
lg("RM exec_out_*: " .. tostring(r2))

local r3 = cmd("exec|rm -f /tmp/asm_args /tmp/assemble.lua", 20)
lg("RM asm: " .. tostring(r3))

-- 验证
local r4 = cmd("exec|ls /tmp", 15)
lg("LS /tmp AFTER: " .. tostring(r4))

log:close()
