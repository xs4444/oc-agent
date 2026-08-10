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
-- computer 模块（pcall 保护）：readInput 光标闪烁计时用。**不能依赖全局
-- computer**——荒野大师/OCEmu 无全局（debug.lua:59 同款坑：oc_mock 注入
-- 全局 computer 掩盖，真机崩溃）。
local ok_cp, computer = pcall(require, "computer")
-- 缺库降级: 无 GPU/键盘组件时绘制静默失败，纯逻辑（history/滚动/补全）
-- 仍可用（测试环境/机器人）。
if not ok_c then component = {} end
if not ok_t then term = {} end
if not ok_e then event = {} end
if not ok_k then keyboard = {} end
if not ok_cp or type(computer) ~= "table" then computer = nil end

-- 计时源：优先 computer.uptime()（真实 OC 开机秒），缺失时 os.clock()
-- 兜底（闪烁计时仅装饰，精度无关紧要）
local function now_seconds()
  if computer and computer.uptime then
    local ok_u, u = pcall(computer.uptime)
    if ok_u and type(u) == "number" then return u end
  end
  return os.clock()
end

-- UTF-8 显示宽度（OC 等宽屏: ASCII 1 列, CJK/多字节 2 列——中文按 1 字符
-- 计算会导致换行/光标/截断全部错位，长中文行溢出炸布局）
local function ulen(s)
  local n = 0
  for ch in tostring(s):gmatch("([\1-\127\194-\244][\128-\191]*)") do
    if ch:byte(1) < 128 then n = n + 1 else n = n + 2 end
  end
  return n
end
local function usub(s, i, j)
  local str = tostring(s)
  local start_char, end_char = math.max(1, i or 1), j or -1
  local out, count = {}, 0
  for ch in str:gmatch("([\1-\127\194-\244][\128-\191]*)") do
    count = count + 1
    if count >= start_char and (end_char < 0 or count <= end_char) then
      out[#out + 1] = ch
    end
    if end_char >= 0 and count > end_char then break end
  end
  return table.concat(out)
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
    -- 注意: 不能写 `return component.gpu and component.gpu.getResolution()`
    -- —— Lua 的 and 只保留第一个返回值, getResolution 的高度会丢失(h=nil),
    -- 导致恒走兜底 80x25。须显式分支保留多返回值。
    local g = component.gpu
    if g then return g.getResolution() end
    return nil
  end)
  -- 异常分辨率兜底（某些模拟器/远控返回怪异值 → 标准 80x25）
  if not ok or type(w) ~= "number" or type(h) ~= "number"
      or w < 20 or h < 8 or w > 320 or h > 160 then
    w, h = 80, 25
  end
  state.width, state.height = w, h
  state.running = true
  state.scrollOffset = 0
  -- 滚动型渲染探测（荒野大师等终端滚动型模拟器）：写入最底行 y=h 会触发
  -- 整屏上滚（帧缓冲模拟器如 ocvm/OCEmu 无此行为）。探测：先在 y=1 写
  -- 标记再写 y=h，标记被顶走即滚动型。**旧版先读后写是 bug——启动时
  -- 屏幕为空（term.clear 后），滚动后 y=1 被原 y=2 空行顶上 c1==c2 恒等，
  -- 探测永远失败（真机实证：v0.3.39 scrollSafe 未生效，状态栏内容滚进
  -- 内容区）。**set 单点与 fill 整行两种写入都测（滚动触发条件未知）。
  -- scrollSafe = true 时布局整体上移一行（最底行 h 永不写入），杜绝滚动。
  state.scrollSafe = false
  local ok_g, gpu0 = pcall(function() return component.gpu end)
  if ok_g and gpu0 and gpu0.set and gpu0.get and gpu0.fill then
    local function scroll_probe(write_bottom)
      pcall(gpu0.fill, 1, 1, 3, 3, " ")     -- 清左上角（含 y=1 标记位）
      pcall(gpu0.set, 1, 1, "M")            -- 写标记
      local ok1, c1 = pcall(gpu0.get, 1, 1)
      if not (ok1 and c1 == "M") then return false end
      pcall(write_bottom)
      local ok2, c2 = pcall(gpu0.get, 1, 1)
      return ok2 and c1 ~= c2
    end
    -- 测 1: 单点 set 写 y=h
    if scroll_probe(function() pcall(gpu0.set, 1, h, "Z") end) then
      state.scrollSafe = true
    else
      -- 测 2: fill 整行写 y=h（部分模拟器仅整行写入触发滚动）
      if scroll_probe(function() pcall(gpu0.fill, 1, h, 5, 1, "X") end) then
        state.scrollSafe = true
      end
    end
    pcall(gpu0.fill, 1, 1, 1, h, " ")  -- 清理探测痕迹（init 末尾 term.clear 再清一次）
  end
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
  if not g then return end  -- 无 gpu（测试/降级环境）静默
  g.setBackground(tui.colors.status)
  g.setForeground(tui.colors.statusText)
  g.fill(1, 1, state.width, 1, " ")
  g.setForeground(tui.colors.toolName)
  g.set(2, 1, "OC Agent")
  g.setForeground(tui.colors.statusText)
  -- hint 只宣传实际可用的滚动方式：PgUp/PgDn 在部分游戏/远程环境
  -- 不产生键码（荒野大师实测不可用），/up /down 命令是通用兜底
  local hint = "/help | /up /down scroll | /exit"
  if state.width >= ulen(hint) + 16 then
    g.set(state.width - ulen(hint) - 1, 1, hint)
  end
