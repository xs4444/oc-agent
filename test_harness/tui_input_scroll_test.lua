-- ════════════════════════════════════════════════════════════════
-- TUI Input Scroll + Auto-Height Regression Test（v0.3.112）
--
-- 真机 bug 回归 + 用户设计新功能验证:
--   A. 滚轮快速滚动闪烁（即使到顶/底）——根因: scrollUp/Down/ToTop/
--      ToBottom 无条件 lineCache={} + redrawContent（fill 全屏擦除再
--      重画）→ 到顶/底 offset 不变仍全屏重绘 = 高频全屏 fill = 闪黑。
--      修复: scrollView() 边界 no-op + 只重绘内容区行（无 fill）。
--   B. 输入框自动增高 + 滚轮换行（用户原话: "类似其他经典 agent 的
--      输入框。根据行数自动增高（占用对话行），到一定高度时，滚轮
--      换行。通过光标所在的位置或最后点击的位置，分辨 scroll 的是
--      对话框还是输入框。"）——窗口化输入框（MAX_INPUT_HEIGHT=8）+
--      lastTouchY 路由滚轮。
--
-- 依赖 oc_mock 增强（v0.3.112）: debug_gpu_set_count()/set_reset()
-- （gpu.set 调用计数——断言边界滚动 no-op 时不再全屏重绘）。
--
-- 运行:
--   独立:  lua test_harness/tui_input_scroll_test.lua
--   接入:  run_tests.lua 设置 _IN_RUN_TESTS=true 后 dofile，
--          本文件跳过 os.exit 并 return pass, fail 由宿主累加。
-- ════════════════════════════════════════════════════════════════

io.stdout:setvbuf("no")

-- 环境搭建（幂等: 被 run_tests dofile 时 oc_mock 已加载、agent 已加载）
if not package.loaded["oc_mock"] then
  package.path = "test_harness/?.lua;" .. package.path
end
if not os.sleep then os.sleep = function() end end
local oc_mock = require("oc_mock")
component = oc_mock.component
computer = oc_mock.computer
filesystem = oc_mock.filesystem
shell = oc_mock.shell
internet = oc_mock.internet
serialization = oc_mock.serialization
event = oc_mock.event
keyboard = oc_mock.keyboard
for k, v in pairs(oc_mock) do
  if type(v) == "table" then package.loaded[k] = v end
end
_TEST_MODE = true
if not package.loaded["agent.tui"] then
  pcall(dofile, "src/agent/init.lua")
end
local ok_tui, tui = pcall(require, "agent.tui")
if not ok_tui or type(tui) ~= "table" then
  print("FAIL tui_input_scroll_test: agent.tui load failed: " .. tostring(ok_tui))
  os.exit(1)
end

local pass, fail = 0, 0
local function test(name, cond, detail)
  if cond then
    pass = pass + 1
    print("PASS " .. name)
  else
    fail = fail + 1
    print("FAIL " .. name .. (detail and (" -- " .. tostring(detail)) or ""))
  end
end

local function q(...)
  local t = {...}
  table.insert(oc_mock._event_queue, t)
end
local function qKey(char, code)
  q("key_down", "kb-addr", char, code, "player")
end
local function cell(x, y)
  local scr = component.debug_gpu_screen()
  return (scr[y] and scr[y][x]) or {ch = "", fg = -1, bg = -1}
end

-- 30 行历史（ih=1 时内容区 h=22 → maxScroll=8; ih=8 时 h=15 → maxScroll=15）
local function fresh30()
  component.debug_gpu_reset()
  pcall(tui.init, {})
  for i = 1, 30 do tui.print("line " .. i, tui.colors.user) end
  tui.redrawContent()
end

-- ════════════════════════════════════════════════════════════════
-- A. 滚动防闪烁（v0.3.112）
--    边界 no-op: 到顶/到底后继续滚 → gpu.set 计数 0（零重绘）;
--    有效滚动: 计数 > 0（每行一次 set 覆盖，无 fill 全屏擦除）。
-- ════════════════════════════════════════════════════════════════
fresh30()
tui.scrollToTop()  -- offset 0 → 8
component.debug_gpu_set_reset()
tui.scrollUp(1)    -- 已在顶部（8=8）→ no-op
test("A: scrollUp at top is no-op (0 gpu.set)",
  component.debug_gpu_set_count() == 0,
  "count=" .. tostring(component.debug_gpu_set_count()))
