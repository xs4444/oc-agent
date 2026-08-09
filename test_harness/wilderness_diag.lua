-- wilderness_diag.lua: 荒野大师"空回车多状态栏"诊断
-- 三个模拟器（ocvm/OCEmu）已确认无此现象，差异在荒野大师客户端渲染层，
-- 需要真机屏幕证据定位。本脚本在你的荒野大师环境跑：
--
--   用法: lua wilderness_diag.lua
--   步骤: 1) 脚本启动 TUI 后, 连续按 4 次回车（输入框保持空）
--         2) 再按 Ctrl+C 结束输入
--         3) 脚本自动转储屏幕 before/after 对比, 结果写入结果文件
--         4) 把结果文件内容贴回给开发者
--
-- 原理: gpu.get 读屏逐格转储 + 统计状态文本出现的所有行号——
-- 若"多个状态栏"是 GPU 帧多行绘制, after 转储会直接暴露。

local agent_path = "/home/agent/agent.lua"
if not pcall(function() return io.open(agent_path, "r") end) then
  -- 回退: 当前目录
  agent_path = "agent.lua"
end

local RESULT_NAME = "diag_result.txt"
local function write_result(text)
  for _, p in ipairs({"/home/" .. RESULT_NAME, "/mnt/" .. RESULT_NAME}) do
    local ok, f = pcall(io.open, p, "w")
    if ok and f then f:write(text) f:close() end
  end
end

local out = {}
local function log(...)
  local parts = {}
  for i = 1, select("#", ...) do parts[i] = tostring(select(i, ...)) end
  local line = table.concat(parts, " ")
  out[#out + 1] = line
end

-- 加载 agent（模块注册，不跑 main）
_TEST_MODE = true
local ok, err = pcall(dofile, agent_path)
if not ok then
  log("LOAD FAILED: " .. tostring(err))
  write_result(table.concat(out, "\n"))
  error("load failed")
end
local ok_tui, tui = pcall(require, "agent.tui")
if not (ok_tui and type(tui) == "table") then
  log("tui unavailable")
  write_result(table.concat(out, "\n"))
  return
end
tui.init({})

local gpu = require("component").gpu
local w, h = gpu.getResolution()
log("resolution: " .. tostring(w) .. "x" .. tostring(h))

-- 全屏转储: 逐行, 行尾去空白; 记录含状态文本的行
local function dump()
  local lines = {}
  local hits = {}
  for y = 1, h do
    local row = {}
    for x = 1, w do
      local okg, c = pcall(gpu.get, x, y)
      row[x] = okg and (c or " ") or " "
    end
    local s = table.concat(row):gsub("%s+$", "")
    lines[y] = s
    if s:find("Ready", 1, true) or s:find("Thinking", 1, true) or s:find("Running", 1, true) then
      hits[#hits + 1] = tostring(y) .. ":[" .. s .. "]"
    end
  end
  return lines, hits
end

local before, hits_before = dump()
log("=== BEFORE (状态文本行) ===")
for _, x in ipairs(hits_before) do log(x) end
log("")
log("请现在连续按 4 次回车（空输入框），再按 Ctrl+C...")
log("（等待 8 秒）")

-- 进入输入循环, 用户按键由 readInput 处理; Ctrl+C 返回 nil
local deadline = os.clock() + 8
local r = "?"
local ok_r, ret = pcall(tui.readInput)
if ok_r then
  log("readInput returned: " .. tostring(ret or "nil(Ctrl+C)"))
else
  log("readInput error: " .. tostring(ret))
end

local after, hits_after = dump()
log("")
log("=== AFTER (状态文本行) ===")
for _, x in ipairs(hits_after) do log(x) end
log("")
log("=== 状态栏行 (h-1) ===")
log("before: [" .. before[h - 1] .. "]")
log("after:  [" .. after[h - 1] .. "]")
log("=== 输入行 (h) ===")
log("before: [" .. before[h] .. "]")
log("after:  [" .. after[h] .. "]")
log("")
log("=== 全屏差异行 ===")
local diffs = 0
for y = 1, h do
  if before[y] ~= after[y] then
    diffs = diffs + 1
    log("row " .. y .. " before=[" .. tostring(before[y]) .. "]")
    log("     after =[" .. tostring(after[y]) .. "]")
  end
end
log("diff rows: " .. diffs)
log("")
log("DONE")

pcall(tui.cleanup)
write_result(table.concat(out, "\n"))
print(table.concat(out, "\n"))
