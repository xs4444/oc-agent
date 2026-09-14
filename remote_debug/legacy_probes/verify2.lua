-- 权威校验：用 exec ls -la 获取所有文件准确大小，与本地比对
-- 样板层已由 tools/retrofit_v5_scripts.py 替换 (2026-09-15):
-- v5 直连 modem(端口 8001) 已退役; 现经 /home/v5shim.lua 走 v6(8100)。
-- 业务逻辑(cmd(...) 调用)保持原样, 返回值仍是 "ok|..."/"err|..."。
local cmd = dofile("/home/v5shim.lua")

local log = io.open("/home/verify2.out", "w")
local function lg(s) log:write(s .. "\n"); log:flush() end


local files = {
  {"analyzeGenes.lua", 11687},
  {"apiary.lua", 14801},
  {"bee.lua", 1634},
  {"beeData.lua", 10691},
  {"biomes.lua", 32103},
  {"bot.lua", 13781},
  {"config.lua", 401},
  {"device.lua", 2891},
  {"doUntil.lua", 302},
  {"environment.lua", 2063},
  {"installer.lua", 1988},
  {"lib/inflate-bwo.lua", 7238},
  {"lib/nbt.lua", 26815},
  {"lib/zzlib.lua", 5831},
  {"mutations.lua", 76915},
  {"strategy.lua", 66813},
  {"tools.lua", 3680},
}
local REMOTE_DIR = "/home/beemaster"
local ok_count, fail_count = 0, 0

for _, f in ipairs(files) do
  local name, local_size = f[1], f[2]
  local remote_path = REMOTE_DIR .. "/" .. name
  local r = cmd("exec|ls -la " .. remote_path, 20)
  -- 解析 ls -la 输出: "f-rw <size> <date> <time> <path>"
  local size = r and r:match("^ok|f%-rw (%d+)")
  if size and tonumber(size) == local_size then
    lg(string.format("OK  %-22s %d bytes", name, local_size))
    ok_count = ok_count + 1
  else
    lg(string.format("FAIL %-22s remote=%s local=%d", name, tostring(size), local_size))
    fail_count = fail_count + 1
  end
end

lg(string.format("FINAL VERIFY: %d ok, %d fail / %d total", ok_count, fail_count, #files))
log:close()
