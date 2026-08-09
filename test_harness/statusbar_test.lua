-- statusbar_test.lua: 空回车后状态栏唯一性验证（真机渲染）
-- 场景: 模拟空回车路径（readInput 空回车留在输入循环, 仅 drawInput 重绘,
-- 不返回主循环）——反复空回车后断言: 状态栏行 (h-1) 显示 status,
-- 屏幕其他行无状态文本残影（无"多个状态栏"）。
-- 钩子版（无协程 event.pull）：直接调 setStatus/drawStatus/drawInput 渲染,
-- 结果写文件不 print 屏幕（黑盒断言读屏幕字符, 打印会污染）。
-- 用法: lua /mnt/<short>/statusbar_test.lua /mnt/<short>
local base = ({...})[1] or "/mnt"
local PASS, FAIL = 0, 0
local RESULT_NAME = "statusbar_test_result.txt"
local function log(...)
  local parts = {}
  for i = 1, select("#", ...) do parts[i] = tostring(select(i, ...)) end
  local line = table.concat(parts, " ")
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

local ok_tui, tui = pcall(require, "agent.tui")
check("tui module available", ok_tui and type(tui) == "table", tostring(ok_tui))
if not (ok_tui and type(tui) == "table") then log("RESULT: " .. PASS .. " pass, " .. FAIL .. " fail") return end

local ok_init = pcall(function() tui.init({}) end)
check("tui init on real gpu", ok_init, tostring(ok_init))
if not ok_init then log("RESULT: " .. PASS .. " pass, " .. FAIL .. " fail") return end

local gpu = require("component").gpu
local w, h = gpu.getResolution()
log("resolution: " .. tostring(w) .. "x" .. tostring(h))

-- 读屏 helper（逐格拼行）
local function read_row(y)
  local parts = {}
  for x = 1, w do
    local okg, c = pcall(gpu.get, x, y)
    parts[x] = okg and (c or " ") or " "
  end
  return table.concat(parts):gsub("%s+$", "")
end

-- ═══ 场景 A: 空回车前的初始状态 ═══
tui.setStatus("Ready")
local row_h1 = read_row(h - 1)
check("statusbar shows Ready initially", row_h1:find("Ready", 1, true) ~= nil, row_h1:sub(1, 60))

-- ═══ 场景 B: 反复空回车（readInput 留在循环, 每次 drawInput 重绘）═══
for i = 1, 8 do
  pcall(tui.drawInput)  -- 空 buffer 重绘（模拟空回车后的重绘路径）
end
-- 空回车不应改变状态栏（主循环未返回, 状态不变）
local row_h1_b = read_row(h - 1)
check("statusbar unchanged after empty enters", row_h1_b == row_h1,
  "before='" .. row_h1:sub(1, 60) .. "' after='" .. row_h1_b:sub(1, 60) .. "'")

-- ═══ 场景 C: 状态切换后仅一行状态栏（无残影/无多行）═══
tui.setStatus("Thinking...")
tui.setStatus("Ready")
-- 检查整屏: 状态文本只能出现在 h-1 行, 其他行不得含 "Ready"/"Thinking"
local leak = nil
for y = 1, h do
  if y ~= h - 1 then
    local row = read_row(y)
    if row:find("Ready", 1, true) or row:find("Thinking", 1, true) then
      leak = "row " .. tostring(y) .. ": '" .. row:sub(1, 60) .. "'"
      break
    end
  end
end
check("no status text leak on other rows", leak == nil, leak)
-- 输入行（h）应有提示符（空回车后仍正常）
local row_h = read_row(h)
check("input row has prompt", row_h:find(">", 1, true) ~= nil, row_h:sub(1, 40))

-- ═══ 场景 D: 完整渲染链（redrawContent 后状态栏仍唯一）═══
pcall(tui.print, "test content line")
pcall(tui.redrawContent)
leak = nil
for y = 1, h do
  if y ~= h - 1 then
    local row = read_row(y)
    if row:find("Ready", 1, true) or row:find("Thinking", 1, true) then
      leak = "row " .. tostring(y) .. ": '" .. row:sub(1, 60) .. "'"
      break
    end
  end
end
check("no status leak after redrawContent", leak == nil, leak)
local row_h1_d = read_row(h - 1)
check("statusbar intact after redrawContent", row_h1_d:find("Ready", 1, true) ~= nil,
  row_h1_d:sub(1, 60))

pcall(tui.cleanup)
log("")
log("RESULT: " .. PASS .. " pass, " .. FAIL .. " fail")
