-- tui_smoke_test.lua: ocvm 真机冒烟——TUI 用真实 GPU 渲染不崩。
-- 验证: agent 加载 / tui 模块 init(真实分辨率) / 打印+重绘 / 单色检测 /
-- 清理。无需网络。
-- 用法: lua /mnt/<short>/tui_smoke_test.lua /mnt/<short>
local base = ({...})[1] or "/mnt"
print("tui smoke start, base=" .. base)
local PASS, FAIL = 0, 0
local RESULT_NAME = "tui_smoke_result.txt"
local function log(...)
  local parts = {}
  for i = 1, select("#", ...) do parts[i] = tostring(select(i, ...)) end
  local line = table.concat(parts, " ")
  print(line)
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
local agent_path
for item in fs.list("/mnt") do
  local full = "/mnt/" .. item
  if fs.exists(full .. "/agent.lua") then agent_path = full .. "/agent.lua" break end
end
if not agent_path then log("ERROR: agent.lua not found") log("RESULT: 0 pass, 0 fail") return end

_TEST_MODE = true
local ok, err = pcall(dofile, agent_path)
check("agent loads", ok, err)
if not ok then log("RESULT: " .. PASS .. " pass, " .. FAIL .. " fail") return end

-- TUI 模块（构建产物内嵌）
local ok_tui, tui = pcall(require, "agent.tui")
check("tui module available in build", ok_tui and type(tui) == "table", tostring(ok_tui))
if not (ok_tui and type(tui) == "table") then log("RESULT: " .. PASS .. " pass, " .. FAIL .. " fail") return end

-- 硬件检测
local component = require("component")
local has_gpu = component.isAvailable and component.isAvailable("gpu")
local has_screen = component.isAvailable and component.isAvailable("screen")
local has_kb = component.isAvailable and component.isAvailable("keyboard")
log("hardware: gpu=" .. tostring(has_gpu) .. " screen=" .. tostring(has_screen)
  .. " keyboard=" .. tostring(has_kb))
check("gpu+screen present (TUI 可启用)", has_gpu and has_screen)

-- 真实 GPU 初始化 + 渲染
local ok_init, init_err = pcall(function()
  tui.init({})
  local gpu = component.gpu
  local w, h = gpu.getResolution()
  log("resolution: " .. tostring(w) .. "x" .. tostring(h))
  local ok_depth, depth = pcall(gpu.getDepth)
  log("depth: " .. tostring(ok_depth and depth or "?"))
  if ok_depth and depth == 1 then
    tui.init({monochrome = true})
    log("monochrome mode enabled (1-bit)")
  end
  -- 内容: 角色消息 + 长文本换行 + 中文
  tui.printRole("user", "hello from tui smoke test")
  tui.printRole("assistant", "运行在真实 GPU 上的 TUI 渲染测试")
  tui.print(string.rep("wrap test ", 40), tui.colors.dim)
  tui.printToolCall("shell_execute", '{"command":"echo hi"}')
  -- 滚动 + 状态
  tui.scrollUp(2)
  tui.scrollToBottom()
  tui.setStatus("Smoke done")
  tui.drawInput()
  return true
end)
check("tui init+render on real gpu", ok_init, init_err)

-- 内容区消息数（print 应产生多条换行记录）
local n_hist = #tui.history()
check("history populated", n_hist >= 4, "n=" .. tostring(n_hist))

-- 清理恢复终端
local ok_clean = pcall(tui.cleanup)
check("tui cleanup restores terminal", ok_clean)

log("")
log("RESULT: " .. PASS .. " pass, " .. FAIL .. " fail")
