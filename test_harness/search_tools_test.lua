-- search_tools_test.lua: ocvm 真机验证 search_files 工具
-- 骨架仿 paste_multiline_test.lua / resolution_test.lua:
--   base 参数、_TEST_MODE=true、pcall(dofile, agent_path)、
--   require agent.tools.file、log/check 模式。
-- v0.3.124: glob 工具已删（OpenOS 有 find），本测试只验 search_files。
-- 不 print 到屏幕（黑盒惯例：打印会污染待断言内容/屏幕），只写结果文件。
-- 断言:
--   1) agent.tools.file 模块加载成功且导出 exec
--   2) agent.tools registry 的 list() 含 search_files
--   3) exec("search_files", {pattern="RESULT_NAME", path=base, glob="*.lua"})
--      返回含本脚本文件名的匹配行
-- 用法: lua /mnt/<short>/search_tools_test.lua /mnt/<short>
local base = ({...})[1] or "/mnt"
print("search tools test start")
local PASS, FAIL = 0, 0
local RESULT_NAME = "search_tools_test_result.txt"
local function log(...)
  local parts = {}
  for i = 1, select("#", ...) do parts[i] = tostring(select(i, ...)) end
  local line = table.concat(parts, " ")
  -- 不 print 到屏幕（黑盒断言同款约定: log 打印会污染屏幕/待断言内容）;
  -- 只写结果文件, 由宿主机侧轮询读取。
  local fs_ok, fs = pcall(require, "filesystem")
  if fs_ok and fs.list then
    for item in fs.list("/mnt") do
      local okf, f = pcall(io.open, "/mnt/" .. item .. "/" .. RESULT_NAME, "a")
      if okf and f then f:write(line .. "\n") f:close() end
    end
  end
end
pcall(function() io.open(base .. "/" .. RESULT_NAME, "w"):close() end)
local function check(name, cond, detail)
  if cond then PASS = PASS + 1 log("PASS " .. name)
  else FAIL = FAIL + 1 log("FAIL " .. name .. (detail and (" -- " .. tostring(detail)) or "")) end
end

local fs = require("filesystem")
local agent_path = fs.exists(base .. "/agent.lua") and (base .. "/agent.lua") or nil
if not agent_path then
  for item in fs.list("/mnt") do
    local full = "/mnt/" .. item
    if fs.exists(full .. "/agent.lua") then agent_path = full .. "/agent.lua" break end
  end
end
log("agent at " .. tostring(agent_path))
_TEST_MODE = true
local ok, err = pcall(dofile, agent_path)
check("agent loads", ok, err)
if not ok then log("RESULT: " .. PASS .. " pass, " .. FAIL .. " fail") return end

-- 1) tools 模块加载
local ok_file, file_mod = pcall(require, "agent.tools.file")
check("tools module loads", ok_file and type(file_mod) == "table"
  and type(file_mod.exec) == "function", tostring(ok_file))
if not (ok_file and type(file_mod) == "table" and type(file_mod.exec) == "function") then
  log("RESULT: " .. PASS .. " pass, " .. FAIL .. " fail") return
end

-- 2) search_files 已注册（agent.tools registry list() 含）
local ok_tools, tools_mod = pcall(require, "agent.tools")
local has_search = false
if ok_tools and type(tools_mod) == "table" and type(tools_mod.list) == "function" then
  for _, decl in ipairs(tools_mod.list()) do
    local def = decl and decl["function"]
    local name = def and def.name
    if name == "search_files" then has_search = true end
  end
end
check("search_files registered", has_search, "list() missing search_files")

-- 3) search_files 找到 RESULT_NAME 内容行（含本脚本文件名）
local ok_s, search_res = pcall(file_mod.exec, "search_files",
  {pattern = "RESULT_NAME", path = base, glob = "*.lua"})
check("search_files finds content", ok_s and type(search_res) == "string"
  and search_res:find("search_tools_test.lua", 1, true) ~= nil,
  "res='" .. tostring(search_res and search_res:sub(1, 300) or "nil") .. "'")

log("")
log("RESULT: " .. PASS .. " pass, " .. FAIL .. " fail")
