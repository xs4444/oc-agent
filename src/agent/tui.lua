-- ═══════════════════════════════════════════════════════════════
-- agent.tui — OpenComputers 终端 UI（参考 DonChong2000/oc-ai 的
-- lib/oc-code/tui.lua 架构）。
--
-- 四区布局: header(第1行) / 内容区(2..h-3) / 状态栏(h-1) / 输入行(h)。
-- 单色模式: gpu.getDepth()==1 → monoColors（机器人 T1 GPU 1-bit 屏）。
-- 所有 gpu 调用 pcall 包裹: 渲染异常不拖垮 agent（调用方回退 REPL）。
-- 兼容接口（与 oc-ai runLoop 同构）: init/print/printRole/printToolCall/
-- printToolResult/setStatus/readInput/scrollUp/scrollDown/scrollToBottom/
-- isRunning/stop/clear/cleanup。扩展: setStatusData(fn)（状态栏右侧动态
-- 数据: 上下文占用/cache）、setCompletions(list)（Tab 补全候选）。
-- ═══════════════════════════════════════════════════════════════

local ok_c, component = pcall(require, "component")
local ok_t, term = pcall(require, "term")
local ok_e, event = pcall(require, "event")
local ok_k, keyboard = pcall(require, "keyboard")
local ok_u, unicode = pcall(require, "unicode")
-- 缺库降级: 无 GPU/键盘组件时绘制静默失败，纯逻辑（history/滚动/补全）
-- 仍可用（测试环境/机器人）。
if not ok_c then component = {} end
if not ok_t then term = {} end
if not ok_e then event = {} end
if not ok_k then keyboard = {} end
if not ok_u then unicode = nil end

local function ulen(s)
  if unicode then return ulen(s) end
  return tostring(s):len()
end
local function usub(s, i, j)
  if unicode then return usub(s, i, j) end
  return tostring(s):sub(i, j)
end

local tui = {}

-- 彩色方案（暗底 + 角色色，opencode TUI 风格）
tui.colors = {
  background = 0x000000, foreground = 0xffffff,
  status = 0x1b1b2f, statusText = 0x9aa0b0,
  prompt = 0x4ec9b0, user = 0x8ab4f8, assistant = 0xffffff,
  tool = 0xf0a35e, toolName = 0xffd966, error = 0xff6b6b, dim = 0x888888,
}
-- 单色方案（1-bit: 状态栏/输入行反白区分，其余正常）
tui.monoColors = {
  background = 0x000000, foreground = 0xffffff,
  status = 0xffffff, statusText = 0x000000,
  prompt = 0xffffff, user = 0xffffff, assistant = 0xffffff,
  tool = 0xffffff, toolName = 0xffffff, error = 0xffffff, dim = 0xffffff,
}

local state = {}
local completionHandlers = {}  -- {prefix = {candidates = {cmd, desc}...}}

-- 解析: 按字节找分隔符（OC gpu 文本按字符定位，ansi 处理走 unicode）
local function char_count_before(s, sub)
  local idx = s:find(sub, 1, true)
  if not idx then return ulen(s) end
  return ulen(s:sub(1, idx - 1))
end

-- 初始化（config.monochrome 强制单色）
function tui.init(config)
  config = config or {}
  if config.monochrome then tui.colors = tui.monoColors end
  local ok, w, h = pcall(function()
    return component.gpu and component.gpu.getResolution()
  end)
  state.width, state.height = (ok and w) or 80, (ok and h) or 25
  state.running = true
  state.scrollOffset = 0
  state.history = {}
  state.inputBuffer = ""
  state.inputCursor = 0
  state.cmdHistory = {}
  state.cmdHistoryIndex = 0
  state.savedInput = ""
  state.status = "Ready"
  state.statusData = nil
  state.completions = {}
  state.completionCycle = nil
  pcall(function()
    term.clear()
    tui.drawHeader()
    tui.drawStatus()
    tui.drawInput()
  end)
end

-- 状态栏右侧动态数据提供者（init.lua 注入: 上下文占用/cache 等）
function tui.setStatusData(fn)
  state.statusData = fn
end

-- Tab 补全候选（命令/工具名列表）
function tui.setCompletions(list)
  state.completions = list or {}
end

-- 绘制 header（第 1 行）
function tui.drawHeader()
  local g = component.gpu
  g.setBackground(tui.colors.status)
  g.setForeground(tui.colors.statusText)
  g.fill(1, 1, state.width, 1, " ")
  g.setForeground(tui.colors.toolName)
  g.set(2, 1, "OC Agent")
  g.setForeground(tui.colors.statusText)
  local hint = "/help | PgUp/PgDn scroll | /exit"
  if state.width >= ulen(hint) + 16 then
    g.set(state.width - ulen(hint) - 1, 1, hint)
  end