tui.scrollToBottom()  -- 8 → 0（有效滚动, 有重绘）
component.debug_gpu_set_reset()
tui.scrollDown(1)  -- 已在底部（0=0）→ no-op
test("A: scrollDown at bottom is no-op (0 gpu.set)",
  component.debug_gpu_set_count() == 0,
  "count=" .. tostring(component.debug_gpu_set_count()))
component.debug_gpu_set_reset()
tui.scrollUp(3)    -- 0 → 3（有效滚动: 只重绘内容区行, 不 fill）
test("A: real scroll redraws without crash", true)
test("A: real scroll uses row redraw (set count > 0)",
  component.debug_gpu_set_count() > 0,
  "count=" .. tostring(component.debug_gpu_set_count()))

-- ════════════════════════════════════════════════════════════════
-- A2. 滚动残留文本（v0.3.113 回归修复）: scrollView 逐行 g.set 覆盖
--     （无 fill 全屏擦除）——drawRow 行尾若不补空格到满宽, 短行滚动
--     覆盖长行时残留旧字符（行尾不补满）。构造: 长行(40 x) 在
--     history[1], 滚到顶（长行上屏）再滚回底（短行覆盖同一行）
--     → 断言短行右侧全空格。
-- ════════════════════════════════════════════════════════════════
component.debug_gpu_reset()
pcall(tui.init, {})
tui.debug_set_buffer("l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\nl9\nl10\nl11\nl12")  -- ih=8 → h=15
tui.print(string.rep("x", 40), tui.colors.user)   -- history[1] 长行（40 列）
for i = 2, 15 do tui.print("line " .. i, tui.colors.user) end
tui.print("S", tui.colors.user)                   -- history[16] 短行
-- maxScroll = max(0, 16-15) = 1
tui.scrollToTop()     -- offset 1: 行2 = history[1] 长行（40 x 上屏）
tui.scrollToBottom()  -- offset 0: 行2 = history[2] 短行覆盖同一行
test("A2: scroll residue cleared (short row right side spaces)",
  cell(10, 2).ch == " " and cell(30, 2).ch == " ",
  "c10=" .. tostring(cell(10, 2).ch) .. " c30=" .. tostring(cell(30, 2).ch))
test("A2: short row content intact", cell(2, 2).ch == "l" and cell(7, 2).ch == "2",
  "c2=" .. tostring(cell(2, 2).ch) .. " c7=" .. tostring(cell(7, 2).ch))

-- ════════════════════════════════════════════════════════════════
-- B1. 输入框自动增高: inputHeight = 显示行数（上限 8）; 内容区/状态栏
--     随之让位（status y = 屏高 - inputHeight; 输入框顶 = 屏高-ih+1）。
-- ════════════════════════════════════════════════════════════════
component.debug_gpu_reset()
pcall(tui.init, {})
test("B1: default input height 1", tui.debug_input_height() == 1,
  "h=" .. tostring(tui.debug_input_height()))
tui.debug_set_buffer("l1\nl2\nl3")
test("B1: 3-line buffer -> height 3", tui.debug_input_height() == 3,
  "h=" .. tostring(tui.debug_input_height()))
pcall(tui.drawInput)
pcall(tui.redrawContent)
test("B1: status row moved to y=22 (25-3)", cell(2, 22).ch == "R",
  "ch=" .. tostring(cell(2, 22).ch))
test("B1: input box rows 23-25: line1 at (5,23)", cell(5, 23).ch == "l",
  "ch=" .. tostring(cell(5, 23).ch))
test("B1: multiline prompt >> at col 2", cell(2, 23).ch == ">",
  "ch=" .. tostring(cell(2, 23).ch))
test("B1: line3 at (5,25)", cell(5, 25).ch == "l" and cell(6, 25).ch == "3",
  "c5=" .. tostring(cell(5, 25).ch) .. " c6=" .. tostring(cell(6, 25).ch))
tui.debug_set_buffer("l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\nl9\nl10\nl11\nl12")
test("B1: 12-line buffer capped at height 8", tui.debug_input_height() == 8,
  "h=" .. tostring(tui.debug_input_height()))
pcall(tui.redrawContent)
test("B1: with height 8 status at y=17", cell(2, 17).ch == "R",
  "ch=" .. tostring(cell(2, 17).ch))

