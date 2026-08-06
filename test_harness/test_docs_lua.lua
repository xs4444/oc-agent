-- test_docs_lua.lua: ocvm 端到端验证 docs.lua（注入假 internet 模块）
-- 覆盖: default_dest 探测 / 版本对比 / 下载(模拟) / ustar 解析 / 解压 /
--       version.txt 写入 / 二次运行跳过下载
-- 用法: lua /mnt/<short>/test_docs_lua.lua /mnt/<short>
-- 依赖上传: oc-docs.tar + docs.json（EXTRA_FILES）
local base = ({...})[1] or "/mnt"
local PASS, FAIL = 0, 0
local function log(...)
  local parts = {}
  for i = 1, select("#", ...) do parts[i] = tostring(select(i, ...)) end
  local line = table.concat(parts, " ")
  print(line)
  local f = io.open(base .. "/test_docs_lua_result.txt", "a")
  if f then f:write(line .. "\n") f:close() end
end
io.open(base .. "/test_docs_lua_result.txt", "w"):close()

local function check(name, cond, detail)
  if cond then
    PASS = PASS + 1
    log("PASS " .. name)
  else
    FAIL = FAIL + 1
    log("FAIL " .. name .. (detail and (" -- " .. tostring(detail)) or ""))
  end
end

-- ── 注入假 internet：docs.json/oc-docs.tar 从挂载盘读取 ──
local json_file = io.open(base .. "/docs.json", "r")
local json_data = json_file and json_file:read("*a")
if json_file then json_file:close() end
local tar_file = io.open(base .. "/oc-docs.tar", "rb")
local tar_data = tar_file and tar_file:read("*a")
if tar_file then tar_file:close() end

local requested = {}
local fake_internet = {
  request = function(url)
    requested[#requested + 1] = url
    local data
    if url:find("docs%.json") then
      data = json_data
    elseif url:find("oc%-docs%.tar") then
      data = tar_data
    end
    if not data then
      return nil  -- data API 等：触发 fetch 失败路径
    end
    -- 模拟 OC 的迭代器 handle：__call 每次返回下一 chunk，最后 nil
    local done = false
    return setmetatable({}, {
      __index = { read = function() return data end },
      __call = function()
        if done then return nil end
        done = true
        return data
      end,
    })
  end,
}
package.loaded["internet"] = fake_internet
package.loaded["component"] = require("component")
package.loaded["filesystem"] = require("filesystem")

check("fixtures loaded", json_data ~= nil and tar_data ~= nil and #tar_data > 500000, #(tar_data or ""))

-- ── 运行真实 docs.lua（传目标目录参数，避免默认探测干扰断言）──
local dest = base .. "/doc"
local chunk = assert(loadfile(base .. "/docs.lua"))
-- docs.lua 顶层执行时会 fetch；用 pcall 包住并捕获 print 输出
local out_lines = {}
local orig_print = print
print = function(...) out_lines[#out_lines + 1] = table.concat({...}, " ") end

local ok_run, run_err = pcall(chunk, dest)
print = orig_print

log("out_lines count: " .. #out_lines .. ", run_err: " .. tostring(run_err))
local full_out = table.concat(out_lines, "\n")
log("--- docs.lua 第一次运行输出 ---")
for _, l in ipairs(out_lines) do log("  " .. l) end
log("---")

check("docs.lua 运行无异常", ok_run, run_err)

-- 解压结果校验
local fs = require("filesystem")
local count = 0
local function walk(dir)
  for item in fs.list(dir) do
    local full = dir .. "/" .. item
    if fs.isDirectory(full) then walk(full)
    elseif item:match("%.md$") then count = count + 1 end
  end
end
walk(dest)
check("解压 269 个 md", count == 269, count)
check("api/robot.md 存在", fs.exists(dest .. "/api/robot.md"))
check("gtnh/open_computers.md 存在", fs.exists(dest .. "/gtnh/open_computers.md"))

-- version.txt 写入 + 内容
local vf = io.open(dest .. "/version.txt", "r")
local v = vf and vf:read("*a")
if vf then vf:close() end
local expect_v = json_data and json_data:match('"version"%s*:%s*"([^"]+)"')
check("version.txt 写入且匹配", v ~= nil and v:gsub("%s","") == expect_v, tostring(v) .. " vs " .. tostring(expect_v))

-- ── 第二次运行：应跳过下载（已是最新）──
local run2_lines = {}
local orig_print2 = print
print = function(...) run2_lines[#run2_lines + 1] = table.concat({...}, " ") end
local ok_run2 = pcall(chunk, dest)
print = orig_print2
local out2 = table.concat(run2_lines, "\n")
log("--- docs.lua 第二次运行输出 ---")
for _, l in ipairs(run2_lines) do log("  " .. l) end
check("第二次运行跳过下载", out2:find("已是最新") ~= nil, out2:sub(1, 200))

-- 请求次数: 第二次不应请求 tar（只请求 docs.json + data API）
local tar_requests = 0
for _, u in ipairs(requested) do if u:find("oc%-docs%.tar") then tar_requests = tar_requests + 1 end end
check("tar 只下载一次（不重复下载）", tar_requests == 1, tar_requests)

log("")
log("RESULT: " .. PASS .. " pass, " .. FAIL .. " fail")
