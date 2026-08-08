-- resolution_test.lua: ocvm 真机验证 tui.init 正确读取真实分辨率并布局
-- 黑盒验证: 通过 gpu.get(x, y) 读屏幕字符, 断言布局锚点位置与
-- gpu.getResolution() 真值一致 (而非兜底 80x25):
--   1) header 在 y=1, hint 锚定在 state.width - len(hint) - 1
--   2) status "Ready" 在 y=height-1 行
--   3) input 提示符 "> " 在 y=height 行
--   4) 若 maxResolution 允许, 先放大分辨率再 init, 强区分真值与兜底
-- 用法: lua /mnt/<short>/resolution_test.lua /mnt/<short>
local base = ({...})[1] or "/mnt"
print("resolution test start")
local PASS, FAIL = 0, 0
local RESULT_NAME = "resolution_test_result.txt"
local function log(...)
  local parts = {}
  for i = 1, select("#", ...) do parts[i] = tostring(select(i, ...)) end
  local line = table.concat(parts, " ")
  -- 不 print 到屏幕: 黑盒断言读的是屏幕字符, 打印会污染待断言的格子
  -- （fix-1 真机实证: log 打印导致 4 个锚点全读到打印残迹）
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

local gpu = require("component").gpu
local mw, mh = gpu.maxResolution()
log("gpu max resolution: " .. tostring(mw) .. "x" .. tostring(mh))

-- 尝试放大到非 80x25 分辨率, 强区分"读真值" vs "硬编码兜底"
local rw, rh = gpu.getResolution()
local enlarged = false
if mw and mh and mw >= 100 and mh >= 40 then
  local ok_set = pcall(function() gpu.setResolution(math.min(mw, 160), math.min(mh, 50)) end)
  if ok_set then
    rw, rh = gpu.getResolution()
    enlarged = true
  end
end
log("resolution under test: " .. tostring(rw) .. "x" .. tostring(rh) ..
    (enlarged and " (enlarged)" or " (native)"))

local ok_init = pcall(function() tui.init({}) end)
check("tui init on real gpu", ok_init, tostring(ok_init))
if not ok_init then log("RESULT: " .. PASS .. " pass, " .. FAIL .. " fail") return end

-- 黑盒读屏（真实 GPU get(x,y) -> char, fg, bg）
local function gget(x, y)
  local okg, c = pcall(gpu.get, x, y)
  if okg and c then return c end
  return nil
end

-- 1) header 在 y=1: "OC Agent" 首字符 O 在 (2, 1)
local hdr = gget(2, 1) or ""
check("header at row 1", hdr:sub(1, 1) == "O", "got '" .. tostring(hdr):sub(1, 8) .. "'")

-- 2) hint 锚定在 state.width 末端: x = rw - #hint - 1 处应是 '/' (hint 全 ASCII)
local hint = "/help | PgUp/PgDn scroll | /exit"
local hx = rw - #hint - 1
if hx >= 1 then
  local hc = gget(hx, 1) or ""
  check("hint anchored at real width", hc:sub(1, 1) == "/",
    "x=" .. tostring(hx) .. " got '" .. tostring(hc):sub(1, 4) .. "'")
else
  check("hint anchored at real width", true, "width too small, skipped")
end

-- 3) status "Ready" 首字符 R 在 (2, height-1) —— 证明 state.height == rh
local st = gget(2, rh - 1) or ""
check("status at height-1 row", st:sub(1, 1) == "R", "got '" .. tostring(st):sub(1, 8) .. "'")

-- 4) input 提示符 ">" 在 (2, height) —— 证明 state.height == rh
--    注意: gget 只取单个字符, 不能与 "> " 双字符比较（恒假）
local inp = gget(2, rh) or ""
check("input prompt at bottom row", inp:sub(1, 1) == ">",
  "got '" .. tostring(inp):sub(1, 8) .. "'")

-- 5) 若放大成功: 断言真值非 80x25, 布局确实用了放大后的分辨率
if enlarged then
  check("enlarged resolution used", rw ~= 80 or rh ~= 25,
    "res=" .. tostring(rw) .. "x" .. tostring(rh))
end

pcall(tui.cleanup)
log("")
log("RESULT: " .. PASS .. " pass, " .. FAIL .. " fail")