-- ════════════════════════════════════════════════════════════════
-- B2. 输入窗口滚轮: lastTouchY 在输入框区域 → 滚 inputScroll; 边界
--     no-op（计数与基线相同 = 零额外重绘）; 有效滚动只重绘输入框。
--     12 行 paste: ih=8, 输入框顶=18, maxScroll=12-8=4。
--     注: readInput 入口清空 buffer → 每次 run 都以 clipboard 粘贴
--     重建多行内容（正是真机用户粘贴多行的生产路径）。粘贴后光标在
--     末行 → drawInput 光标跟随滚到 inputScroll=4（maxScroll）——
--     先 4 次上滚到顶（s=0）再测各边界。
-- ════════════════════════════════════════════════════════════════
local function paste12()
  q("clipboard", "kb-addr", "l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\nl9\nl10\nl11\nl12")
end
-- run0: paste + touch 输入框 (5,18) → 基线（无滚轮; 光标跟随 → s=4）
component.debug_gpu_reset()
pcall(tui.init, {})
paste12()
q("touch", "screen-addr", 5, 18, 0)
q("interrupted")
pcall(tui.readInput, nil)
local c_base = component.debug_gpu_set_count()
test("B2: paste cursor-follow scrolls to max (s=4)", tui.debug_input_scroll() == 4,
  "s=" .. tostring(tui.debug_input_scroll()))
-- run1: paste + touch + 上滚 ×4 → 到顶 s=0
component.debug_gpu_set_reset()
paste12()
q("touch", "screen-addr", 5, 18, 0)
for _ = 1, 4 do q("scroll", "screen-addr", 5, 18, 1) end
q("interrupted")
pcall(tui.readInput, nil)
local c_top = component.debug_gpu_set_count()
test("B2: 4x wheel up reaches top (s=0)", tui.debug_input_scroll() == 0,
  "s=" .. tostring(tui.debug_input_scroll()))
-- run2: 同 run1 + 再上滚 ×1（s=0 边界）→ 计数 == c_top（零额外重绘）
component.debug_gpu_set_reset()
paste12()
q("touch", "screen-addr", 5, 18, 0)
for _ = 1, 4 do q("scroll", "screen-addr", 5, 18, 1) end
q("scroll", "screen-addr", 5, 18, 1)
q("interrupted")
pcall(tui.readInput, nil)
test("B2: input wheel up at top is no-op (no extra redraw)",
  component.debug_gpu_set_count() == c_top,
  "top=" .. tostring(c_top) .. " now=" .. tostring(component.debug_gpu_set_count()))
-- run3: paste + touch + 4 上 + 2 下 → s=2; 窗口显示显示行 3..10
component.debug_gpu_set_reset()
paste12()
q("touch", "screen-addr", 5, 18, 0)
for _ = 1, 4 do q("scroll", "screen-addr", 5, 18, 1) end
for _ = 1, 2 do q("scroll", "screen-addr", 5, 18, -1) end
q("interrupted")
pcall(tui.readInput, nil)
test("B2: 2x wheel down from top -> inputScroll 2",
  tui.debug_input_scroll() == 2, "s=" .. tostring(tui.debug_input_scroll()))
test("B2: window line5 rendered at row 20", cell(6, 20).ch == "5",
  "ch=" .. tostring(cell(6, 20).ch))
test("B2: content scroll untouched", tui.debug_scroll_offset() == 0,
  "off=" .. tostring(tui.debug_scroll_offset()))
test("B2: input scroll redraws (extra sets)",
  component.debug_gpu_set_count() > c_top,
  "top=" .. tostring(c_top) .. " now=" .. tostring(component.debug_gpu_set_count()))
-- run4: paste + touch + 4 上 + 4 下 → 到底 s=4（maxScroll）
component.debug_gpu_set_reset()
paste12()
q("touch", "screen-addr", 5, 18, 0)
for _ = 1, 4 do q("scroll", "screen-addr", 5, 18, 1) end
for _ = 1, 4 do q("scroll", "screen-addr", 5, 18, -1) end
q("interrupted")
pcall(tui.readInput, nil)
local c_max = component.debug_gpu_set_count()
test("B2: 4x wheel down reaches maxScroll 4", tui.debug_input_scroll() == 4,
  "s=" .. tostring(tui.debug_input_scroll()))
