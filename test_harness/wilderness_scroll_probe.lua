-- wilderness_scroll_probe.lua: 荒野大师滚动触发条件精确定位
-- 背景：TUI 状态栏/输入行内容出现在终端历史（用户贴屏证据），v0.3.39 探测
-- 用 gpu.set 单点写 y=h 可能未覆盖真实滚动触发（fill 整行？写 h-1？）。
-- 本脚本逐项测试滚动触发条件，输出每步 y=1/y=2 是否被波及（滚动会把
-- 原 y=2 顶到 y=1）。
--   用法: lua wilderness_scroll_probe.lua
local out = {}
local function log(...)
  local parts = {}
  for i = 1, select("#", ...) do parts[i] = tostring(select(i, ...)) end
  local line = table.concat(parts, " ")
  out[#out + 1] = line
  print(line)
end
local function write_result(text)
  for _, p in ipairs({"/home/scrollprobe_result.txt", "/mnt/scrollprobe_result.txt"}) do
    local ok, f = pcall(io.open, p, "w")
    if ok and f then f:write(text) f:close() end
  end
end

local component = require("component")
local gpu = component.gpu
local w, h = gpu.getResolution()
log("resolution: " .. tostring(w) .. "x" .. tostring(h))

-- 读指定行前 12 字符
local function peek(y)
  local chars = {}
  for x = 1, 12 do
    local okg, c = pcall(gpu.get, x, y)
    chars[x] = okg and (c or " ") or "?"
  end
  return table.concat(chars):gsub("%s+$", "")
end

-- 重置: 在 y=1/y=2 写标记行
local function reset_lines()
  gpu.setBackground(0x000000)
  gpu.setForeground(0xFFFFFF)
  pcall(gpu.fill, 1, 1, w, 3, " ")
  pcall(gpu.set, 1, 1, "MARK1-LINE1")
  pcall(gpu.set, 1, 2, "MARK2-LINE2")
  pcall(gpu.set, 1, 3, "MARK3-LINE3")
end

local function step(name, fn)
  reset_lines()
  local before1, before2 = peek(1), peek(2)
  pcall(fn)
  local after1, after2 = peek(1), peek(2)
  local moved = (before1 ~= after1) or (before2 ~= after2)
  log(string.format("STEP %-28s y1: %-10s -> %-10s | y2: %-10s -> %-10s | %s",
    name, before1, after1, before2, after2,
    moved and "*** SCROLLED ***" or "no move"))
  -- 清理
  pcall(gpu.fill, 1, 1, w, h, " ")
end

log("=== 滚动触发条件测试（y=h 或 y=h-1 写入是否顶动 y=1/y=2）===")
step("set(1,h,'Z') 单点", function() gpu.set(1, h, "Z") end)
step("fill(1,h,10,1,'X') 整行", function() gpu.fill(1, h, 10, 1, "X") end)
step("set(1,h-1,'Z') 单点", function() gpu.set(1, h - 1, "Z") end)
step("fill(1,h-1,10,1,'X') 整行", function() gpu.fill(1, h - 1, 10, 1, "X") end)
step("set(w,h,'Z') 右上角", function() gpu.set(w, h, "Z") end)
step("fill(1,h,width,1) 全宽", function() gpu.fill(1, h, w, 1, "X") end)
step("set(1,1,'X') 顶行覆写", function() gpu.set(1, 1, "X") end)

log("")
log("=== 终端层写入（print 是否滚动 GPU 帧）===")
reset_lines()
local b1, b2 = peek(1), peek(2)
print("TERM-TEST-LINE")
local a1, a2 = peek(1), peek(2)
log(string.format("print -> y1: %-10s -> %-10s | y2: %-10s -> %-10s | %s",
  b1, a1, b2, a2, (b1 ~= a1 or b2 ~= a2) and "*** SCROLLED ***" or "no move"))
pcall(gpu.fill, 1, 1, w, h, " ")

log("")
log("=== 光标/换行行为 ===")
reset_lines()
local ok_t, term = pcall(require, "term")
if ok_t and term.getCursor then
  local cx, cy = term.getCursor()
  log("term cursor before: " .. tostring(cx) .. "," .. tostring(cy))
  pcall(term.setCursor, 5, 5)
  local cx2, cy2 = term.getCursor()
  log("term cursor after setCursor(5,5): " .. tostring(cx2) .. "," .. tostring(cy2))
  -- 光标处写字符后读 GPU
  pcall(term.write, "CURSORX")
  local got = peek(5)
  log("after term.write at (5,5), y5 head: [" .. got .. "]")
end

log("")
log("=== 当前屏幕转储（前 5 行 + 后 3 行）===")
pcall(gpu.fill, 1, 1, w, h, " ")
gpu.set(1, 1, "T1-HEADER")
gpu.set(1, 2, "T2-CONTENT")
gpu.set(1, h - 1, "T3-STATUS")
gpu.set(1, h, "T4-INPUT")
for y = 1, math.min(5, h) do log("screen y" .. y .. ": [" .. peek(y) .. "]") end
for y = h - 2, h do log("screen y" .. y .. ": [" .. peek(y) .. "]") end

write_result(table.concat(out, "\n"))
log("")
log("PROBE DONE — 请把以上输出贴回给开发者")