end

-- 绘制状态栏（h-1 行: status 左 + 动态数据右 + scroll 指示; scrollSafe 时上移一行）
function tui.drawStatus()
  local g = component.gpu
  if not g then return end  -- 无 gpu（测试/降级环境）静默
  local y = state.height - 1 - (state.scrollSafe and 1 or 0)
  g.setBackground(tui.colors.status)
  g.setForeground(tui.colors.statusText)
  g.fill(1, y, state.width, 1, " ")
  g.set(2, y, state.status)
  -- 多行输入指示（粘贴多行时: 显示行数，提示 Enter 提交全部）
  if state.inputBuffer and state.inputBuffer:find("\n", 1, true) then
    local n = 0
    for _ in state.inputBuffer:gmatch("\n") do n = n + 1 end
    g.setForeground(tui.colors.tool)
    g.set(ulen(state.status) + 4, y, "ML:" .. tostring(n + 1) .. " (Enter=send)")
    g.setForeground(tui.colors.statusText)
  end
  if state.statusData then
    -- pcall 防御: 回调内任何异常（如 provider usage 结构怪异）都不应
    -- 中断状态栏绘制——否则状态栏只剩 status 文本（真机曾现"完成后
    -- 只剩 Ready，model/ctx/cache 全丢"）
    local ok_data, data = pcall(state.statusData)
    if ok_data and data and data ~= "" then
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

-- 内容区边界（含滚动窗口高度）; scrollSafe 时整体上移一行（内容区少 1 行）
local function getContentBounds()
  return 2, 2, state.width - 2, state.height - 3 - (state.scrollSafe and 1 or 0)
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

-- 翻页步长（半屏）——/up /down 命令与 PgUp/PgDn 失效时的兜底
-- scrollSafe 时内容区矮 1 行 → 步长同步 -1，与内容区一致
function tui.pageStep()
  return math.max(1, state.height - 4 - (state.scrollSafe and 1 or 0))
end

-- 多行 buffer 支持: 粘贴内容（含 \n）完整保留，输入行只显示最后一行，
-- 编辑限定在最后一行（跨行编辑不做），Enter 提交整个多行内容。
-- 返回 buffer 中最后一个 \n 的【字符】位置（无则 0）——与 inputCursor
-- 的字符语义一致（usub 操作字符，避免中文混用时字节/字符错位）。
local function lastLineStart(buffer)
  local idx = 0
  local pos = 0
  for ch in tostring(buffer):gmatch("([\1-\127\194-\244][\128-\191]*)") do
    pos = pos + 1
    if ch == "\n" then idx = pos end
  end
  return idx
end

