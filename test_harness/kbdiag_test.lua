-- kbdiag_test.lua: 真机键盘事件诊断（快捷键不可用问题定位）
-- 运行: lua kbdiag_test.lua
-- 按屏幕指引按键，观察事件是否到达、键码是否匹配、Ctrl 状态是否更新。
-- 结果贴回给开发者即可定位：事件根本没到 / 键码不同 / Ctrl 修饰键丢失。
print("=== keyboard diag start ===")

-- 1) 键盘库状态
local ok_kb, keyboard = pcall(require, "keyboard")
print("keyboard lib: ok=" .. tostring(ok_kb) .. " type=" .. tostring(type(keyboard)))
if ok_kb and type(keyboard) == "table" then
  print("  isControlDown: " .. tostring(type(keyboard.isControlDown)))
  print("  isShiftDown:   " .. tostring(type(keyboard.isShiftDown)))
  print("  keys.lcontrol: " .. tostring(keyboard.keys and keyboard.keys.lcontrol))
  print("  keys.rcontrol: " .. tostring(keyboard.keys and keyboard.keys.rcontrol))
end

-- 2) 组件层
local ok_comp, component = pcall(require, "component")
if ok_comp and component.isAvailable then
  print("keyboard component available: " .. tostring(component.isAvailable("keyboard")))
  if component.keyboard then
    local methods = {}
    for k in pairs(component.keyboard) do methods[#methods + 1] = tostring(k) end
    table.sort(methods)
    print("  component.keyboard methods: " .. table.concat(methods, ", "))
  end
end

-- 3) 事件监听（20 秒）
local ok_ev, event = pcall(require, "event")
if not ok_ev or not event or not event.pull then
  print("ERROR: no event library: " .. tostring(event))
  return
end
print("")
print("--- 现在依次按以下键（每个按一次，按完等 1 秒）---")
print(" 1. 左方向键    2. 右方向键    3. 上方向键    4. 下方向键")
print(" 5. Ctrl+左      6. Ctrl+右      7. Ctrl+上      8. Ctrl+下")
print(" 9. PgUp        10. PgDn       11. Home       12. End")
print("13. Tab         14. Esc        15. 字母 a")
print("--- 20 秒后自动结束 ---")
print("")

local deadline = os.clock() + 20
local count = 0
while os.clock() < deadline do
  local ev, _, char, code = event.pull(0.5)
  if ev then
    count = count + 1
    local ctrl, shift = "?", "?"
    if keyboard and keyboard.isControlDown then
      local okc, c = pcall(keyboard.isControlDown)
      ctrl = okc and tostring(c) or ("err:" .. tostring(c))
    end
    if keyboard and keyboard.isShiftDown then
      local oks, s = pcall(keyboard.isShiftDown)
      shift = oks and tostring(s) or ("err:" .. tostring(s))
    end
    print(string.format("[%02d] ev=%-12s char=%-4d(%-4q) code=%-4d ctrl=%-5s shift=%-5s",
      count, tostring(ev), char or -1, tostring(char or ""), code or -1, ctrl, shift))
  end
end
print("")
print("=== diag done, events seen: " .. count .. " ===")
print("keyboard.keys expected: left=203 right=205 up=200 down=208 home=199 end=207 pgup=201 pgdn=209 tab=15 lctrl=29")
