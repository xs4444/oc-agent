-- 样板层已由 tools/retrofit_v5_scripts.py 替换 (2026-09-15):
-- v5 直连 modem(端口 8001) 已退役; 现经 /home/v5shim.lua 走 v6(8100)。
-- 业务逻辑(cmd(...) 调用)保持原样, 返回值仍是 "ok|..."/"err|..."。
local cmd = dofile("/home/v5shim.lua")

local log = io.open("/home/cln.out", "w")
local function lg(s) log:write(s .. "\n"); log:flush() end


-- 用 exec 列出 /tmp 所有文件
local r = cmd("exec|ls /tmp", 15)
lg("LS /tmp: " .. tostring(r))

-- 解析文件名列表
local files = {}
if r and r:find("^ok|") then
  local content = r:sub(5)  -- 去掉 ok| 前缀
  for name in content:gmatch("[^\r\n]+") do
    if name ~= "" then
      files[#files+1] = name
    end
  end
end
lg("FILE COUNT: " .. #files)

-- 逐个 delete
local ok_count, fail_count = 0, 0
for _, name in ipairs(files) do
  local path = "/tmp/" .. name
  local d = cmd("delete|" .. path, 10)
  if d and d:find("^ok|") then
    ok_count = ok_count + 1
  else
    fail_count = fail_count + 1
    lg("FAIL delete " .. path .. ": " .. tostring(d))
  end
end
lg(string.format("CLEAN DONE: %d ok, %d fail", ok_count, fail_count))

-- 验证清理后
local r2 = cmd("exec|ls /tmp", 15)
lg("LS /tmp AFTER: " .. tostring(r2))

log:close()