-- run5: 同 run4 + 再下滚 ×1（s=4 边界）→ 计数 == c_max（零额外重绘）
component.debug_gpu_set_reset()
paste12()
q("touch", "screen-addr", 5, 18, 0)
for _ = 1, 4 do q("scroll", "screen-addr", 5, 18, 1) end
for _ = 1, 4 do q("scroll", "screen-addr", 5, 18, -1) end
q("scroll", "screen-addr", 5, 18, -1)
q("interrupted")
pcall(tui.readInput, nil)
test("B2: input wheel down at max is no-op (no extra redraw)",
  component.debug_gpu_set_count() == c_max,
  "max=" .. tostring(c_max) .. " now=" .. tostring(component.debug_gpu_set_count()))

-- ════════════════════════════════════════════════════════════════
-- B3. 滚轮路由: lastTouchY 在内容区 → 滚内容区（scrollOffset）;
--     无 touch 记录 → 默认滚内容区（旧行为）。内容区高度随 ih 变
--     （paste 12 行 → ih=8 → h=15, maxScroll=15）。
-- ════════════════════════════════════════════════════════════════
component.debug_gpu_reset()
pcall(tui.init, {})
for i = 1, 30 do tui.print("line " .. i, tui.colors.user) end
-- run1: paste 12 行（ih=8, 输入框顶=18）+ touch 内容区 (5,3) → 路由到
-- 内容区; 上滚 ×2 → offset 6; drop 清 csel → interrupted 退出
paste12()
q("touch", "screen-addr", 5, 3, 0)
q("scroll", "screen-addr", 5, 3, 1)
q("scroll", "screen-addr", 5, 3, 1)
q("drop", "screen-addr", 5, 3, 0)
q("interrupted")
pcall(tui.readInput, nil)
test("B3: content wheel scrolls content (offset 6)",
  tui.debug_scroll_offset() == 6, "off=" .. tostring(tui.debug_scroll_offset()))
test("B3: input scroll untouched by content wheel (s=4 from paste follow)",
  tui.debug_input_scroll() == 4, "s=" .. tostring(tui.debug_input_scroll()))
-- run2: 无 touch → 默认滚内容区
component.debug_gpu_reset()
pcall(tui.init, {})
for i = 1, 30 do tui.print("line " .. i, tui.colors.user) end
q("scroll", "screen-addr", 5, 20, 1)
q("interrupted")
pcall(tui.readInput, nil)
test("B3: no-touch wheel defaults to content (offset 3)",
  tui.debug_scroll_offset() == 3, "off=" .. tostring(tui.debug_scroll_offset()))

-- ════════════════════════════════════════════════════════════════
-- B4. 多行编辑边界（v0.3.112 光标所在行）: 点击中间行定位 inputCursor;
--     Backspace 限当前行; Up/Down 跨显示行移动（列保持）; End 到行尾;
--     Home 到行首; 行首 Backspace no-op。
--     paste "l1\nl2\nl3\nl4": ih=4, 输入框顶=22, 行2 字符区间 {3,2}。
-- ════════════════════════════════════════════════════════════════
local function buf4paste()
  component.debug_gpu_reset()
  pcall(tui.init, {})
  q("clipboard", "kb-addr", "l1\nl2\nl3\nl4")
end

buf4paste()
q("touch", "screen-addr", 6, 23, 0)  -- 行2 "l2" 中 'l' 后
q("interrupted")
pcall(tui.readInput, nil)
test("B4: click middle line -> cursor 4", tui.debug_input_cursor() == 4,
  "c=" .. tostring(tui.debug_input_cursor()))

buf4paste()
q("touch", "screen-addr", 6, 23, 0)
qKey(8, 14)      -- Backspace: 删 'l'（限当前行, 不删 \n）
qKey(13, 28)     -- Enter 提交整个 buffer
local ok_r, res_r = pcall(tui.readInput, nil)
test("B4: backspace in middle line", ok_r and res_r == "l1\n2\nl3\nl4",
  "got=" .. tostring(res_r))

buf4paste()
q("touch", "screen-addr", 6, 23, 0)
qKey(0, 200)    -- Up: 光标到行1（列保持 → 行1 偏移 1）
qKey(88, 45)     -- 'X'（插在行1 'l' 后 → lX1）
qKey(13, 28)
pcall(tui.readInput, nil)
res_r = tui.debug_input_buffer()
test("B4: Up moves to previous display line (col kept)", res_r == "lX1\nl2\nl3\nl4",
  "got=" .. tostring(res_r):gsub("\n", "\\n"))

