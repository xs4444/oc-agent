-- test_docs_interact.lua: ocvm 验证 docs.lua 交互引导（安装选盘/卸载/状态）
-- 注入 fake internet + 模拟 io.read 输入，跑真实 docs.lua 全流程
-- 用法: lua /mnt/<short>/test_docs_interact.lua /mnt/<short>
local base = ({...})[1] or "/mnt"
local PASS, FAIL = 0, 0
local function log(...)
  local parts = {}
  for i = 1, select("#", ...) do parts[i] = tostring(select(i, ...)) end
  local line = table.concat(parts, " ")
  print(line)
  local f = io.open(base .. "/test_docs_interact_result.txt", "a")
  if f then f:write(line .. "\n") f:close() end
end
io.open(base .. "/test_docs_interact_result.txt", "w"):close()
local function check(name, cond, detail)
  if cond then PASS = PASS + 1 log("PASS " .. name)
  else FAIL = FAIL + 1 log("FAIL " .. name .. (detail and (" -- " .. tostring(detail)) or "")) end
end

local fs = require("filesystem")

-- ── 假 internet（docs.json/oc-docs.tar 从挂载盘读）──
local json_data = io.open(base .. "/docs.json", "r"):read("*a")
local tar_file = io.open(base .. "/oc-docs.tar", "rb")
local tar_data = tar_file:read("*a")
tar_file:close()
package.loaded["internet"] = {
  request = function(url)
    local data
    if url:find("docs%.json") then data = json_data
    elseif url:find("oc%-docs%.tar") then data = tar_data end
    if not data then return nil end
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
package.loaded["component"] = require("component")
package.loaded["filesystem"] = require("filesystem")

-- ── 模拟用户输入队列 ──
local inputs = {}
local orig_read = io.read
io.read = function(...)
  local n = table.remove(inputs, 1)
  log("  [输入] " .. tostring(n))
  return n
end

local function run_docs(...)
  local out_lines = {}
  local orig_print = print
  print = function(...)
    local p = {}
    for i = 1, select("#", ...) do p[i] = tostring(select(i, ...)) end
    out_lines[#out_lines + 1] = table.concat(p, " ")
  end
  local chunk = assert(loadfile(base .. "/docs.lua"))
  local ok, err = pcall(chunk, ...)
  print = orig_print
  for _, l in ipairs(out_lines) do log("  " .. l) end
  return ok, err, table.concat(out_lines, "\n")
end

-- ── 场景 1: 直接路径安装（旧用法）──
local dest1 = base .. "/doc"
log("--- 场景1: 直接路径安装 ---")
local ok1, err1, out1 = run_docs(dest1)
check("path install runs", ok1, err1)
check("path install writes files", fs.exists(dest1 .. "/api/robot.md"), out1:sub(1, 200))
check("path install writes version", fs.exists(dest1 .. "/version.txt"))

-- ── 场景 2: status 显示已安装 ──
log("--- 场景2: status ---")
local ok2, err2, out2 = run_docs("status")
check("status runs", ok2, err2)
check("status shows installed", out2:find("已安装") ~= nil and out2:find(dest1) ~= nil, out2:sub(1, 300))

-- ── 场景 3: 交互安装（无参 → 选第一个盘）──
log("--- 场景3: 交互安装 ---")
inputs = {"1", "1"}  -- 操作=1(安装), 盘=1
local ok3, err3, out3 = run_docs()
check("interactive install runs", ok3, err3)
check("interactive picks disk 1", out3:find("文档已更新到") ~= nil or out3:find("已是最新") ~= nil, out3:sub(1, 300))

-- ── 场景 4: 交互卸载（选第一个已安装 + 确认 y）──
log("--- 场景4: 交互卸载 ---")
inputs = {"2", "1", "y"}  -- 操作=2(卸载), 位置=1, 确认=y
local ok4, err4, out4 = run_docs()
check("interactive uninstall runs", ok4, err4)
local removed_ok = not fs.exists(base .. "/doc")
check("uninstall removes doc dir", removed_ok, out4:sub(1, 300))

-- ── 场景 5: status 确认已卸载 ──
local ok5, err5, out5 = run_docs("status")
check("status after uninstall", ok5, err5)

io.read = orig_read
log("")
log("RESULT: " .. PASS .. " pass, " .. FAIL .. " fail")