end

-- 绘制状态栏（h-1 行: status 左 + 动态数据右 + scroll 指示）
function tui.drawStatus()
  local g = component.gpu
  local y = state.height - 1
  g.setBackground(tui.colors.status)
  g.setForeground(tui.colors.statusText)
  g.fill(1, y, state.width, 1, " ")
  g.set(2, y, state.status)
  if state.statusData then
    local data = state.statusData()
    if data and data ~= "" then
      local maxw = state.width - 8
      if ulen(data) > maxw then data = usub(data, 1, maxw - 1) .. "~" end
      g.set(state.width - ulen(data) - 1, y, data)
    end
  end
  if state.scrollOffset > 0 then
    local st = "[Scroll " .. tostring(state.scrollOffset) .. "]"
    g.setForeground(tui.colors.tool)
    g.set(state.width - ulen(st) - 1, y, st)
    g.setForeground(tui.colors.statusText)
  end
  g.setBackground(tui.colors.background)
  g.setForeground(tui.colors.foreground)
end

function tui.setStatus(msg)
  state.status = msg or "Ready"
  pcall(tui.drawStatus)
end

-- 内容区边界（含滚动窗口高度）
local function getContentBounds()
  return 2, 2, state.width - 2, state.height - 3
end

-- 逐词换行 + 长词硬断（中文按 unicode 字符）
local function wrapText(str, width)
  local lines = {}
  for line in tostring(str):gmatch("([^\n]*)\n?") do
    if ulen(line) <= width then
      lines[#lines + 1] = line
    else
      local current = ""
      for word in line:gmatch("%S+") do
        if ulen(current) + ulen(word) + 1 <= width then
          current = current == "" and word or (current .. " " .. word)
        else
          if current ~= "" then lines[#lines + 1] = current end
          if ulen(word) > width then
            while ulen(word) > width do
              lines[#lines + 1] = usub(word, 1, width)
              word = usub(word, width + 1)
            end
            current = word
          else
            current = word
          end
        end
      end
      if current ~= "" then lines[#lines + 1] = current end
    end
  end
  return lines
end

-- 输出到内容区（自动滚动到底）
function tui.print(msg, color)
  local _, _, w = getContentBounds()
  color = color or tui.colors.foreground
  for _, line in ipairs(wrapText(msg, w)) do
    state.history[#state.history + 1] = {text = line, color = color}
  end
  state.scrollOffset = 0
  pcall(tui.redrawContent)
end

-- 角色前缀输出
function tui.printRole(role, msg)
  local color, prefix
  if role == "user" then color, prefix = tui.colors.user, "> "
  elseif role == "assistant" then color, prefix = tui.colors.assistant, ""
  elseif role == "tool" then color, prefix = tui.colors.tool, "  "
  elseif role == "error" then color, prefix = tui.colors.error, "Error: "
  else color, prefix = tui.colors.foreground, "" end
  tui.print(prefix .. msg, color)
end

function tui.printToolCall(name, args)
  tui.print(">> " .. tostring(name), tui.colors.toolName)
  if args then
    local s = type(args) == "string" and args or json_encode(args)
    if ulen(s) > 100 then s = usub(s, 1, 97) .. "..." end
    tui.print("   " .. s, tui.colors.dim)
  end
end

function tui.printToolResult(name, result)
  local s = type(result) == "string" and result or json_encode(result)
  if ulen(s) > 200 then s = usub(s, 1, 197) .. "..." end
  tui.print("<< " .. s, tui.colors.dim)
end

local function json_encode(v)
  local ok, out = pcall(function() return require("agent.json").encode(v) end)
  return ok and out or tostring(v)
end

-- 重绘内容区（可见窗口 = 底部 h 行 - scrollOffset）
function tui.redrawContent()
  local g = component.gpu
  local x, y, w, h = getContentBounds()
  g.setBackground(tui.colors.background)
  g.fill(x - 1, y, w + 2, h, " ")
  local startIdx = math.max(1, #state.history - h + 1 - state.scrollOffset)
  local endIdx = math.min(#state.history, startIdx + h - 1)
  local row = y
  for i = startIdx, endIdx do
    local entry = state.history[i]
    g.setForeground(entry.color or tui.colors.foreground)
    g.set(x, row, usub(entry.text, 1, w))
    row = row + 1
  end
  g.setForeground(tui.colors.foreground)
  tui.drawStatus()
  tui.drawInput()
end

function tui.scrollUp(lines)
  lines = lines or 1
  local _, _, _, h = getContentBounds()
  local maxScroll = math.max(0, #state.history - h)
  state.scrollOffset = math.min(maxScroll, state.scrollOffset + lines)
  pcall(tui.redrawContent)
end

function tui.scrollDown(lines)
  lines = lines or 1
  state.scrollOffset = math.max(0, state.scrollOffset - lines)
  pcall(tui.redrawContent)
end

function tui.scrollToBottom()
  state.scrollOffset = 0
  pcall(tui.redrawContent)
end

function tui.scrollToTop()
  local _, _, _, h = getContentBounds()
  state.scrollOffset = math.max(0, #state.history - h)
  pcall(tui.redrawContent)
end

-- 绘制输入行（底部: 提示符 + 文本 + 反色块光标 + Tab 候选提示）
function tui.drawInput()
  local g = component.gpu
  local y = state.height
  g.setBackground(tui.colors.background)
  g.fill(1, y, state.width, 1, " ")
  g.setForeground(tui.colors.prompt)
  g.set(2, y, "> ")
  g.setForeground(tui.colors.foreground)
  local inputStart = 4
  local maxWidth = state.width - inputStart - 1
  local displayText = state.inputBuffer
  local visibleCursorPos = state.inputCursor
  if ulen(displayText) > maxWidth then
    local start = math.max(1, state.inputCursor - maxWidth + 10)
    displayText = usub(state.inputBuffer, start, start + maxWidth - 1)
    visibleCursorPos = state.inputCursor - (start - 1)
  end
  g.set(inputStart, y, displayText)
  -- 反色块光标
  local cursorX = inputStart + visibleCursorPos
  if cursorX <= state.width - 1 then
    local ch = usub(state.inputBuffer, state.inputCursor + 1, state.inputCursor + 1)
    if ch == "" then ch = " " end
    g.setBackground(tui.colors.foreground)
    g.setForeground(tui.colors.background)
    g.set(cursorX, y, ch)
    g.setBackground(tui.colors.background)
    g.setForeground(tui.colors.foreground)
  end
  -- Tab 补全候选提示（输入行末尾）
  if state.completionCycle and state.completionCycle[2] then
    local hint = "Tab: " .. tostring(state.completionCycle[2].cmd)
    if ulen(displayText) + ulen(hint) + inputStart < state.width then
      g.setForeground(tui.colors.tool)
      g.set(state.width - ulen(hint) - 1, y, hint)
      g.setForeground(tui.colors.foreground)
    end
  end
  pcall(term.setCursor, cursorX, y)
  pcall(term.setCursorBlink, false)
end

-- 补全候选: 命令 + 工具名 + 注册前缀处理器
local function completionCandidates(buffer)
  local results = {}
  local lower = buffer:lower()
  -- 前缀处理器（completionHandlers，如 /model 的模型候选）
  for prefix, h in pairs(completionHandlers) do
    if buffer:sub(1, #prefix) == prefix then
      local extra = h.handler(buffer)
      if extra then
        for _, cand in ipairs(extra) do results[#results + 1] = cand end
      end
    end
  end
  -- 静态候选（命令 + 工具名）
  for _, cand in ipairs(state.completions) do
    local c = type(cand) == "string" and cand or cand.cmd
    if lower == "" or c:lower():find(lower, 1, true) == 1 then
      results[#results + 1] = type(cand) == "string" and {cmd = cand, desc = ""} or cand
    end
  end
  -- 去重保序
  local seen, dedup = {}, {}
  for _, r in ipairs(results) do
    if not seen[r.cmd] then seen[r.cmd] = true dedup[#dedup + 1] = r end
  end
  return dedup
end

function tui.registerCompletion(prefix, handler, label)
  completionHandlers[prefix] = {handler = handler, label = label}
end

-- 事件驱动输入: 键盘编辑 + 历史浏览 + Tab 补全 + 滚动 + Ctrl+C。
-- 无 keyboard 组件时回退 io.read（机器人）。
function tui.readInput()
  local ok_kb, kb_avail = pcall(function()
    return keyboard.isAvailable and keyboard.isAvailable()
  end)
  if not ok_kb or not kb_avail then
    io.write("> ")
    io.flush()
    local ok, line = pcall(io.read, "*l")
    if not ok then return nil end
    return (line or ""):gsub("\r?\n", "")
  end

  state.inputBuffer = ""
  state.inputCursor = 0
  state.completionCycle = nil
  local cursorVisible = true
  local lastBlink = computer.uptime()

  pcall(tui.drawInput)

  while true do
    local ev, _, char, code = event.pull(0.25)

    -- 光标闪烁
    local now = computer.uptime()
    if now - lastBlink >= 0.5 then
      cursorVisible = not cursorVisible
      lastBlink = now
      -- 简化: 闪烁只做定时重绘提示（块光标常亮，不闪烁——机器人帧率友好）
    end

    if ev == "interrupted" then
      return nil
    elseif ev == "key_down" then
      local ch = char or 0
      if ch == 13 then -- Enter
        local line = state.inputBuffer
        if line ~= "" then
          state.cmdHistory[#state.cmdHistory + 1] = line
          if #state.cmdHistory > 50 then table.remove(state.cmdHistory, 1) end
        end
        state.cmdHistoryIndex = 0
        state.savedInput = ""
        state.completionCycle = nil
        tui.print("> " .. line, tui.colors.user)
        return line
      elseif ch == 8 or code == 14 then -- Backspace
        if state.inputCursor > 0 then
          state.inputBuffer = usub(state.inputBuffer, 1, state.inputCursor - 1)
            .. usub(state.inputBuffer, state.inputCursor + 1)
          state.inputCursor = state.inputCursor - 1
          state.completionCycle = nil
        end
      elseif code == 203 then -- Left
        if state.inputCursor > 0 then state.inputCursor = state.inputCursor - 1 end
        state.completionCycle = nil
      elseif code == 205 then -- Right
        if state.inputCursor < ulen(state.inputBuffer) then
          state.inputCursor = state.inputCursor + 1
        end
        state.completionCycle = nil
      elseif code == 199 then -- Home
        state.inputCursor = 0
      elseif code == 207 then -- End
        state.inputCursor = ulen(state.inputBuffer)
      elseif code == 211 then -- Delete
        local len = ulen(state.inputBuffer)
        if state.inputCursor < len then
          state.inputBuffer = usub(state.inputBuffer, 1, state.inputCursor)
            .. usub(state.inputBuffer, state.inputCursor + 2)
        end
        state.completionCycle = nil
      elseif code == 200 then -- Up: 历史上翻
        if #state.cmdHistory > 0 then
          if state.cmdHistoryIndex == 0 then state.savedInput = state.inputBuffer end
          if state.cmdHistoryIndex < #state.cmdHistory then
            state.cmdHistoryIndex = state.cmdHistoryIndex + 1
            state.inputBuffer = state.cmdHistory[#state.cmdHistory - state.cmdHistoryIndex + 1]
            state.inputCursor = ulen(state.inputBuffer)
          end
        end
      elseif code == 208 then -- Down: 历史下翻
        if state.cmdHistoryIndex > 0 then
          state.cmdHistoryIndex = state.cmdHistoryIndex - 1
          if state.cmdHistoryIndex == 0 then
            state.inputBuffer = state.savedInput
          else
            state.inputBuffer = state.cmdHistory[#state.cmdHistory - state.cmdHistoryIndex + 1]
          end
          state.inputCursor = ulen(state.inputBuffer)
        end
      elseif code == 201 then -- PgUp: 上滚
        tui.scrollUp(state.height - 4)
      elseif code == 209 then -- PgDn: 下滚
        tui.scrollDown(state.height - 4)
      elseif code == 15 then -- Tab: 补全循环
        local cands = completionCandidates(state.inputBuffer)
        if #cands > 0 then
          if not state.completionCycle then state.completionCycle = {cands, cands[1]} end
          state.inputBuffer = state.completionCycle[2].cmd
          state.inputCursor = ulen(state.inputBuffer)
        end
      elseif ch >= 32 and ch < 127 then -- 可打印 ASCII
        state.inputBuffer = usub(state.inputBuffer, 1, state.inputCursor)
          .. string.char(ch)
          .. usub(state.inputBuffer, state.inputCursor + 1)
        state.inputCursor = state.inputCursor + 1
        state.completionCycle = nil
      end
      pcall(tui.drawInput)
    elseif ev == "clipboard" then
      if char then
        state.inputBuffer = usub(state.inputBuffer, 1, state.inputCursor)
          .. char
          .. usub(state.inputBuffer, state.inputCursor + 1)
        state.inputCursor = state.inputCursor + ulen(char)
        state.completionCycle = nil
        pcall(tui.drawInput)
      end
    end
  end
end

function tui.isRunning()
  return state.running
end

function tui.stop()
  state.running = false
end

-- 清空会话显示
function tui.clear()
  state.history = {}
  state.scrollOffset = 0
  pcall(function()
    term.clear()
    tui.drawHeader()
    tui.drawStatus()
    tui.drawInput()
  end)
end

-- 退出恢复终端
function tui.cleanup()
  pcall(function()
    term.clear()
    local g = component.gpu
    g.setBackground(0x000000)
    g.setForeground(0xffffff)
  end)
end

-- 测试/调试只读: 内容区消息列表 {text, color}
function tui.history()
  return state.history
end

return tui