buf4paste()
q("touch", "screen-addr", 6, 23, 0)
qKey(0, 200)    -- Up → 行1
qKey(88, 45)     -- 'X'（lX1）
qKey(0, 208)    -- Down → 行2（列保持 → 行2 末尾）
qKey(89, 45)     -- 'Y'（l2Y）
qKey(13, 28)
pcall(tui.readInput, nil)
res_r = tui.debug_input_buffer()
test("B4: Down moves to next display line (col kept)", res_r == "lX1\nl2Y\nl3\nl4",
  "got=" .. tostring(res_r):gsub("\n", "\\n"))

buf4paste()
q("touch", "screen-addr", 6, 23, 0)
qKey(0, 207)    -- End: 光标所在行尾（不是 buffer 尾!）
qKey(90, 45)     -- 'Z'
qKey(13, 28)
pcall(tui.readInput, nil)
res_r = tui.debug_input_buffer()
test("B4: End goes to current line end", res_r == "l1\nl2Z\nl3\nl4",
  "got=" .. tostring(res_r):gsub("\n", "\\n"))

buf4paste()
q("touch", "screen-addr", 6, 23, 0)
qKey(0, 199)    -- Home: 光标所在行首
qKey(90, 45)     -- 'Z'
qKey(13, 28)
pcall(tui.readInput, nil)
res_r = tui.debug_input_buffer()
test("B4: Home goes to current line start", res_r == "l1\nZl2\nl3\nl4",
  "got=" .. tostring(res_r):gsub("\n", "\\n"))

buf4paste()
q("touch", "screen-addr", 5, 23, 0)  -- 行2 行首（rel=0 → cursor 3）
qKey(8, 14)      -- Backspace 在行首: no-op
qKey(13, 28)
pcall(tui.readInput, nil)
res_r = tui.debug_input_buffer()
test("B4: backspace at line start is no-op", res_r == "l1\nl2\nl3\nl4",
  "got=" .. tostring(res_r):gsub("\n", "\\n"))

-- ════════════════════════════════════════════════════════════════
-- C. 折行缓存（v0.3.113 输入卡顿回归）: 光标移动/滚动零重算（version
--    不变 → inputDisplayLines 缓存命中 O(1)）; 编辑/粘贴恰 1 次重算。
--    大量文本（200 行 × 50 字符 ≈ 10K 字符）粘贴后编辑/光标行为与
--    修复前一致。依赖 debug_input_reflow_count() 钩子。
-- ════════════════════════════════════════════════════════════════
local big_lines = {}
for i = 1, 200 do big_lines[i] = "line " .. string.format("%03d", i) .. string.rep("x", 44) end
local big_text = table.concat(big_lines, "\n")

-- C1: 粘贴 ~10K 字符 + 4 次光标移动 → 恰 2 次重算（readInput 入口清空 1 次
--     + 粘贴 1 次）——光标移动零重算（卡顿根因回归断言）
component.debug_gpu_reset()
pcall(tui.init, {})
q("clipboard", "kb-addr", big_text)
q("key_down", "kb-addr", 0, 205, "player")  -- Right
q("key_down", "kb-addr", 0, 203, "player")  -- Left
q("key_down", "kb-addr", 0, 200, "player")  -- Up
q("key_down", "kb-addr", 0, 208, "player")  -- Down
q("interrupted")
pcall(tui.readInput, nil)
test("C: large paste + 4 cursor moves == 2 reflows (entry+paste, moves=0)",
  tui.debug_input_reflow_count() == 2,
  "count=" .. tostring(tui.debug_input_reflow_count()))
test("C: height capped at 8 for 200 lines", tui.debug_input_height() == 8,
  "h=" .. tostring(tui.debug_input_height()))
test("C: window shows last line (line 200) at row 25",
  cell(5, 25).ch == "l" and cell(10, 25).ch == "2",
  "c5=" .. tostring(cell(5, 25).ch) .. " c10=" .. tostring(cell(10, 25).ch))
-- C2: 同一 run 内: 粘贴 + 编辑 1 字符 → 恰 3 次重算（入口+粘贴+字符）;
--     buffer 完整 = big .. 'X'（大文本编辑正确性）
component.debug_gpu_reset()
pcall(tui.init, {})
q("clipboard", "kb-addr", big_text)
q("key_down", "kb-addr", 88, 45, "player")  -- 'X'（光标在末尾 → append）
q("interrupted")
pcall(tui.readInput, nil)
test("C: paste + 1 char edit == 3 reflows (entry+paste+char)",
  tui.debug_input_reflow_count() == 3,
  "count=" .. tostring(tui.debug_input_reflow_count()))
