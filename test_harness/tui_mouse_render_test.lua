-- ════════════════════════════════════════════════════════════════
-- TUI Mouse Render Regression Test（v0.3.110）
--
-- 真机 bug 回归（模拟鼠标事件驱动渲染路径）:
--   ① tui.lua:381 "attempt to call a nil value (global 'drawRow')"
--     —— readInput 事件路径缺 drawRow 前向声明崩溃
--   ② v0.3.108 起 TUI 字体全黑（选中才亮）
--     —— 选中段 setForeground(background) 残留 fg=黑 → fill 只设 bg
--        不设 fg → 整区黑字空格（v0.3.110 fill 前 setForeground + 
--        drawRow 每行渲染后复位 fg/bg 双保险）
--   ③ 搜索高亮 usub 终止索引 bug（长度当 end 传 → 匹配段永不渲染）
--   ④ 选中反色分段渲染（前缀/选中/后缀三色）
--   ⑤ readInput 干净退出（可打印字符 key_down + Enter）
--
-- 依赖 oc_mock 增强（v0.3.110）: 真实 GPU 屏幕缓冲
-- （debug_gpu_screen/debug_gpu_reset）+ keyboard 代理
-- （keyboard.isAvailable→true 激活 readInput 事件路径）+ 事件队列
-- 导出（oc_mock._event_queue 与 mock_event.pull 同一张表）。
--
-- 运行:
--   独立:  lua test_harness/tui_mouse_render_test.lua   （仓库根目录）
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
  print("FAIL tui_mouse_render_test: agent.tui load failed: " .. tostring(ok_tui))
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

-- 场景辅助: 清屏 + 两条 history（"line one alpha" user 色 /
-- "line two beta" assistant 色）→ 内容区 y=2,3，y=4+ 空行
local function fresh()
  component.debug_gpu_reset()
  pcall(tui.init, {})
  tui.print("line one alpha", tui.colors.user)
  tui.print("line two beta", tui.colors.assistant)
  tui.redrawContent()
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

-- ════════════════════════════════════════════════════════════════
-- 1. 崩溃回归 + readInput 干净退出（①⑤）:
--    touch 内容区 → redrawContent（drawRow 调用点）; drag → 
--    redrawRowRange; 可打印字符 key_down + Enter → readInput 返回。
--    缺 drawRow 前向声明时此处必崩。
-- ════════════════════════════════════════════════════════════════
fresh()
q("touch", "screen-addr", 5, 2, 0)
q("drag", "screen-addr", 10, 3, 0)
qKey(120, 45) -- 'x'
qKey(13, 28)  -- Enter
local ok_read, res_read = pcall(tui.readInput, nil)
test("crash: readInput touch/drag no crash (drawRow fwd decl)", ok_read,
  "err=" .. tostring(res_read))
test("exit: readInput returns submitted line", ok_read and res_read == "x",
  "got=" .. tostring(res_read))

-- ════════════════════════════════════════════════════════════════
-- 2. 字体全黑回归（②）——复现"选中后全黑"路径:
--    touch+drag 选中渲染（drag 到行尾, 选中段 suf 空 → 旧代码 fg 残留
--    黑）→ 再 redrawContent → 非选中行/空行必须正常。
--    断言: y=3 非选中行 fg=assistant bg=0; y=4 是 "> x" echo（user 色,
--    非空行!）; y=5 真正空行 fg=foreground bg=0。
-- ════════════════════════════════════════════════════════════════
fresh()
q("touch", "screen-addr", 5, 2, 0)
q("drag", "screen-addr", 79, 2, 0) -- 拖到行尾, 选中段延伸到行右缘
qKey(120, 45)
qKey(13, 28)
pcall(tui.readInput, nil)
-- 选中仍在（未 drop）→ 手动 redrawContent 复现下一轮渲染
pcall(tui.redrawContent)
local c3 = cell(3, 3) -- "line two beta" 前缀, 非选中行
test("black: non-selected row fg=row color", c3.fg == tui.colors.assistant,
  string.format("fg=%x", c3.fg))
test("black: non-selected row bg=background", c3.bg == 0,
  string.format("bg=%x", c3.bg))
local c4 = cell(3, 4) -- "> x" echo（user 色, 非空行）
test("black: echo row fg=user", c4.fg == tui.colors.user,
  string.format("fg=%x ch=%q", c4.fg, c4.ch))
test("black: echo row bg=background", c4.bg == 0, string.format("bg=%x", c4.bg))
local c5 = cell(3, 5) -- 真正空行
test("black: empty row fg=foreground", c5.fg == tui.colors.foreground,
  string.format("fg=%x", c5.fg))
test("black: empty row bg=background", c5.bg == 0, string.format("bg=%x", c5.bg))
local c2 = cell(10, 2) -- 选中行仍反色（选中未清除, 正确行为）
test("black: selected row keeps inverted", c2.fg == 0 and c2.bg == tui.colors.user,
  string.format("fg=%x bg=%x", c2.fg, c2.bg))

