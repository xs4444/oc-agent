-- wilderness_probe.lua: 荒野大师环境事实收集（一次性回答所有疑问）
-- 不用 readInput/TUI，纯打印 + 文件。运行后把屏幕输出贴回给开发者。
--   用法: lua wilderness_probe.lua
local out = {}
local function log(...)
  local parts = {}
  for i = 1, select("#", ...) do parts[i] = tostring(select(i, ...)) end
  local line = table.concat(parts, " ")
  out[#out + 1] = line
  print(line)
end
local function write_result(text)
  for _, p in ipairs({"/home/probe_result.txt", "/mnt/probe_result.txt"}) do
    local ok, f = pcall(io.open, p, "w")
    if ok and f then f:write(text) f:close() end
  end
end

log("=== 1. keyboard 库状态 ===")
local ok_kb, keyboard = pcall(require, "keyboard")
log("require keyboard: ok=" .. tostring(ok_kb) .. " type=" .. tostring(type(keyboard)))
if ok_kb and type(keyboard) == "table" then
  log("  isAvailable: " .. tostring(type(keyboard.isAvailable)))
  if keyboard.isAvailable then
    local ok2, v2 = pcall(keyboard.isAvailable)
    log("  isAvailable() = " .. tostring(ok2) .. " " .. tostring(v2))
  end
  log("  keys.enter = " .. tostring(keyboard.keys and keyboard.keys.enter))
  log("  keys.tab = " .. tostring(keyboard.keys and keyboard.keys.tab))
end

log("")
log("=== 2. 组件状态 ===")
local ok_c, component = pcall(require, "component")
if ok_c and component.isAvailable then
  log("  gpu available: " .. tostring(component.isAvailable("gpu")))
  log("  keyboard component available: " .. tostring(component.isAvailable("keyboard")))
  log("  screen available: " .. tostring(component.isAvailable("screen")))
else
  log("  component unavailable")
end

log("")
log("=== 3. GPU set 行为（标记写到哪行）===")
local gpu = component.gpu
if gpu and gpu.getResolution then
  local w, h = gpu.getResolution()
  log("resolution: " .. tostring(w) .. "x" .. tostring(h))
  -- 写标记到已知行
  pcall(gpu.set, 1, 5, "MARK5")
  pcall(gpu.set, 1, 6, "MARK6")
  pcall(gpu.set, 1, h - 1, "MARKH1")
  pcall(gpu.set, 1, h, "MARKH")
  -- dump 全屏找 MARK 出现行（读屏验证 set 的 y 是否真的定位）
  for y = 1, h do
    local row = {}
    for x = 1, w do
      local okg, c = pcall(gpu.get, x, y)
      row[x] = okg and (c or " ") or " "
    end
    local s = table.concat(row):gsub("%s+$", "")
    if s:find("MARK", 1, true) then
      log("  MARK at row " .. y .. ": [" .. s:sub(1, 40) .. "]")
    end
  end
end

log("")
log("=== 4. event.pull 验证（3 秒窗口，请按一次字母 A）===")
local ok_e, event = pcall(require, "event")
if ok_e and event and event.pull then
  local deadline = os.clock() + 3
  while os.clock() < deadline do
    local ev, _, char, code = event.pull(0.2)
    if ev then
      log("  event: " .. tostring(ev) .. " char=" .. tostring(char) .. "(" .. type(char)
        .. ") code=" .. tostring(code) .. "(" .. type(code) .. ")")
    end
  end
  log("  (3 秒结束)")
else
  log("  event unavailable")
end

log("")
log("=== 5. term 光标（检查终端层）===")
local ok_t, term = pcall(require, "term")
if ok_t and term.getCursor then
  local x, y = term.getCursor()
  log("  term cursor: " .. tostring(x) .. "," .. tostring(y))
end

write_result(table.concat(out, "\n"))
log("")
log("PROBE DONE — 请把以上输出贴回给开发者")