-- 绘制输入行（底部: 提示符 + 最后一行文本 + 反色块光标 + Tab 候选提示;
-- scrollSafe 时上移一行, 最底行 h 永不写入——杜绝终端滚动型模拟器触发整屏上滚）
function tui.drawInput()
  local g = component.gpu
  if not g then return end  -- 无 gpu（测试/降级环境）静默
  local y = state.height - (state.scrollSafe and 1 or 0)
  g.setBackground(tui.colors.background)
  g.fill(1, y, state.width, 1, " ")
  local line_start = lastLineStart(state.inputBuffer)
  local multiline = line_start > 0
  g.setForeground(tui.colors.prompt)
  g.set(2, y, multiline and ">> " or "> ")
  g.setForeground(tui.colors.foreground)
  local inputStart = multiline and 5 or 4
  local maxWidth = state.width - inputStart - 1
  -- 只显示最后一行（历史行提交时在内容区打印）
  local displayText = multiline and usub(state.inputBuffer, line_start + 1)
    or state.inputBuffer
  local cursorInLine = math.max(0, state.inputCursor - line_start)
  -- 光标 x 位置按显示宽度（中文占 2 列，字符索引会错位）
  local cursorX = inputStart + ulen(usub(displayText, 1, cursorInLine))
  if ulen(displayText) > maxWidth then
    local start = math.max(1, cursorInLine - maxWidth + 10)
    displayText = usub(displayText, start, start + maxWidth - 1)
  end
  g.set(inputStart, y, displayText)
  -- 反色块光标
  if cursorX <= state.width - 1 then
    local ch = usub(displayText, cursorInLine + 1, cursorInLine + 1)
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
  -- 键盘可用性检测（荒野大师/OCEmu 同款 OpenOS 库缺 keyboard.isAvailable，
  -- 但组件存在且事件驱动正常——真机探针实证 key_down 全键标准格式到达）：
  -- isAvailable 缺失时回退到组件检测；组件可用即走事件驱动分支，否则
  -- io.read 回退（机器人）。此前缺失误判导致每次 readInput 走 io.read
  -- 回退（io.write 直写终端层 + 阻塞读行）——Tab/方向键/Ctrl 组合全部
  -- "无反应"、空回车多状态栏，均由此产生。
  local ok_kb, kb_avail = pcall(function()
    if keyboard.isAvailable then return keyboard.isAvailable() end
    local ok_c, comp = pcall(require, "component")
    return ok_c and comp.isAvailable and comp.isAvailable("keyboard")
  end)
  if not ok_kb or not kb_avail then
    io.write("> ")
    io.flush()
    local ok, line = pcall(io.read, "*l")
    if not ok then return nil end
    line = (line or ""):gsub("\r?\n", "")
    -- 与事件驱动分支一致：提交内容进内容区（主循环不回显，统一由
    -- readInput 打印——v0.3.40 键盘检测修复后事件驱动激活，双重回显
    -- 曾导致同一消息两行）
    if line ~= "" then tui.print("> " .. line, tui.colors.user) end
    return line
  end

  state.inputBuffer = ""
  state.inputCursor = 0
  state.completionCycle = nil
  local cursorVisible = true
  local lastBlink = now_seconds()

  pcall(tui.drawInput)

  while true do
    local ev, _, char, code = event.pull(0.25)

    -- 光标闪烁
    local now = now_seconds()
    if now - lastBlink >= 0.5 then
      cursorVisible = not cursorVisible
      lastBlink = now
      -- 简化: 闪烁只做定时重绘提示（块光标常亮，不闪烁——机器人帧率友好）
    end

    if ev == "interrupted" then
      return nil
    elseif ev == "key_down" then
      local ch = char or 0
      local line_start = lastLineStart(state.inputBuffer)  -- 编辑边界（最后一行起点）
      if ch == 13 then -- Enter
        local line = state.inputBuffer
        if line == "" or line:match("^%s+$") then
          -- 空回车/空白回车: 留在输入循环（重绘输入行）——不返回主循环，
          -- 避免终端换行/状态栏闪烁等副作用。
          -- 空白字符（空格/全角空格/Tab）必须同样拦截：否则空白消息被
          -- 当真输入提交 → Thinking 状态 + 完整请求 → 空回答重试网再一轮
          -- → 状态栏 Ready→Thinking→...反复切换（真机"多个状态栏"根因）
          state.completionCycle = nil
          pcall(tui.drawInput)
        else
          state.cmdHistory[#state.cmdHistory + 1] = line
          if #state.cmdHistory > 50 then table.remove(state.cmdHistory, 1) end
          tui.print("> " .. line, tui.colors.user)
          state.cmdHistoryIndex = 0
          state.savedInput = ""
          state.completionCycle = nil
          return line
        end
      elseif ch == 8 or code == 14 then -- Backspace（限最后一行，不删 \n）
        if state.inputCursor > line_start then
          state.inputBuffer = usub(state.inputBuffer, 1, state.inputCursor - 1)
            .. usub(state.inputBuffer, state.inputCursor + 1)
          state.inputCursor = state.inputCursor - 1
          state.completionCycle = nil
        end
      elseif code == 203 then -- Left（不跨行）
        if keyboard.isControlDown and keyboard.isControlDown() then
          -- Ctrl+Left: 前一个单词边界（字符索引）
          local pos = state.inputCursor
          while pos > line_start and usub(state.inputBuffer, pos, pos):match("%s") do
            pos = pos - 1
          end
          while pos > line_start and not usub(state.inputBuffer, pos, pos):match("%s") do
            pos = pos - 1
          end
          state.inputCursor = pos
        elseif state.inputCursor > line_start then
          state.inputCursor = state.inputCursor - 1
        end
        state.completionCycle = nil
      elseif code == 205 then -- Right
        if keyboard.isControlDown and keyboard.isControlDown() then
          -- Ctrl+Right: 下一个单词边界（字符索引）
          local len = ulen(state.inputBuffer)
          local pos = state.inputCursor
          while pos < len and not usub(state.inputBuffer, pos + 1, pos + 1):match("%s") do
            pos = pos + 1
          end
          while pos < len and usub(state.inputBuffer, pos + 1, pos + 1):match("%s") do
            pos = pos + 1
          end
          state.inputCursor = pos
        elseif state.inputCursor < ulen(state.inputBuffer) then
          state.inputCursor = state.inputCursor + 1
        end
        state.completionCycle = nil
      elseif code == 199 then -- Home（行首; Ctrl=滚到顶）
        if keyboard.isControlDown and keyboard.isControlDown() then
          tui.scrollToTop()
        else
          state.inputCursor = line_start
        end
      elseif code == 207 then -- End（buffer 尾 = 最后一行尾; Ctrl=滚到底）
        if keyboard.isControlDown and keyboard.isControlDown() then
          tui.scrollToBottom()
        else
          state.inputCursor = ulen(state.inputBuffer)
        end
      elseif code == 211 then -- Delete（最后一行内）
        local len = ulen(state.inputBuffer)
        if state.inputCursor < len then
          state.inputBuffer = usub(state.inputBuffer, 1, state.inputCursor)
            .. usub(state.inputBuffer, state.inputCursor + 2)
        end
        state.completionCycle = nil
      elseif code == 200 then -- Up: Ctrl=上滚 1 行; 否则历史上翻（多行 buffer 时禁用）
        if keyboard.isControlDown and keyboard.isControlDown() then
          tui.scrollUp(1)
        elseif line_start == 0 and #state.cmdHistory > 0 then
          if state.cmdHistoryIndex == 0 then state.savedInput = state.inputBuffer end
          if state.cmdHistoryIndex < #state.cmdHistory then
            state.cmdHistoryIndex = state.cmdHistoryIndex + 1
            state.inputBuffer = state.cmdHistory[#state.cmdHistory - state.cmdHistoryIndex + 1]
            state.inputCursor = ulen(state.inputBuffer)
          end
        end
      elseif code == 208 then -- Down: Ctrl=下滚 1 行; 否则历史下翻（多行时禁用）
        if keyboard.isControlDown and keyboard.isControlDown() then
          tui.scrollDown(1)
        elseif line_start == 0 and state.cmdHistoryIndex > 0 then
          state.cmdHistoryIndex = state.cmdHistoryIndex - 1
          if state.cmdHistoryIndex == 0 then
            state.inputBuffer = state.savedInput
          else
            state.inputBuffer = state.cmdHistory[#state.cmdHistory - state.cmdHistoryIndex + 1]
          end
          state.inputCursor = ulen(state.inputBuffer)
        end
      elseif code == 201 then -- PgUp: 上滚
        tui.scrollUp(tui.pageStep())
      elseif code == 209 then -- PgDn: 下滚
        tui.scrollDown(tui.pageStep())
      elseif ch == 27 then -- Esc: 关闭补全循环（oc-ai 同）
        state.completionCycle = nil
      elseif ch == 9 or code == 15
          or (ch == 32 and keyboard.isControlDown and keyboard.isControlDown()) then
        -- 补全触发: Tab（char 或 code 双判断——oc-ai 用 char==9）或 Ctrl+Space。
        -- 荒野大师全屏 TUI 实测: Home/End/方向键/Ctrl 组合全有效但 Tab 事件
        -- 被游戏客户端拦截（Minecraft Tab=玩家列表），故加 Ctrl+Space 备用触发。
        local cands = completionCandidates(state.inputBuffer)
        -- 可见诊断反馈: 无候选/有候选都更新状态栏, 用于区分
        -- "Tab 事件没到达"(状态栏无变化) vs "候选为空"(显示 Tab: no match)
        if #cands > 0 then
          if not state.completionCycle then state.completionCycle = {cands, cands[1]} end
          state.inputBuffer = state.completionCycle[2].cmd
          state.inputCursor = ulen(state.inputBuffer)
          tui.setStatus("Tab: " .. state.completionCycle[2].cmd
            .. (#cands > 1 and (" (" .. #cands .. " candidates)") or ""))
        else
          tui.setStatus("Tab: no match")
        end
      elseif ch >= 32 and ch < 127 then -- 可打印 ASCII
        state.inputBuffer = usub(state.inputBuffer, 1, state.inputCursor)
          .. string.char(ch)
          .. usub(state.inputBuffer, state.inputCursor + 1)
        state.inputCursor = state.inputCursor + 1
        state.completionCycle = nil
      else
        -- 诊断（v0.3.29 临时）: 未匹配任何分支的 key_down——用于定位荒野大师
        -- 真机 Tab 无反应：若 Tab 事件到达但 char/code 值不同，会落入此分支
        -- 并显示实际值；若状态栏仍无变化则事件根本未到达 agent。
        tui.setStatus("kd?" .. tostring(char) .. "/" .. tostring(code))
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
    elseif ev == "touch" or ev == "drag" then
      -- 指针定位（v0.3.68 新增，OpenOS 终端同款——真机 4 盘场景用户
      -- 需求"捕获指针操作复制粘贴"）: screen 组件发 touch/drag
      -- (x, y, button, player)。点击输入行 → 把输入光标定位到点击列
      -- （按显示宽度换算：中文占 2 列）；点击消息区/状态栏 → 不打断
      -- 编辑（拖选复制是客户端功能，机器侧静默——此前 touch 事件落入
      -- 循环底部未匹配分支被丢弃，点击完全无反应）。
      local tx, ty = char, code
      if type(tx) == "number" and type(ty) == "number" then
        local inputY = state.height - (state.scrollSafe and 1 or 0)
        if ty == inputY then
          -- 输入行: 按列换算字符索引（第 1 列是边框，prompt 从 4/5 列起）
          local line_start = lastLineStart(state.inputBuffer)
          local multiline = line_start > 0
          local inputStart = multiline and 5 or 4
          local rel = tx - inputStart
          if rel < 0 then rel = 0 end
          -- 遍历显示文本找 rel 列对应字符索引（逐字符累积显示宽度）
          local displayText = multiline and usub(state.inputBuffer, line_start + 1)
            or state.inputBuffer
          local idx = 0
          local w = 0
          while idx < ulen(displayText) do
            local ch = usub(displayText, idx + 1, idx + 1)
            local cw = ulen(ch) == 2 and 2 or 1
            if w + cw > rel then break end
            w = w + cw
            idx = idx + 1
          end
          state.inputCursor = line_start + idx
          state.completionCycle = nil
          pcall(tui.drawInput)
        end
      end
    elseif ev == "scroll" then
      -- 鼠标滚轮: char == 1 上滚 3 行, -1 下滚 3 行（oc-ai 同）
      if char == 1 then
        tui.scrollUp(3)
      elseif char == -1 then
        tui.scrollDown(3)
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

-- 进入 TUI 时显示会话历史（填充内容区，避免空屏/下半空白）:
-- 最近优先，最多 30 条；跳过 folded 折叠段与空内容；
-- 摘要消息（[对话摘要] system）以 dim 色显示。按旧→新顺序打印。
-- 当前不截断：完整显示（内容区可滚动查看全文）。
function tui.printHistory(messages)
  if type(messages) ~= "table" then return end
  local collected = {}
  for i = #messages, 1, -1 do
    if #collected >= 30 then break end
    local m = messages[i]
    if m and not m.folded then
      if m.role == "user" then
        local c = tostring(m.content or "")
        if c ~= "" then collected[#collected + 1] = {role = "user", text = c} end
      elseif m.role == "assistant" and m.content then
        local c = tostring(m.content)
        if c ~= "" then collected[#collected + 1] = {role = "assistant", text = c} end
      elseif m.role == "system" and type(m.content) == "string"
          and m.content:match("^%[对话摘要%]") then
        collected[#collected + 1] = {role = "system", text = m.content}
      end
    end
  end
  for i = #collected, 1, -1 do
    local e = collected[i]
    if e.role == "user" then
      tui.printRole("user", e.text)
    elseif e.role == "assistant" then
      tui.printRole("assistant", e.text)
    else
      tui.print(e.text, tui.colors.dim)
    end
  end
end

-- 测试钩子: 直接设置输入 buffer（模拟粘贴结果）——ocvm 上事件循环模拟
-- 不可靠（协程 event.pull 卡死），真机验证渲染路径用此钩子。
function tui.debug_set_buffer(s)
  state.inputBuffer = tostring(s or "")
  state.inputCursor = ulen(state.inputBuffer)
end

return tui