-- ════════════════════════════════════════════════════════════════
-- 3. drop 复制后恢复原色（② 的 drop 路径）+ onCopy 文本
--    touch(5,2)+drag(10,3)+drop → copyContentSelection → csel 清除 →
--    redrawContent → 选中行恢复原色; onCopy 收到读回文本。
-- ════════════════════════════════════════════════════════════════
component.debug_gpu_reset()
local copied = nil
pcall(tui.init, {onCopy = function(text) copied = text end})
tui.print("line one alpha", tui.colors.user)
tui.print("line two beta", tui.colors.assistant)
tui.redrawContent()
q("touch", "screen-addr", 5, 2, 0)
q("drag", "screen-addr", 10, 3, 0)
q("drop", "screen-addr", 10, 3, 0)
qKey(120, 45)
qKey(13, 28)
local ok_drop, res_drop = pcall(tui.readInput, nil)
test("drop: readInput survives drop (copyContentSelection)", ok_drop,
  "err=" .. tostring(res_drop))
test("drop: onCopy received selection text", copied ~= nil and copied:find("alpha") ~= nil
  and copied:find("line two") ~= nil,
  "copied=" .. tostring(copied))
local d2 = cell(3, 2) -- 选中已清除 → 恢复原色
test("drop: row restored to original color", d2.fg == tui.colors.user and d2.bg == 0,
  string.format("fg=%x bg=%x", d2.fg, d2.bg))
local d5 = cell(3, 5)
test("drop: empty row fg=foreground bg=0", d5.fg == tui.colors.foreground and d5.bg == 0,
  string.format("fg=%x bg=%x", d5.fg, d5.bg))

-- ════════════════════════════════════════════════════════════════
-- 4. 选中反色分段（④）——touch(5,2)+drag(10,3):
--    row2: 前缀(2..4) fg=user bg=0 / 选中(5..79) fg=0 bg=user
--    row3: 选中(2..10) fg=0 bg=assistant / 后缀(11..14) fg=assistant bg=0
-- ════════════════════════════════════════════════════════════════
fresh()
q("touch", "screen-addr", 5, 2, 0)
q("drag", "screen-addr", 10, 3, 0)
qKey(120, 45)
qKey(13, 28)
pcall(tui.readInput, nil)
local p2 = cell(3, 2)
test("sel: row2 prefix fg=user bg=0", p2.fg == tui.colors.user and p2.bg == 0,
  string.format("fg=%x bg=%x", p2.fg, p2.bg))
local s2 = cell(6, 2)
test("sel: row2 selected inverted fg=0 bg=user", s2.fg == 0 and s2.bg == tui.colors.user,
  string.format("fg=%x bg=%x", s2.fg, s2.bg))
local s3 = cell(3, 3)
test("sel: row3 selected inverted fg=0 bg=assistant", s3.fg == 0 and s3.bg == tui.colors.assistant,
  string.format("fg=%x bg=%x", s3.fg, s3.bg))
local q3 = cell(13, 3)
test("sel: row3 suffix fg=assistant bg=0", q3.fg == tui.colors.assistant and q3.bg == 0,
  string.format("fg=%x bg=%x", q3.fg, q3.bg))

-- ════════════════════════════════════════════════════════════════
-- 5. 搜索高亮（③）: tui.search("beta") → row3 "line two beta" 的
--    beta（字符 10-13）→ 屏幕列 2-1+10=11..14 tool 色段;
--    非命中行（row2）保持 user 原色。
-- ════════════════════════════════════════════════════════════════
fresh()
local n_search = tui.search("beta")
test("search: match count 1", n_search == 1, "n=" .. tostring(n_search))
-- 匹配行 y=3（scrollOffset=0: #history=2 < 视口高, 无滚动）
local s11 = cell(11, 3)
test("search: match col 11 tool color", s11.fg == tui.colors.tool,
  string.format("fg=%x ch=%q", s11.fg, s11.ch))
local s14 = cell(14, 3)
test("search: match col 14 tool color", s14.fg == tui.colors.tool,
  string.format("fg=%x ch=%q", s14.fg, s14.ch))
local s10 = cell(10, 3)
test("search: pre segment row color", s10.fg == tui.colors.assistant,
  string.format("fg=%x", s10.fg))
-- 非命中行 row2 全程 user 色, 无 tool 段
local nonhit_tool = false
for x = 2, 20 do
  if cell(x, 2).fg == tui.colors.tool then nonhit_tool = true break end
end
local n2 = cell(3, 2)
test("search: non-match row keeps color", n2.fg == tui.colors.user and not nonhit_tool,
  string.format("fg=%x tool_in_row=%s", n2.fg, tostring(nonhit_tool)))
-- 搜索无匹配 → 0 不崩
local n_zero = tui.search("zzz")
test("search: no match returns 0", n_zero == 0, "n=" .. tostring(n_zero))

-- ════════════════════════════════════════════════════════════════
print(string.format("RESULT: %d pass, %d fail", pass, fail))
if not _IN_RUN_TESTS then
  os.exit(fail > 0 and 1 or 0)
end
return pass, fail
