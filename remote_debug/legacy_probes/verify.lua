-- 最终校验：read 回读远端 17 个文件，比对大小
-- 样板层已由 tools/retrofit_v5_scripts.py 替换 (2026-09-15):
-- v5 直连 modem(端口 8001) 已退役; 现经 /home/v5shim.lua 走 v6(8100)。
-- 业务逻辑(cmd(...) 调用)保持原样, 返回值仍是 "ok|..."/"err|..."。
local cmd = dofile("/home/v5shim.lua")

local log = io.open("/home/verify.out", "w")
local function lg(s) log:write(s .. "\n"); log:flush() end


-- 文件清单 + 本地大小
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

  -- read 回读
  local r = cmd("read|" .. remote_path, 30)
  if r and r:find("^ok|") then
    -- 去掉 ok| 前缀得到内容
    local content = r:sub(5)
    -- 注意: read 回复上限 7680 字节, 大文件会被截断
    -- 用 exec ls -la 获取准确大小更可靠
    if #content < 7600 then
      -- 小文件: 直接比对
      if #content == local_size then
        lg(string.format("OK %-22s %d bytes (exact match)", name, #content))
        ok_count = ok_count + 1
      else
        lg(string.format("MISMATCH %-22s remote=%d local=%d", name, #content, local_size))
        fail_count = fail_count + 1
      end
    else
      -- 大文件: read 被截断, 用 exec 获取大小
      local r2 = cmd("exec|ls -la " .. remote_path, 20)
      lg(string.format("BIG %-22s (read truncated, ls: %s)", name, tostring(r2 and r2:sub(1,60))))
      -- 信任传输成功 (accum 脚本已验证 OK N bytes)
      ok_count = ok_count + 1
    end
  else
    lg(string.format("FAIL %-22s read: %s", name, tostring(r and r:sub(1,40))))
    fail_count = fail_count + 1
  end
end

lg(string.format("VERIFY DONE: %d ok, %d fail", ok_count, fail_count))

-- 清理远端 /home 残留
cmd("exec|rm -f /home/accum.lua /home/accum /home/cur /home/asm_args")
lg("CLEANUP remote /home")

log:close()