test("C: large buffer intact after edit", tui.debug_input_buffer() == big_text .. "X",
  "len=" .. tostring(#tui.debug_input_buffer()))

-- ════════════════════════════════════════════════════════════════
-- D. shift 选中编辑（v0.3.114, 用户: "shift 选中删除"）: shift+方向扩展
--    选中（state.sel 0 基 [min,max), sel_active）; 无 shift 移动取消;
--    Backspace/Delete 删整段; 可打印字符/粘贴替换选中; 跨行选中删除。
--    依赖 oc_mock debug_set_shift(bool) 注入 shift 状态（debug_gpu_reset
--    自动复位）。debug_input_sel() 返回 {a,b} 或 nil; Enter 提交后 sel
--    仍保留（Enter 分支不清 sel——用 Enter 退出并断言选中状态）。
-- ════════════════════════════════════════════════════════════════
-- shift 状态注入（v0.3.114）: 事件预排队、处理时才读 shift 状态 →
-- 用 mock 的 test_shift 控制事件在事件流中途原位切换（event.pull 排头
-- 吞掉并应用, 不投递）。非队列形式（component.debug_set_shift）会在
-- readInput 开始前就把状态复位, 事件处理时读不到。
local function shiftQ(v) q("test_shift", v) end

-- D1a: shift+Left×2 扩展选中（锚点=原光标 4, 终点=新光标 2 → "cd"）;
--      Enter 后 sel 保留 {4,2}, 光标 2
component.debug_gpu_reset()
pcall(tui.init, {})
q("clipboard", "kb-addr", "abcd")
shiftQ(true)
q("key_down", "kb-addr", 0, 203, "player")  -- shift+Left
q("key_down", "kb-addr", 0, 203, "player")  -- shift+Left
shiftQ(false)
q("key_down", "kb-addr", 13, 28, "player")  -- Enter（提交并退出, sel 保留）
pcall(tui.readInput, nil)
local dsel = tui.debug_input_sel()
test("D: shift+Left x2 extends selection {4,2}",
  dsel and math.min(dsel.a, dsel.b) == 2 and math.max(dsel.a, dsel.b) == 4,
  "sel=" .. tostring(dsel and (dsel.a .. "," .. dsel.b)))
test("D: cursor follows to 2", tui.debug_input_cursor() == 2,
  "c=" .. tostring(tui.debug_input_cursor()))

-- D1b: 选中 + Backspace → 删整段 "cd" → "ab"
component.debug_gpu_reset()
pcall(tui.init, {})
q("clipboard", "kb-addr", "abcd")
shiftQ(true)
q("key_down", "kb-addr", 0, 203, "player")
q("key_down", "kb-addr", 0, 203, "player")
shiftQ(false)
q("key_down", "kb-addr", 8, 14, "player")  -- Backspace 删选中
q("key_down", "kb-addr", 13, 28, "player")
local ok_d, res_d = pcall(tui.readInput, nil)
test("D: Backspace deletes whole selection -> ab", ok_d and res_d == "ab",
  "got=" .. tostring(res_d))

-- D2: shift+Home 反向扩到行首（选中全行）+ 输入字符替换 → "X"
component.debug_gpu_reset()
pcall(tui.init, {})
q("clipboard", "kb-addr", "abcd")
shiftQ(true)
q("key_down", "kb-addr", 0, 199, "player")  -- shift+Home
shiftQ(false)
q("key_down", "kb-addr", 88, 45, "player")  -- 'X' 替换选中
q("key_down", "kb-addr", 13, 28, "player")
pcall(tui.readInput, nil)
test("D: shift+Home selects line, char replaces -> X",
  tui.debug_input_buffer() == "X", "buf=" .. tostring(tui.debug_input_buffer()))

-- D3: 选中 + Delete → 删整段 "def" → "abc"
component.debug_gpu_reset()
pcall(tui.init, {})
q("clipboard", "kb-addr", "abcdef")
shiftQ(true)
for _ = 1, 3 do q("key_down", "kb-addr", 0, 203, "player") end  -- shift+Left×3
shiftQ(false)
q("key_down", "kb-addr", 0, 211, "player")  -- Delete 删选中
q("key_down", "kb-addr", 13, 28, "player")
pcall(tui.readInput, nil)
test("D: Delete deletes whole selection -> abc",
  tui.debug_input_buffer() == "abc", "buf=" .. tostring(tui.debug_input_buffer()))

-- D4: 中部选中 + 输入字符替换（'d' → 'X'）→ "abcX"
component.debug_gpu_reset()
pcall(tui.init, {})
q("clipboard", "kb-addr", "abcd")
shiftQ(true)
q("key_down", "kb-addr", 0, 203, "player")  -- shift+Left（选 'd'）
shiftQ(false)
q("key_down", "kb-addr", 88, 45, "player")  -- 'X' 替换
q("key_down", "kb-addr", 13, 28, "player")
pcall(tui.readInput, nil)
test("D: mid-selection char replaces -> abcX",
  tui.debug_input_buffer() == "abcX", "buf=" .. tostring(tui.debug_input_buffer()))

-- D5: 无 shift 移动取消选中 → 后续字符在光标处插入（非替换）→ "aXbcd"
component.debug_gpu_reset()
pcall(tui.init, {})
q("clipboard", "kb-addr", "abcd")
shiftQ(true)
q("key_down", "kb-addr", 0, 203, "player")
q("key_down", "kb-addr", 0, 203, "player")  -- sel {4,2}
shiftQ(false)
q("key_down", "kb-addr", 0, 203, "player")  -- 无 shift Left → 取消选中, 光标 1
q("key_down", "kb-addr", 88, 45, "player")  -- 'X' 插入光标处
q("key_down", "kb-addr", 13, 28, "player")
pcall(tui.readInput, nil)
local dsel5 = tui.debug_input_sel()
test("D: no-shift move cancels selection (insert not replace) -> aXbcd",
  tui.debug_input_buffer() == "aXbcd", "buf=" .. tostring(tui.debug_input_buffer()))
test("D: selection cleared after no-shift move", dsel5 == nil,
  "sel=" .. tostring(dsel5 and (dsel5.a .. "," .. dsel5.b)))

-- D6: shift+Up×2 跨行选中（l2+l3 含 \n）+ Backspace 删整段 → "l1"
component.debug_gpu_reset()
pcall(tui.init, {})
q("clipboard", "kb-addr", "l1\nl2\nl3")
shiftQ(true)
q("key_down", "kb-addr", 0, 200, "player")  -- shift+Up → 行2尾
q("key_down", "kb-addr", 0, 200, "player")  -- shift+Up → 行1尾 (sel {8,2})
shiftQ(false)
q("key_down", "kb-addr", 8, 14, "player")  -- Backspace 删选中跨行段
q("key_down", "kb-addr", 13, 28, "player")
pcall(tui.readInput, nil)
test("D: shift+Up cross-line selection deleted -> l1",
  tui.debug_input_buffer() == "l1", "buf=" .. tostring(tui.debug_input_buffer()))

-- D7: 粘贴替换选中（"world" → "X"）→ "hello X"
component.debug_gpu_reset()
pcall(tui.init, {})
q("clipboard", "kb-addr", "hello world")
shiftQ(true)
for _ = 1, 5 do q("key_down", "kb-addr", 0, 203, "player") end  -- 选 "world"
shiftQ(false)
q("clipboard", "kb-addr", "X")  -- 粘贴替换选中
q("key_down", "kb-addr", 13, 28, "player")
pcall(tui.readInput, nil)
test("D: paste replaces selection -> hello X",
  tui.debug_input_buffer() == "hello X", "buf=" .. tostring(tui.debug_input_buffer()))

-- ════════════════════════════════════════════════════════════════
-- E. v0.3.115 功能1/3: Ctrl+A 全选 + bash 标准 ↑↓。
--    E1: Ctrl+A（ch==1）→ sel={0,charCount}; Backspace 删整 buffer。
--    E2: bash 标准——多行光标顶行 ↑ = 历史上翻（替换整个 buffer）;
--        底行 ↓ = 历史下翻; 中间 ↑↓ = 跨行移动（B4 已测保持）;
--        单行 ↑↓ = 历史（现状保持）。
-- ════════════════════════════════════════════════════════════════
-- E1a: Ctrl+A 后 Enter（不清 sel）→ sel {0,11} 保留
component.debug_gpu_reset()
pcall(tui.init, {})
q("clipboard", "kb-addr", "hello world")
q("key_down", "kb-addr", 1, 30, "player")  -- Ctrl+A（ch==1=SOH）
q("key_down", "kb-addr", 13, 28, "player")
pcall(tui.readInput, nil)
local e1sel = tui.debug_input_sel()
test("E1: Ctrl+A selects whole buffer {0,11}", e1sel and e1sel.a == 0 and e1sel.b == 11,
  "sel=" .. tostring(e1sel and (e1sel.a .. "," .. e1sel.b)))
-- E1b: Ctrl+A + Backspace 删整 buffer → 后续输入从空开始
component.debug_gpu_reset()
pcall(tui.init, {})
q("clipboard", "kb-addr", "hello world")
q("key_down", "kb-addr", 1, 30, "player")  -- Ctrl+A
q("key_down", "kb-addr", 8, 14, "player")  -- Backspace 删整段 → buffer ""
q("key_down", "kb-addr", 120, 45, "player")  -- 'x' → buffer "x"
q("key_down", "kb-addr", 13, 28, "player")
local ok_e1, res_e1 = pcall(tui.readInput, nil)
test("E1: Ctrl+A + Backspace clears buffer (submit == x)", ok_e1 and res_e1 == "x",
  "got=" .. tostring(res_e1))

-- E2: bash 标准 ↑↓（历史经 run1 提交建立; 跨 run 不复位 cmdHistory）
-- run1: 提交 "prevcmd" → cmdHistory = {"prevcmd"}
component.debug_gpu_reset()
pcall(tui.init, {})
q("clipboard", "kb-addr", "prevcmd")
q("key_down", "kb-addr", 13, 28, "player")
pcall(tui.readInput, nil)
-- run2: 多行 paste + 点击顶行（行 1 = y=22, cursor 0）+ ↑ → 历史上翻 → "prevcmd"
q("clipboard", "kb-addr", "l1\nl2\nl3\nl4")
q("touch", "screen-addr", 5, 22, 0)  -- 顶行行首 (ih=4, inputTop=22)
q("key_down", "kb-addr", 0, 200, "player")  -- Up: 顶行 → 历史
q("key_down", "kb-addr", 13, 28, "player")
local ok_e2, res_e2 = pcall(tui.readInput, nil)
test("E2: Up at top line browses history (prevcmd)", ok_e2 and res_e2 == "prevcmd",
  "got=" .. tostring(res_e2))
-- E3: 底行 ↓ = 历史下翻（同 run 内往返: paste 多行 → End 底行 → Up×2
--     到历史（首 Up 跨行上移, 二 Up 顶行翻历史）→ Down 底行语义回
--     savedInput）→ 提交 = 原始 "ab\ncd"。若 Up/Down 任一非 bash 语义
--     （跨行 vs 历史错乱）, 往返结果 ≠ "ab\ncd" → 断言失败。
q("clipboard", "kb-addr", "ab\ncd")
q("key_down", "kb-addr", 0, 207, "player")  -- End → buffer 尾（line_end==charCount）
q("key_down", "kb-addr", 0, 200, "player")  -- Up: 底行 → 跨行上移（非历史）
q("key_down", "kb-addr", 0, 200, "player")  -- Up: 顶行 → 历史上翻
q("key_down", "kb-addr", 0, 208, "player")  -- Down: 单行 buffer → 历史下翻回 savedInput
q("key_down", "kb-addr", 13, 28, "player")
local ok_e3, res_e3 = pcall(tui.readInput, nil)
test("E3: bottom Down round-trips through history", ok_e3 and res_e3 == "ab\ncd",
  "got=" .. tostring(res_e3):gsub("\n", "\\n"))
-- E4: 单行 ↑ = 历史（现状保持; 独立 run 自建历史, 期望不依赖前面 run）
component.debug_gpu_reset()
pcall(tui.init, {})
q("clipboard", "kb-addr", "prevcmd")
q("key_down", "kb-addr", 13, 28, "player")
pcall(tui.readInput, nil)  -- cmdHistory = {"prevcmd"}
q("clipboard", "kb-addr", "solo")
q("key_down", "kb-addr", 0, 200, "player")  -- Up: 单行 → 历史上翻
q("key_down", "kb-addr", 13, 28, "player")
local ok_e4, res_e4 = pcall(tui.readInput, nil)
test("E4: single-line Up browses history (prevcmd)", ok_e4 and res_e4 == "prevcmd",
  "got=" .. tostring(res_e4))

-- ════════════════════════════════════════════════════════════════
print(string.format("RESULT: %d pass, %d fail", pass, fail))
if not _IN_RUN_TESTS then
  os.exit(fail > 0 and 1 or 0)
end
return pass, fail
