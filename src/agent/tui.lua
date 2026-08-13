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
-- 宽字符判定模块（v0.3.116）: musl wcwidth 区间表（与 OC 真机 FontUtils.scala
-- 一致）。根因修复: 旧 isWideChar=#ch>=3 把 en dash(U+2013)/em dash 等
-- 3 字节但真机 1 列的字符误判为宽字符 → 混排选中偏移。pcall 保护:
-- 缺模块时回落旧启发（#ch>=3），不阻塞启动/测试。
local ok_w, wcwidth = pcall(require, "agent.wcwidth")
if not ok_w or type(wcwidth) ~= "table" then wcwidth = nil end
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

-- ═══════════════════════════════════════════════════════════════
-- UTF-8 工具区（v0.3.111 宽字符修复）
-- OC 等宽屏: ASCII 1 列, CJK/多字节 UTF-8 占 2 列（第二格 padding）。
-- 全文件两套坐标系（缺一即错位）:
--   · 列（column）: 屏幕格坐标（gpu.set/get/fill、csel、selFrom…）
--   · 字符索引（char）: 字符串内字符序号（inputCursor、state.sel、
--     search.from/to、usub 参数）
-- 中文按 1 字符/1 字节计算 → 换行/光标/截断/选中全部错位，长中文行
-- 溢出炸布局（用户报告: 鼠标选中英文正常、中文有 bug）。
-- 以下工具统一做 列⇄字符 换算（vim drawscreen.c:941-943 双游标对译:
-- 字符游标迭代 + 列游标累积）。
-- ═══════════════════════════════════════════════════════════════

-- 显示宽度（列数）: ASCII 1 列, 宽字符 2 列。
-- v0.3.116: 宽度判定改用 wcwidth 区间表（真机 musl 语义）——旧
-- ch:byte(1)<128 把 en/em dash(3 字节 1 列) 等误计 2 列, 列坐标整体偏移。
local function ulen(s)
  local n = 0
  for ch in tostring(s):gmatch("([\1-\127\194-\244][\128-\191]*)") do
    if wcwidth then
      n = n + wcwidth.wcwidth(wcwidth.codepointOf(ch))
    elseif ch:byte(1) < 128 then
      n = n + 1
    else
      n = n + 2
    end
  end
  return n
end
-- 字符索引取子串（i..j 为字符序号, j<0 = 到末尾）
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

-- 宽字符判定: 返回该字符是否占 2 列（wcwidth==2）。
-- v0.3.111: 从原 446 行上移到此工具区，供 charWidth/subCols 复用。
-- v0.3.116: 内部实现改用 wcwidth 模块（musl 区间表, 与 OC 真机一致）——
-- 旧 #ch>=3 把 en dash(U+2013)/em dash 等 3 字节 1 列字符误判宽字符
-- → 混排选中偏移（用户真机报告）。函数名/签名/布尔语义不变。
local function isWideChar(ch)
  if wcwidth then return wcwidth.isWide(ch) end
  return type(ch) == "string" and #ch >= 3
end

-- 单字符显示宽度（列数）: 1 或 2
local function charWidth(ch)
  return isWideChar(ch) and 2 or 1
end

-- 字符计数（按 UTF-8 字符，非字节）: 字节偏移 → 字符索引换算用
local function charCount(s)
  local n = 0
  for _ in tostring(s):gmatch("([\1-\127\194-\244][\128-\191]*)") do
    n = n + 1
  end
  return n
end

-- 按【列】截断: 返回列宽 ≤ maxCols 的最长前缀（末尾宽字符放不下则丢弃）
-- ——drawRow 行截断与 wrapText 硬断用（宁可短 1 列不可溢出炸布局）。
-- 与 subCols 不同: 这里不包含越界的宽字符。
local function truncateCols(s, maxCols)
  local col, out = 0, {}
  for ch in tostring(s):gmatch("([\1-\127\194-\244][\128-\191]*)") do
    local cw = charWidth(ch)
    if col + cw > maxCols then break end
    out[#out + 1] = ch
    col = col + cw
  end
  return table.concat(out)
end

-- 按【列】区间取子串（双游标: 迭代字符累积列宽）。colFrom 为 1 起始列,
-- colTo < 0 = 到行尾。宽字符整字符包含:
--   · colFrom 落在宽字符 padding 格 → 从该字符起点开始
--   · 宽字符跨越 colTo → 包含整个字符
-- 因此返回子串的列宽可能 < colFrom-1 或 > colTo（调用处容忍）。
-- 返回 (子串, 起始列, 结束列)（起始/结束列为 0 起始半开区间）。
local function subCols(s, colFrom, colTo)
  local str = tostring(s)
  colFrom = math.max(1, colFrom or 1)
  local chars = {}
  for ch in str:gmatch("([\1-\127\194-\244][\128-\191]*)") do
    chars[#chars + 1] = ch
  end
  local col, startIdx, endIdx, startCol = 0, nil, nil, 0
  for i = 1, #chars do
    local cw = charWidth(chars[i])
    if not startIdx and col + cw >= colFrom then
      startIdx = i
      startCol = col
    end
    col = col + cw
    if startIdx and colTo >= 0 and col >= colTo then
      endIdx = i
      break
    end
  end
  if not startIdx then return "", 0, 0 end
  return table.concat(chars, "", startIdx, endIdx or #chars), startCol, col
end

-- 列位置 → 字符索引（readInput 输入行点击定位——逐字符累积显示宽度
-- 求列→字符索引的正确实现抽取复用; v0.3.68 起）。落在宽字符 padding
-- 格时返回该字符索引。col ≤ 0 → 0（行首）。
local function charIndexAtCol(s, col)
  if col <= 0 then return 0 end
  local idx, w = 0, 0
  for ch in tostring(s):gmatch("([\1-\127\194-\244][\128-\191]*)") do
    local cw = charWidth(ch)
    if w + cw > col then break end
    w = w + cw
    idx = idx + 1
  end
  return idx
end

-- 字符区间（1 起始闭合）→ 列区间（0 起始半开 [from, to)）
-- ——search.from/to 为字符索引（findMatch 字节偏移转换），drawRow
-- 高亮时换算列区间。
local function charRangeToCols(s, fromChar, toChar)
  local col, i, cf, ct = 0, 0, nil, nil
  for ch in tostring(s):gmatch("([\1-\127\194-\244][\128-\191]*)") do
    i = i + 1
    local cw = charWidth(ch)
    if i == fromChar then cf = col end
    if i == toChar then ct = col + cw break end
    col = col + cw
  end
  return cf or 0, ct or col
end

-- 按列区间把一行切成 前缀/中段/后缀 三段（选中段/搜索段着色共用）。
-- relFrom/relTo: 0 起始半开列区间（相对行首）。宽字符整字符归属——
-- 不与区间边界交错（col+width ≤ relFrom → 前缀; col ≥ relTo → 后缀），
-- 分段永不把宽字符劈成两半。单次遍历完成三段的边界计算（drawRow
-- 每行只扫一遍，性能达标）。
local function splitLineByCols(line, relFrom, relTo)
  local pre, sel, suf = {}, {}, {}
  local col = 0
  for ch in tostring(line):gmatch("([\1-\127\194-\244][\128-\191]*)") do
    local cw = charWidth(ch)
    if col + cw <= relFrom then
      pre[#pre + 1] = ch
    elseif col >= relTo then
      suf[#suf + 1] = ch
    else
      sel[#sel + 1] = ch
    end
    col = col + cw
  end
  return table.concat(pre), table.concat(sel), table.concat(suf)
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
  -- 内容区选中（v0.3.100）: 屏幕坐标矩形 {ax,ay,bx,by} + 激活标志;
  -- 与输入行选中（state.sel）互斥。onCopy 由 init.lua 注入（写
  -- selected.txt 供 /debug gist 附带）。
  state.csel = nil
  state.csel_active = nil
  -- v0.3.115 双击/三击连击检测（内容区）: 同位置(|dx|,|dy|<=1)且间隔
  -- <500ms → clickCount 递增（1→2 选词, 2→3 选行, 3 后复位）。时间源
  -- now_seconds()（computer.uptime, mock 可 debug_advance_uptime 推进）。
  state.lastClickTime = nil
  state.lastClickX = nil
  state.lastClickY = nil
  state.clickCount = 0
  -- v0.3.114: 输入行选中同样随会话复位（Enter 提交不清 sel——上一会话
  -- 残留的选中会在新会话的粘贴/输入里触发错误的"替换选中"）
  state.sel = nil
  state.sel_active = nil
  tui.onCopy = config.onCopy
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
  -- 行缓存 + 脏行集合（v0.3.109, vim ScreenAttrs 比较移植）:
  -- lineCache[screenY] = {text=上次set串, color=fg, sel=选中态}——
  -- drawRow 前比较相同则跳过（组件调用 120/帧→个位数）;
  -- dirtyRows = {[screenY]=true}——redrawContent 只重画标记行，
  -- 全量重绘（print/滚动/缩放）标记全部可见行，增量（选中拖动/
  -- 光标闪烁）只标记受影响行。
  state.lineCache = {}
  state.dirtyRows = {}
  -- 键盘浏览/选择模式（v0.3.109, tmux copy-mode 移植）:
  -- /browse 进入 → hjkl 移动虚拟光标（映射 scrollOffset+屏幕坐标）、
  -- Space 开始选中（csel anchor=当前）、移动扩展选中（csel active 实时
  -- 派生渲染）、y 复制、q 退出。鼠标选中不精确时键盘可靠替代。
  state.browseMode = false
  state.browsePos = nil  -- {x, y} 屏幕坐标
  -- 搜索（v0.3.109 P1-3, tmux window_copy_search + vim hlsearch 移植）:
  -- state.search = {pattern=关键词, idx=匹配行历史索引, from,to=匹配段
  -- 列区间}。search() 从顶部找首匹配并跳转; searchNext(dir) n/N 循环。
  -- 匹配行 drawRow 派生高亮（tool 色，与选中反色互斥）。
  state.search = nil
  state.inputBuffer = ""
  state.inputCursor = 0
  -- v0.3.113 折行缓存: buffer 版本号（每次写 +1, 见 setInputBufferText）+
  -- 缓存 {version,width,lines,ranges,multiline} + 重算计数（测试断言）
  state.inputLinesVersion = 0
  state.inputLinesCache = nil
  state.inputReflowCount = 0
  -- v0.3.112 输入框多行: 显示高度（自动增高）+ 输入窗口滚动 + 滚轮路由
  -- （最后 touch/drag 的 y 决定 scroll 事件滚内容区还是输入框）
  state.inputHeight = 1
  state.inputScroll = 0
  state.lastTouchY = nil
  state.inputFollow = true  -- 输入窗口是否跟随光标（手动滚轮浏览时关）
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

-- 绘制状态栏（输入框上方 1 行: status 左 + 动态数据右 + scroll 指示;
-- v0.3.112 输入框自动增高 → 状态栏 y = 总高 - inputHeight - scrollSafe）
function tui.drawStatus()
  local g = component.gpu
  if not g then return end  -- 无 gpu（测试/降级环境）静默
  local y = state.height - (state.inputHeight or 1) - (state.scrollSafe and 1 or 0)
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

-- 内容区边界（含滚动窗口高度）; scrollSafe 时整体上移一行（内容区少 1 行）。
-- v0.3.112: 输入框自动增高 → 内容区高度 = 总高 - header(1) - status(1)
-- - inputHeight（inputHeight=1 时与旧公式完全一致）。
local function getContentBounds()
  local ih = math.max(1, state.inputHeight or 1)
  return 2, 2, state.width - 2, state.height - 2 - ih - (state.scrollSafe and 1 or 0)
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
            -- v0.3.111: 硬断按【列】切（中文占 2 列——旧 usub(word,1,width)
            -- 把列宽当字符数，中文长词每行溢出 width 列，总宽超屏炸布局）
            while ulen(word) > width do
              local chunk = truncateCols(word, width)
              if chunk == "" then chunk = usub(word, 1, 1) end  -- 单宽字符超宽防御
              lines[#lines + 1] = chunk
              word = usub(word, charCount(chunk) + 1)
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

-- ════════════════════════════════════════
-- 输入框多行支持（v0.3.112, 用户设计）:
-- "类似其他经典 agent 的输入框——根据行数自动增高（占用对话行），
--  到一定高度时滚轮换行; 通过光标所在的位置或最后点击的位置分辨
--  scroll 的是对话框还是输入框。"
-- 显示行 = wrapText(inputBuffer, 输入行宽) 折行结果; 窗口显示
-- inputHeight 行（上限 MAX_INPUT_HEIGHT）, inputScroll 滚动窗口。
-- 内容区高度 = 总高 - header(1) - status(1) - inputHeight（getContentBounds
-- 已集中改读 state.inputHeight, 全布局一处适配）。
-- ════════════════════════════════════════
local MAX_INPUT_HEIGHT = 8

-- inputBuffer 唯一写入口（v0.3.113）: 所有 buffer 修改点统一走这里——
-- 折行缓存版本号随写自增; 直接赋值会绕过缓存, 下次 inputDisplayLines
-- 返回脏数据（版本号没变但内容变了 → 假命中）。
local function setInputBufferText(text)
  state.inputBuffer = text
  state.inputLinesVersion = (state.inputLinesVersion or 0) + 1
end

-- 输入框显示行 + 每行字符区间（0 基半开 [start, start+len)）+ 多行标记。
-- 与 wrapText 同源折行（同一 gmatch 迭代——"ab\n" 无尾部空行,
-- 空 buffer → 1 个空行; 与历史换行行为完全一致）。
-- v0.3.113 折行缓存: buffer 版本号 + 折行宽度未变 → 直接返回缓存——
-- drawInput/syncInputHeight 每次按键/光标移动/滚动都调本函数, 几千字符
-- 时每次 O(n) 折行是输入卡顿根因。光标移动不改 buffer → 版本不变 →
-- 命中缓存（O(1)）。编辑/粘贴 → setInputBufferText 自增版本 → 1 次重算。
-- 重算次数计数（state.inputReflowCount）暴露给测试断言。
local function inputDisplayLines()
  local c = state.inputLinesCache
  local v = state.inputLinesVersion or 0
  if c and c.version == v then
    return c.lines, c.ranges, c.multiline
  end
  local buf = state.inputBuffer or ""
  local multiline = buf:find("\n", 1, true) ~= nil
  local maxWidth = state.width - (multiline and 6 or 5)
  if c and c.version == v and c.width == maxWidth then
    return c.lines, c.ranges, c.multiline
  end
  state.inputReflowCount = (state.inputReflowCount or 0) + 1
  local lines, ranges = {}, {}
  local charAcc = 0
  for line in buf:gmatch("([^\n]*)\n?") do
    if ulen(line) <= maxWidth then
      lines[#lines + 1] = line
      ranges[#ranges + 1] = {charAcc, charCount(line)}
      charAcc = charAcc + charCount(line) + 1
    else
      local remaining = line
      while ulen(remaining) > maxWidth do
        local chunk = truncateCols(remaining, maxWidth)
        if chunk == "" then chunk = usub(remaining, 1, 1) end
        local n = charCount(chunk)
        lines[#lines + 1] = chunk
        ranges[#ranges + 1] = {charAcc, n}
        charAcc = charAcc + n
        remaining = usub(remaining, n + 1)
      end
      lines[#lines + 1] = remaining
      ranges[#ranges + 1] = {charAcc, charCount(remaining)}
      charAcc = charAcc + charCount(remaining) + 1
    end
  end
  if #lines == 0 then lines, ranges = {""}, {{0, 0}} end
  state.inputLinesCache = {version = v, width = maxWidth,
    lines = lines, ranges = ranges, multiline = multiline}
  return lines, ranges, multiline
end

-- 输入高度同步: 显示行数 → inputHeight（上限 MAX_INPUT_HEIGHT）; 行数
-- 减少时 inputScroll clamp。返回高度是否变化——调用方据此决定全量
-- redrawContent（内容区高度变）还是只重绘输入框（防闪烁）。
local function syncInputHeight()
  local lines = inputDisplayLines()
  local newH = math.max(1, math.min(MAX_INPUT_HEIGHT, #lines))
  local changed = newH ~= (state.inputHeight or 1)
  state.inputHeight = newH
  local maxScroll = math.max(0, #lines - newH)
  if state.inputScroll > maxScroll then state.inputScroll = maxScroll end
  if state.inputScroll < 0 then state.inputScroll = 0 end
  return changed
end

-- 光标所在行字符区间（0 基半开 [start, endExclusive)）: 向前找 \n +
-- 向后找 \n。v0.3.112 编辑边界从"最后一行"改为"光标所在行"——
-- Backspace/Left/Right/Delete/Home/End 以当前行为界（不跨行、不删 \n）。
local function lineBoundsAt(s, cursor)
  local str = tostring(s or "")
  cursor = math.max(0, math.min(cursor or 0, charCount(str)))
  local chars = {}
  for ch in str:gmatch("([\1-\127\194-\244][\128-\191]*)") do
    chars[#chars + 1] = ch
  end
  local start = 0
  for i = 1, cursor do
    if chars[i] == "\n" then start = i end
  end
  local endEx = #chars
  for i = cursor + 1, #chars do
    if chars[i] == "\n" then endEx = i - 1 break end
  end
  return start, endEx
end

-- 光标上移/下移一个【显示】行（v0.3.112 多行编辑; Up/Down 跨行移动,
-- 列保持: 当前列宽 → charIndexAtCol 映射到目标行, clamp 到目标行宽）
local function moveCursorByDisplayLine(dir)
  local lines, ranges = inputDisplayLines()
  local c = state.inputCursor
  local idx = 1
  for i = 1, #lines do
    local r = ranges[i]
    if c >= r[1] and c < r[1] + r[2] then idx = i break end
  end
  -- 行尾（== 行末字符后一位）归到该行
  for i = 1, #lines do
    if c == ranges[i][1] + ranges[i][2] then idx = i break end
  end
  local target = idx + dir
  if target < 1 or target > #lines then return false end
  local rt = ranges[target]
  local text = lines[target]
  local curText = lines[idx] or ""
  local curOff = c - (ranges[idx][1] or 0)
  local colPx = ulen(usub(curText, 1, curOff))
  state.inputCursor = rt[1] + charIndexAtCol(text, colPx)
  return true
end

-- ════════════════════════════════════════
-- shift 选中编辑（v0.3.114, 用户: "shift 选中删除", 向经典终端学习）:
--   · shift+Left/Right/Home/End/Ctrl+方向/多行 Up/Down → 从锚点扩展
--     选中（state.sel 0 基 [min,max), sel_active=true）
--   · 无 shift 光标移动 → 取消选中
--   · Backspace/Delete 有选中 → 删整段; 可打印字符/粘贴有选中 → 替换
-- ════════════════════════════════════════

-- 删除激活选中区间 [min,max)（跨行, 与行界无关——用户删的是选中文本）;
-- 光标 = min, 清选中。无激活选中（或 a==b）返回 false（调用方走原逻辑）。
local function deleteSelection()
  local sel = state.sel
  if sel and state.sel_active and sel.a ~= sel.b then
    local lo, hi = math.min(sel.a, sel.b), math.max(sel.a, sel.b)
    setInputBufferText(usub(state.inputBuffer, 1, lo) .. usub(state.inputBuffer, hi + 1))
    state.inputCursor = lo
    state.sel = nil
    state.sel_active = nil
    return true
  end
  return false
end

-- 光标移动后的 shift 扩展（oldCursor = 移动前光标）:
--   shift 按下 → 无激活选中则锚点=oldCursor、终点=新光标; 已激活仅移终点
--   （touch/drag 拖选锚点继续生效——鼠标选中后 shift+方向继续扩展）。
--   无 shift → 取消选中（经典终端: 移动取消选中）。
local function applyShiftSelect(oldCursor)
  local shifted = keyboard.isShiftDown and keyboard.isShiftDown()
  if shifted then
    if not (state.sel and state.sel_active) then
      state.sel = {a = oldCursor, b = state.inputCursor}
      state.sel_active = true
    else
      state.sel.b = state.inputCursor
    end
  else
    state.sel = nil
    state.sel_active = nil
  end
end

-- 命令历史上翻/下翻（v0.3.115 抽出复用: bash 标准 ↑↓——光标在顶/底行时
-- 翻历史; 单行 buffer 恒翻历史）。buffer 整体替换 → 旧选中索引失效 → 清选中。
local function historyUp()
  if #state.cmdHistory == 0 then return end
  state.sel = nil
  state.sel_active = nil
  if state.cmdHistoryIndex == 0 then state.savedInput = state.inputBuffer end
  if state.cmdHistoryIndex < #state.cmdHistory then
    state.cmdHistoryIndex = state.cmdHistoryIndex + 1
    setInputBufferText(state.cmdHistory[#state.cmdHistory - state.cmdHistoryIndex + 1])
    state.inputCursor = charCount(state.inputBuffer)  -- v0.3.111: 字符索引
  end
end
local function historyDown()
  if state.cmdHistoryIndex == 0 then return end
  state.sel = nil
  state.sel_active = nil
  state.cmdHistoryIndex = state.cmdHistoryIndex - 1
  if state.cmdHistoryIndex == 0 then
    setInputBufferText(state.savedInput)
  else
    setInputBufferText(state.cmdHistory[#state.cmdHistory - state.cmdHistoryIndex + 1])
  end
  state.inputCursor = charCount(state.inputBuffer)  -- v0.3.111: 字符索引
end

-- 历史上限（v0.3.109, tmux history-limit 移植）: 2MB 真机内存约束下
-- 纯显示缓冲无上限 = OOM 风险源（长对话几十轮 assistant+工具结果
-- 可达几千行 × 每行 ~100B = 几百 KB）。历史只是显示缓冲（压缩后的
-- 真实对话在 session 文件），屏幕同时最多看 ~40 行。
-- 1000 行（约 100-150KB）: 覆盖典型 /hist dump（30 条消息 × 平均
-- 30 行 = 900 行）+ 正常运行余量——2MB 内存可承受，且不阉割回顾
-- 命令。超限从头部裁（tmux grid_trim_history 模式）并同步 scrollOffset。
local MAX_HISTORY = 1000

-- 追加历史行（含上限裁剪 + scrollOffset 联动）
local function appendHistory(entry)
  state.history[#state.history + 1] = entry
  if #state.history > MAX_HISTORY then
    -- 从头部裁（tmux grid_trim_history）; 已滚动时 offset 同步 -1
    table.remove(state.history, 1)
    if state.scrollOffset > 0 then state.scrollOffset = state.scrollOffset - 1 end
    -- 选中坐标若在移除行内 → 清除选中（选中区随内容上移失效）
    if state.csel and state.csel.ay <= 2 then
      state.csel = nil
      state.csel_active = nil
    elseif state.csel then
      state.csel.ay = state.csel.ay - 1
      state.csel.by = state.csel.by - 1
    end
  end
end

-- 输出到内容区（自动滚动到底）
function tui.print(msg, color)
  local _, _, w = getContentBounds()
  color = color or tui.colors.foreground
  for _, line in ipairs(wrapText(msg, w)) do
    appendHistory({text = line, color = color})
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

-- ════════════════════════════════════════
-- 增量重绘（v0.3.109 P0-2）
-- ════════════════════════════════════════

-- drawRow 前向声明（v0.3.109 bug 修复）: drawRow 定义在文件下方
-- （选中渲染段，~493 行），但 flushDirty/redrawRowRange 先于它调用——
-- Lua 词法作用域下，未先声明的 local 在调用点绑定到全局 nil →
-- "attempt to call a nil value (global 'drawRow')" 真机崩溃
-- （tui.lua:381）。前向声明让下方 `drawRow = function(...)` 赋值到
-- 这个 local。
local drawRow

-- 标记脏行区间（vim mod_top/mod_bot 模式）: 只记录行号集合，
-- 不立即重画——flushDirty 统一处理。
local function markDirty(y0, y1)
  local _, y, _, h = getContentBounds()
  y0 = math.max(y, y0 or 0)
  y1 = math.min(y + h - 1, y1 or 0)
  if y0 > y1 then return end
  for row = y0, y1 do
    state.dirtyRows[row] = true
  end
end

-- 增量重绘（v0.3.109）: 只重画 dirtyRows 标记的行（drawRow 内部行缓存
-- 二次跳过——内容未变的行即使标记也不写屏）。重画后清标记。
-- 不 fill 整区（增量场景无残留——每行整行 set 覆盖）。
local function flushDirty()
  local g = component.gpu
  local x, y, w, h = getContentBounds()
  local startIdx = math.max(1, #state.history - h + 1 - state.scrollOffset)
  g.setBackground(tui.colors.background)
  for row, _ in pairs(state.dirtyRows) do
    if row >= y and row <= y + h - 1 then
      local idx = startIdx + (row - y)
      drawRow(g, x, row, startIdx, idx)
    end
  end
  g.setForeground(tui.colors.foreground)
  g.setBackground(tui.colors.background)
  state.dirtyRows = {}
end

-- 重绘内容区（v0.3.108: 统一走 drawRow 派生渲染——每行从 history 取
-- 文本 + 选中区间实时着色。全量重绘自动带选中高亮）
-- v0.3.109: 全量 = fill 清区 + 清行缓存（fill 已抹掉屏幕，缓存比较
-- 会跳过未变行 → 空白残留——必须全清）+ 标记全部可见行脏 + flushDirty。
function tui.redrawContent()
  local g = component.gpu
  syncInputHeight()  -- v0.3.112: 内容区高度随输入框动态——先同步再取边界
  local x, y, w, h = getContentBounds()
  -- v0.3.110 字体全黑修复: fill 前必须同时设置 foreground + background。
  -- v0.3.108 引入选中反色后，drawRow 选中段把 fg 改成 background(黑)，
  -- 若上一轮渲染停在选中段，这里只设 bg 不设 fg → fill 用残留黑 fg →
  -- 整区黑字空格；随后 drawRow 命中行缓存的行跳过不重画 → 该行保持
  -- 黑字 = "字体全黑，选中才亮"（选中行 drawRow 必 miss 缓存重画才亮）。
  -- v0.3.106 前无反色（fg 无残留）所以从未暴露。
  g.setForeground(tui.colors.foreground)
  g.setBackground(tui.colors.background)
  g.fill(x - 1, y, w + 2, h, " ")
  -- fill 后所有行缓存作废（屏幕已被抹掉，drawRow 缓存命中=跳过=空白）
  state.lineCache = {}
  markDirty(y, y + h - 1)
  flushDirty()
  g.setForeground(tui.colors.foreground)
  g.setBackground(tui.colors.background)
  tui.drawStatus()
  tui.drawInput()
end

-- ════════════════════════════════════════
-- 内容区选中（v0.3.100）: touch/drag 在内容区（非输入行）按下拖动 →
-- 选中矩形 state.csel = {ax,ay,bx,by}（屏幕坐标）→ 反色高亮实时重绘;
-- Ctrl+C / 拖选结束复制 → gpu.get 读回矩形文本 → 进程内剪贴板 +
-- onCopy 回调（init.lua 写 selected.txt，/debug gist 可附带）。
-- 与输入行选中（state.sel）互斥: 输入行 touch 优先。
-- ════════════════════════════════════════

-- 选中归一化（v0.3.106 流式选择）: 起点 = 按 (y, x) 字典序的较小角。
-- 返回 (a, b) 两个 {x, y}——a.y <= b.y 且同 y 时 a.x <= b.x。
local function normalizeCsel()
  local a = {x = state.csel.ax, y = state.csel.ay}
  local b = {x = state.csel.bx, y = state.csel.by}
  if b.y < a.y or (b.y == a.y and b.x < a.x) then a, b = b, a end
  return a, b
end

-- ═══════════════════════════════════════════════════════════════
-- 选中渲染（v0.3.108 重构——经典终端无状态派生模式，抄 tmux/vim）
--
-- exp-1 勘察结论（repos/tmux screen.c:28-42/533-634/642-657,
-- repos/vim drawscreen.c:1461-1504）: 经典终端选中 = "无状态派生
-- 渲染"——只存 (anchor, active) 两个坐标 + 活动标志，高亮样式
-- 从不写进字符存储，每帧从选中区间实时计算每个 cell 是否被选中。
-- 方向反转无残留的根本原因: 没有"之前反过色的格子"概念，就没有
-- 需要恢复的状态（tmux screen_check_selection 三分支纯比较 /
-- vim LTOREQ_POS 选 top/bot）。
--
-- 旧实现（逐格反色 + gpu.get 交错）违反此原则:
--   1. 状态累积: 反色→再反色配对，方向反转重叠格反色两次 → 错色
--   2. get 交错: 每格 get+set 4-5 次调用（80×40=16000 次/帧）→ 闪烁
--
-- 新实现（vim 行级整行重写模式在 OC 的适配）:
--   - 渲染每行从 history 取文本（数据源），命中选中区间则整行
--     分 3 段着色一次 set（前缀原色/选中段反色/后缀原色）
--   - 无 gpu.get: 恢复 = 重新派生（重绘行即恢复原色，天然无残留）
--   - 拖动只重绘受影响行区间 [min(old_y,new_y), max(old_y,new_y)]
--     （tmux window_copy_redraw_selection 模式）
-- ═══════════════════════════════════════════════════════════════

-- 行命中选中区间? 返回该行选中列区间 (from, to) 或 nil。
-- 纯比较（tmux screen_check_selection 思路）: 方向无关——anchor/active
-- 顺序不影响命中判断（先归一化再三分支）。
local function selectionSpan(row, x, w)
  if not state.csel or not state.csel_active then return nil end
  local a, b = normalizeCsel()
  local xmax = x + w - 1
  if row < a.y or row > b.y then return nil end
  local from, to
  if a.y == b.y then
    from, to = a.x, b.x
  elseif row == a.y then
    from, to = a.x, xmax
  elseif row == b.y then
    from, to = x, b.x
  else
    from, to = x, xmax
  end
  from = math.max(x, from)
  to = math.min(xmax, to)
  if from > to then return nil end
  return from, to
end

-- 派生渲染单行（vim win_line 模式）: 从 history 取文本，按选中
-- 区间分 3 段整段 set（前缀原色/选中段反色/后缀原色）——每行 ≤3 次
-- set，无 gpu.get。选中段反色: fg=背景色, bg=行原色（文字以原色为底
-- 黑字，可见且与角色色一致）。
-- v0.3.109 行缓存（vim ScreenAttrs 比较, screen.c:371）: drawRow 前
-- 比较 lineCache[screenY]（上次 set 的 text/color/sel 态），相同则
-- 跳过整行 set——gpu.set 是 JVM 桥接调用，跳过节省大量往返。
-- 注意: 缓存必须存**选中段具体范围**（{from,to} 或 nil）而非布尔——
-- 拖动时行可能一直在选中区间内但选中段位置变了（anchor 移动使
-- 选中段列区间变化），布尔比较相同会跳过 → 屏幕残留旧选中段。
-- v0.3.109 P1-3 搜索高亮: 命中 state.search 匹配行时，匹配段用
-- tool 色（tui.colors.tool）着色——与选中反色互斥（选中优先，
-- 匹配段在非选中部分显示）。缓存键加 srch 段（匹配段位置），
-- 搜索变化时行缓存失配 → 重画。
-- 返回是否实际写屏（false = 缓存命中跳过）。
drawRow = function(g, x, screenY, startIdx, idx)
  local _, _, w = getContentBounds()
  local entry = state.history[idx]
  if not entry then
    -- 空行: 缓存命中跳过（含选中段 nil）
    local cached = state.lineCache[screenY]
    if cached and cached.text == "" and cached.sel == nil and cached.srch == nil then
      return false
    end
    g.setForeground(tui.colors.foreground)
    g.setBackground(tui.colors.background)
    g.set(x, screenY, string.rep(" ", w))
    state.lineCache[screenY] = {text = "", color = tui.colors.foreground, sel = nil, srch = nil}
    return true
  end
  local color = entry.color or tui.colors.foreground
  -- v0.3.111: 按【列】截断（中文占 2 列——旧 usub(entry.text,1,w) 把列宽
  -- 当字符数，中文行显示溢出内容区右缘）
  local line = truncateCols(entry.text, w)
  -- v0.3.113: 补空格到满宽——scrollView 逐行 g.set 覆盖滚动（无 fill 全屏
  -- 擦除），行尾不补满会在新行比旧行短时残留旧字符（短行滚上来覆盖
  -- 长行 → 长行尾部字符残留在屏）。缓存 key 用补满后的 line（选中/搜索
  -- 三段渲染的 suf 段自然覆盖到行尾）。
  line = line .. string.rep(" ", math.max(0, w - ulen(line)))
  local selFrom, selTo = selectionSpan(screenY, x, w)
  local selRange = selFrom and {selFrom, selTo} or nil
  -- 搜索高亮段（v0.3.109 P1-3 + v0.3.111 列修正）: search.from/to 为
  -- 【字符索引】（findMatch 字节偏移已转换）→ charRangeToCols 换算
  -- 列区间——中文匹配段直接当列用会错位
  local srchRange = nil
  if state.search and state.search.idx == idx then
    local cf, ct = charRangeToCols(entry.text, state.search.from, state.search.to)
    local scf = x + cf
    local sct = x + ct - 1
    if sct >= x and scf <= x + w - 1 then
      scf = math.max(x, scf)
      sct = math.min(x + w - 1, sct)
      if scf <= sct then srchRange = {scf, sct} end
    end
  end
  -- 缓存比较（text/color/sel/srch 段全同 → 跳过）
  local cached = state.lineCache[screenY]
  local function rangeEq(a, b)
    if a == nil and b == nil then return true end
    return a and b and a[1] == b[1] and a[2] == b[2] or false
  end
  if cached and cached.text == line and cached.color == color
      and rangeEq(cached.sel, selRange) and rangeEq(cached.srch, srchRange) then
    return false
  end
  state.lineCache[screenY] = {text = line, color = color, sel = selRange, srch = srchRange}
  if not selFrom then
    -- 非选中行: 原色整行 + 可选搜索高亮段（3 段: 前缀/匹配/tool 色/后缀）
    -- v0.3.111: 选中/搜索段统一走 splitLineByCols 按【列】切三段——宽
    -- 字符整字符归属，分段位置精确（旧 usub 按字符数切，中文列偏移全错）。
    -- 各段起始列 = x + 累计 ulen(段)（段内无半字符，列宽计算精确）。
    if not srchRange then
      g.setForeground(color)
      g.setBackground(tui.colors.background)
      g.set(x, screenY, line)
      return true
    end
    local pre, srch, suf = splitLineByCols(line, srchRange[1] - x, srchRange[2] - x + 1)
    local preCols, srchCols = ulen(pre), ulen(srch)
    g.setBackground(tui.colors.background)
    if pre ~= "" then
      g.setForeground(color)
      g.set(x, screenY, pre)
    end
    if srch ~= "" then
      g.setForeground(tui.colors.tool)
      g.set(x + preCols, screenY, srch)
    end
    if suf ~= "" then
      g.setForeground(color)
      g.set(x + preCols + srchCols, screenY, suf)
    end
    return true
  end
  -- 选中行: 3 段着色（前缀原色 / 选中段反色 / 后缀原色）
  local pre, sel, suf = splitLineByCols(line, selFrom - x, selTo - x + 1)
  local preCols, selCols = ulen(pre), ulen(sel)
  g.setBackground(tui.colors.background)
  if pre ~= "" then
    g.setForeground(color)
    g.set(x, screenY, pre)
  end
  if sel ~= "" then
    -- 反色: fg=背景, bg=行原色（文字以原色为底、黑字）
    g.setForeground(tui.colors.background)
    g.setBackground(color)
    g.set(x + preCols, screenY, sel)
  end
  if suf ~= "" then
    g.setForeground(color)
    g.setBackground(tui.colors.background)
    g.set(x + preCols + selCols, screenY, suf)
  else
    -- 选中段延伸到行尾（suf 空）: 必须复位 fg/bg——否则残留 fg=黑、
    -- bg=行色泄漏到下一行 + 下一轮 redrawContent 的 fill（v0.3.110
    -- fill 前已补 setForeground 防御，这里是根因修复: 每行渲染后
    -- gpu 状态干净）
    g.setForeground(tui.colors.foreground)
    g.setBackground(tui.colors.background)
  end
  return true
end

-- 重绘指定行区间（tmux window_copy_redraw_selection 模式）:
-- 拖动只重绘 [y0, y1] 受影响行——每行派生渲染（含选中判断），
-- 无残留（重绘即恢复原色）。
-- v0.3.109: 走 markDirty+flushDirty——行缓存二次跳过未变行。
local function redrawRowRange(y0, y1)
  local _, y, _, h = getContentBounds()
  y0 = math.max(y, y0)
  y1 = math.min(y + h - 1, y1)
  if y0 > y1 then return end
  markDirty(y0, y1)
  flushDirty()
end

-- 读回选中文本（v0.3.106 流式 + 中文支持）:
-- 按文本流拼接（起点行起点列起 → 中间行整行 → 终点行到终点列），
-- 行间 \n 连接。宽字符读回: 跳 padding 格（前一格宽字符的后续格）；
-- 选中列起点落在宽字符第二格时前移一格包含完整字符。
-- 返回字符串或 nil（无选中/全空）
local function readContentSelection()
  if not state.csel then return nil end
  local g = component.gpu
  local x, y, w, h = getContentBounds()
  local a, b = normalizeCsel()
  local xmax = x + w - 1
  local function readSegment(row, from, to)
    from = math.max(x, from)
    to = math.min(xmax, to)
    if from > to then return "" end
    -- 宽字符边界校正: from 若是前一格宽字符的 padding → 前移包含整字符
    if from > x then
      local ok_prev, prev = pcall(g.get, from - 1, row)
      if ok_prev and isWideChar(prev) then from = from - 1 end
    end
    local parts = {}
    local col = from
    local prevWide = false
    while col <= to do
      if prevWide then
        -- padding 格: 跳过（前一格是宽字符）
        prevWide = false
        col = col + 1
      else
        local ok_g, text = pcall(g.get, col, row)
        local ch = ok_g and type(text) == "string" and text or ""
        if isWideChar(ch) then
          parts[#parts + 1] = ch
          prevWide = true
          col = col + 1
        else
          parts[#parts + 1] = (ch == "" and " " or ch)
          col = col + 1
        end
      end
    end
    return table.concat(parts):gsub("[ \t]+$", "")
  end
  local lines = {}
  if a.y == b.y then
    lines[1] = readSegment(a.y, a.x, b.x)
  else
    lines[1] = readSegment(a.y, a.x, xmax)
    for row = a.y + 1, b.y - 1 do
      lines[#lines + 1] = readSegment(row, x, xmax)
    end
    lines[#lines + 1] = readSegment(b.y, x, b.x)
  end
  -- 全空（每行都空）→ nil
  local all_empty = true
  for _, l in ipairs(lines) do
    if l ~= "" then all_empty = false break end
  end
  if all_empty then return nil end
  return table.concat(lines, "\n")
end

-- ════════════════════════════════════════
-- 双击选词 / 三击选行（v0.3.115 功能2, 经典终端语义）:
--   词 = 连续非空白/非标点段（半角标点 + 常用中文标点都是边界）;
--   宽字符整字符归属（padding 格不切开）; 列↔字符换算按列语义。
-- ════════════════════════════════════════

-- 词边界判定: 空白 / ASCII 标点 / 常用中文标点
local function isWordBoundary(ch)
  if not ch or ch == "" then return true end
  if ch:match("%s") then return true end
  if ch:match("[%p]") then return true end
  if ch:match("[，。；：！？、（）【】《》“”‘’…—·]") then return true end
  return false
end

-- 读取一行的字符 + 列位置映射（宽字符首格存完整字符, padding 格跳过;
-- 空屏幕格 → 空格）。返回 (chars, cols): cols[i] = chars[i] 的首列。
local function rowCharMap(row)
  local g = component.gpu
  local x, _, w = getContentBounds()
  local xmax = x + w - 1
  local chars, cols = {}, {}
  local col = x
  local prevWide = false
  while col <= xmax do
    if prevWide then
      prevWide = false
      col = col + 1
    else
      local ok_g, text = pcall(g.get, col, row)
      local ch = ok_g and type(text) == "string" and text or ""
      if isWideChar(ch) then
        chars[#chars + 1] = ch
        cols[#cols + 1] = col
        prevWide = true
        col = col + 1
      else
        chars[#chars + 1] = (ch == "" and " " or ch)
        cols[#cols + 1] = col
        col = col + 1
      end
    end
  end
  return chars, cols
end

-- 点击列 → 该行词的列区间 [start, end]（屏幕列, 1 基）; 点击在非词字符
-- （空白/标点）或空区 → 返回 nil（调用方退回单格选中）。
local function wordSpanAt(clickX, row)
  local chars, cols = rowCharMap(row)
  if #chars == 0 then return nil end
  -- 找点击列命中的字符（宽字符覆盖 [col, col+1]）
  local idx = nil
  for i = 1, #chars do
    local cw = isWideChar(chars[i]) and 2 or 1
    if clickX >= cols[i] and clickX < cols[i] + cw then
      idx = i
      break
    end
  end
  if not idx or isWordBoundary(chars[idx]) then return nil end
  local lo, hi = idx, idx
  while lo > 1 and not isWordBoundary(chars[lo - 1]) do lo = lo - 1 end
  while hi < #chars and not isWordBoundary(chars[hi + 1]) do hi = hi + 1 end
  local startCol = cols[lo]
  local endCol = cols[hi] + (isWideChar(chars[hi]) and 2 or 1) - 1
  return startCol, endCol
end

-- 复制内容区选中: 读回文本 → state.clipboard + onCopy 回调（写
-- WRITABLE_BASE/selected.txt 供 /paste 命令与 /debug gist 附带）→
-- 清除选中。返回复制字符数或 nil。
-- v0.3.106 改: 不再把 state.clipboard 当"优先粘贴源"——那抢占游戏
-- 剪贴板（用户: "占用了正常的从游戏外粘贴到游戏内操作"）。复制选中
-- 走 /paste 命令（读 selected.txt）粘贴，Ctrl+V 恢复游戏剪贴板粘贴。
function tui.copyContentSelection()
  local text = readContentSelection()
  if not text then
    state.csel = nil
    state.csel_active = nil
    return nil
  end
  local n = ulen(text)
  if tui.onCopy then
    local ok, err = pcall(tui.onCopy, text)
    if not ok then
      tui.setStatus("Copied " .. n .. " chars (file write failed: " .. tostring(err) .. ")")
    else
      tui.setStatus("Copied " .. n .. " chars → selected.txt (/paste 粘贴; /debug 附带)")
    end
  else
    tui.setStatus("Copied " .. n .. " chars (/paste 粘贴)")
  end
  state.csel = nil
  state.csel_active = nil
  -- v0.3.108: 清除选中后必须 redrawContent——派生模式下高亮是
  -- 每帧从 csel 计算的，csel=nil 后重绘即恢复原色（无残留）。
  -- 只 drawInput 会留下最后选中的反色行。
  pcall(tui.redrawContent)
  return n
end

-- 设置输入缓冲区（v0.3.106）: /paste 命令把选中内容注入输入行
-- （readInput 主循环的输入行）。仅事件驱动分支有效; io.read 回退
-- 分支忽略（REPL 场景用 /paste 写文件 + 手动粘贴）。
function tui.setInputBuffer(text)
  if type(text) ~= "string" then return end
  -- 注入到当前输入行（覆盖多行选中为单行——内容区选中可能含 \n,
  -- 输入行不支持多行编辑; 换行转空格保持可编辑）
  local single = tostring(text):gsub("[\r\n]+", " ")
  setInputBufferText(single)
  state.inputCursor = charCount(single)  -- v0.3.111: 字符索引（旧 ulen=列数，中文错位）
  state.completionCycle = nil
  state.sel = nil
  state.sel_active = nil
  state.inputFollow = true
  -- v0.3.112: 注入内容可能改变输入框高度 → 布局全量重绘
  syncInputHeight()
  pcall(tui.redrawContent)
end

-- 清除内容区选中（无复制）
function tui.clearContentSelection()
  if state.csel then
    state.csel = nil
    state.csel_active = nil
    pcall(tui.redrawContent)
  end
end

-- 滚动视图（v0.3.112 防闪烁）: 新 offset 与旧值相同（到顶/底边界）→
-- no-op 直接 return（边界快速滚动不再高频全屏重绘）; 不同 → 只重绘
-- 内容区行 + 状态栏（[Scroll n] 指示联动）。**不用 redrawContent**——
-- 旧实现 fill 全屏擦除再重画 = 滚动闪烁的根因; 滚动重绘 = 每行一次
-- set 覆盖，无 fill 闪黑。行缓存无需手动清: scrollOffset 变化 → 每行
-- history idx 变 → drawRow 文本比较自然 miss 重画; 内容未变的行命中
-- 缓存跳过是正确行为（省写屏）。
local function scrollView(newOffset)
  newOffset = math.max(0, newOffset or 0)
  if newOffset == state.scrollOffset then return end
  local delta = newOffset - state.scrollOffset  -- +1 = 视口向更早历史滚 = 内容下移 1 行
  state.scrollOffset = newOffset
  local x, y, w, h = getContentBounds()
  -- v0.3.115 Bug3（问题2 选中不跟随滚轮）: csel 是屏幕坐标 {ax,ay,bx,by},
  -- 滚动改 scrollOffset 后内容平移但 csel 不动 → 选中高亮固定在原屏幕
  -- 位置（内容跑了高亮没跑）。修复: 滚动时 csel 按 delta 平移跟随内容
  -- （delta>0 内容下移 → 选中下移 delta 行），clamp 到内容区（选中内容
  -- 滚出视口 → 视觉选中压到顶/底边界）。copyContentSelection 读回的是
  -- 当前 csel 对应视口内容（滚出部分 = 视口内剩余部分）。
  if state.csel and state.csel_active then
    state.csel.ay = math.max(y, math.min(y + h - 1, state.csel.ay + delta))
    state.csel.by = math.max(y, math.min(y + h - 1, state.csel.by + delta))
  end
  redrawRowRange(y, y + h - 1)
  pcall(tui.drawStatus)
end

function tui.scrollUp(lines)
  lines = lines or 1
  local _, _, _, h = getContentBounds()
  local maxScroll = math.max(0, #state.history - h)
  scrollView(math.min(maxScroll, state.scrollOffset + lines))
end

function tui.scrollDown(lines)
  lines = lines or 1
  scrollView(state.scrollOffset - lines)
end

function tui.scrollToBottom()
  scrollView(0)
end

function tui.scrollToTop()
  local _, _, _, h = getContentBounds()
  scrollView(math.max(0, #state.history - h))
end

-- 浏览位置吸附（v0.3.111）: 落到宽字符 padding 格时向左回走到字符起点
-- （tmux grid.c:1717 grid_in_set 从 padding 格回走模式）——padding 格是
-- 宽字符的显示延续，不是独立光标位。h/l 移动后调用（含 h 落到前一
-- 宽字符的 padding 格、l 落到本宽字符 padding 格两种情况）。
local function snapBrowseFromPadding(pos)
  if pos.x <= 1 then return end
  local g = component.gpu
  local ok_prev, prev = pcall(g.get, pos.x - 1, pos.y)
  local ok_cur, cur = pcall(g.get, pos.x, pos.y)
  -- 前一格是宽字符（首格）且当前格是空格 → 当前格是它的 padding → 回走
  if ok_prev and isWideChar(prev) and ok_cur and (cur == " " or cur == "") then
    pos.x = pos.x - 1
  end
end

-- 进入键盘浏览/选择模式（v0.3.109 P1-1, tmux copy-mode 移植）:
-- /browse 命令进入。hjkl 移动虚拟光标（复用派生选中渲染——
-- Space 设置 csel anchor 为当前浏览位置，移动扩展选中，
-- y 复制选中文本并退出，q/Escape/Enter 退出）。鼠标真机不精确
-- （MC 客户端事件稀疏），键盘是可靠替代且选中渲染零改动。
function tui.enterBrowse()
  local x, y, w, h = getContentBounds()
  if #state.history == 0 then
    tui.setStatus("Nothing to browse (history empty)")
    return
  end
  state.browseMode = true
  -- 初始位置: 视口中部（用户当前看到的位置）
  state.browsePos = {x = x + math.floor(w / 2), y = y + math.floor(h / 2)}
  pcall(tui.redrawContent)
  tui.setStatus("Browse: hjkl move  Space select  y copy  q quit")
end

-- 搜索定位（v0.3.109 P1-3, tmux window_copy_search 移植）:
-- history 是内存纯文本数组——string.find 线性扫零组件调用（对比 tmux
-- 要渲染临时 screen 再匹配 grid，我们数据结构天然适合）。找到匹配行后
-- 设置 scrollOffset 使其可见（居视口中部）+ 记录匹配段供 drawRow 高亮。
-- 返回匹配行数（0 = 未找到）。
local function findMatch(pattern, startIdx, dir)
  local n = #state.history
  if n == 0 or pattern == "" then return nil end
  local i = startIdx
  while true do
    if i < 1 or i > n then return nil end
    local text = state.history[i].text or ""
    local bf, bt = text:find(pattern, 1, true)
    if bf then
      -- v0.3.111: string.find 返回【字节】偏移 → 转【字符】索引（gmatch
      -- 数字符）——中文匹配段字节≠字符≠列，直存字节偏移当列用会错位
      local f = charCount(text:sub(1, bf - 1)) + 1
      local t = charCount(text:sub(1, bt))
      return i, f, t
    end
    i = i + dir
  end
end

function tui.search(pattern)
  if not pattern or pattern == "" then
    tui.setStatus("Usage: /search <text>")
    return 0
  end
  local idx, f, t = findMatch(pattern, 1, 1)  -- 顶部 → 底部
  if not idx then
    state.search = nil
    tui.setStatus("No match: " .. pattern)
    return 0
  end
  state.search = {pattern = pattern, idx = idx, from = f, to = t}
  -- 跳到匹配行: 使其位于视口中部（除非行数不足）
  local _, y, _, h = getContentBounds()
  local maxScroll = math.max(0, #state.history - h)
  local target = #state.history - idx
  state.scrollOffset = math.max(0, math.min(maxScroll, target - math.floor(h / 2)))
  state.lineCache = {}
  pcall(tui.redrawContent)
  tui.setStatus("Match " .. idx .. "/" .. #state.history .. ": " .. pattern)
  return 1
end

-- 重复搜索（n 下一个 / N 上一个）: 从当前匹配行向 dir 方向找
function tui.searchNext(dir)
  dir = dir or 1
  if not state.search then
    tui.setStatus("No active search (/search <text> first)")
    return 0
  end
  local pattern = state.search.pattern
  local idx, f, t = findMatch(pattern, state.search.idx + dir, dir)
  if not idx then
    tui.setStatus("No more match: " .. pattern)
    return 0
  end
  state.search = {pattern = pattern, idx = idx, from = f, to = t}
  local _, y, _, h = getContentBounds()
  local maxScroll = math.max(0, #state.history - h)
  local target = #state.history - idx
  state.scrollOffset = math.max(0, math.min(maxScroll, target - math.floor(h / 2)))
  state.lineCache = {}
  pcall(tui.redrawContent)
  tui.setStatus("Match " .. idx .. "/" .. #state.history .. ": " .. pattern)
  return 1
end

-- 翻页步长（半屏）——/up /down 命令与 PgUp/PgDn 失效时的兜底
-- scrollSafe 时内容区矮 1 行 → 步长同步 -1，与内容区一致
function tui.pageStep()
  -- v0.3.112: 内容区高度动态（输入框自动增高）——PgUp/PgDn 步长跟随
  local _, _, _, h = getContentBounds()
  return math.max(1, h - 1)
end

-- 多行 buffer 支持（v0.3.112 起编辑边界改用 lineBoundsAt——光标所在行;
-- 本函数"最后一行起点"语义已由输入框多行窗口化 + 跨行编辑取代）。
-- 绘制输入行（底部: 提示符 + 最后一行文本 + 反色块光标 + Tab 候选提示;
-- scrollSafe 时上移一行, 最底行 h 永不写入——杜绝终端滚动型模拟器触发整屏上滚）
-- v0.3.72 拖选高亮: state.sel = {a=字符索引, b=字符索引}（输入缓冲内），
-- a==b 时无选中。选中段用反色背景绘制（先画文本→再画选中段覆盖）。
-- GTNH 组件无 setClipboard API——复制目标为 state.clipboard（进程内
-- 剪贴板，Ctrl+V 粘贴优先使用），跨游戏剪贴板不可行。
-- 绘制输入框（v0.3.112 重写: 多行窗口化自动增高）:
-- 底部 inputHeight 行（≤ MAX_INPUT_HEIGHT）显示 inputScroll 起的窗口;
-- 首可见行前缀 ">> "（多行）/"> "（单行），其余行 "   " 缩进（同宽）;
-- 光标所在行渲染反色块光标; 状态栏在输入框上方（drawStatus 已联动）。
-- 窗口跟随光标（state.inputFollow）: 光标行移出窗口时自动滚动; 手动
-- 滚轮浏览输入历史时关闭跟随。
-- state.sel（0 基 [a,b) 字符区间）跨行渲染: 每窗口行切片反色。
-- v0.3.72 拖选高亮 + v0.3.111 宽字符列换算保留。
function tui.drawInput()
  local g = component.gpu
  if not g then return end  -- 无 gpu（测试/降级环境）静默
  syncInputHeight()
  local ih = math.max(1, state.inputHeight or 1)
  local inputY = state.height - (state.scrollSafe and 1 or 0)   -- 最底行
  local y0 = inputY - ih + 1                                    -- 输入框顶行
  local lines, ranges, multiline = inputDisplayLines()
  -- 光标所在显示行（1 基; 行尾归本行, 兜底最后一行）
  local curLine = #lines
  for i = 1, #lines do
    local r = ranges[i]
    if state.inputCursor >= r[1] and state.inputCursor < r[1] + r[2] then
      curLine = i break
    end
  end
  for i = 1, #lines do
    if state.inputCursor == ranges[i][1] + ranges[i][2] then curLine = i break end
  end
  -- 窗口滚动: clamp + 光标跟随（非手动浏览时）
  local maxScroll = math.max(0, #lines - ih)
  if state.inputScroll > maxScroll then state.inputScroll = maxScroll end
  if state.inputScroll < 0 then state.inputScroll = 0 end
  if state.inputFollow ~= false then
    if curLine < state.inputScroll + 1 then state.inputScroll = curLine - 1 end
    if curLine > state.inputScroll + ih then state.inputScroll = curLine - ih end
  end
  -- 清输入框区域（整框擦除——多行残留防抖）
  g.setBackground(tui.colors.background)
  g.fill(1, y0, state.width, ih, " ")
  -- 1) 每窗口行: 前缀 + 文本
  for k = 1, ih do
    local lineIdx = state.inputScroll + k
    local sy = y0 + k - 1
    local text = lines[lineIdx] or ""
    local prefix, textStart
    if k == 1 and state.inputScroll == 0 then
      prefix, textStart = (multiline and ">> " or "> "), (multiline and 5 or 4)
    else
      prefix, textStart = "   ", 5
    end
    g.setForeground(tui.colors.prompt)
    g.set(2, sy, prefix)
    g.setForeground(tui.colors.foreground)
    if text ~= "" then g.set(textStart, sy, text) end
  end
  -- 2) 选中段渲染（state.sel 0 基 [sa, sb) 字符区间 → 每窗口行切片）
  local sel = state.sel
  if sel and sel.a ~= sel.b then
    local sa, sb = math.min(sel.a, sel.b), math.max(sel.a, sel.b)
    for k = 1, ih do
      local lineIdx = state.inputScroll + k
      local r = ranges[lineIdx]
      if r then
        local lo = math.max(sa, r[1]) - r[1]        -- 0 基行内起点
        local hi = math.min(sb, r[1] + r[2]) - r[1]  -- 0 基排他终点
        if lo < hi then
          local text = lines[lineIdx] or ""
          local sy = y0 + k - 1
          local textStart = (k == 1 and state.inputScroll == 0 and not multiline) and 4 or 5
          local x0 = textStart + ulen(usub(text, 1, lo))
          local x1 = textStart + ulen(usub(text, 1, hi))
          if x1 > state.width - 1 then x1 = state.width - 1 end
          local w = x1 - x0
          if w > 0 then
            g.setBackground(tui.colors.foreground)
            g.setForeground(tui.colors.background)
            g.set(x0, sy, usub(text, lo + 1, hi))
            -- v0.3.115 Bug1: 删除"选中终点到行尾的 fill"——旧代码在此处
            -- 处于 setBackground(白) 状态, fill 把选中段之后整行染成白块
            -- （shift 选中中间段后整行变白的根因）。整框已在 1270 擦除,
            -- 选中段之后保持步骤 1 的原色即可。
            g.setBackground(tui.colors.background)
            g.setForeground(tui.colors.foreground)
          end
        end
      end
    end
  end
  -- 3) 反色块光标（光标所在行; 最后画——覆盖选中）
  local rcur = ranges[curLine] or {0, 0}
  local off = state.inputCursor - rcur[1]
  local textC = lines[curLine] or ""
  local kc = curLine - state.inputScroll
  local syc = y0 + kc - 1
  local textStartC = (kc == 1 and state.inputScroll == 0 and not multiline) and 4 or 5
  local cursorX = textStartC + ulen(usub(textC, 1, off))
  if cursorX <= state.width - 1 then
    local ch = usub(textC, off + 1, off + 1)
    if ch == "" then ch = " " end
    g.setBackground(tui.colors.foreground)
    g.setForeground(tui.colors.background)
    g.set(cursorX, syc, ch)
    g.setBackground(tui.colors.background)
    g.setForeground(tui.colors.foreground)
  end
  pcall(term.setCursor, cursorX, syc)
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
function tui.readInput(on_event)
  -- on_event（v0.3.84）: 可选回调，事件循环收到非键盘事件（如
  -- modem_message——explorer 子代理的文件服务请求）时转发，避免事件被
  -- readInput 消费丢弃。回调签名 on_event(ev, args_table)。返回 true
  -- 表示事件已消费（不打断输入循环）。
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

  setInputBufferText("")
  state.inputCursor = 0
  state.completionCycle = nil
  local cursorVisible = true
  local lastBlink = now_seconds()

  pcall(tui.drawInput)
  while true do
    local sig = {event.pull(0.25)}
    local ev, _, char, code = sig[1], sig[2], sig[3], sig[4]

    -- 非键盘事件转发（v0.3.84）: modem_message 等交给 on_event 回调
    -- （主代理文件服务用——explorer 子代理读主代理硬盘）。不打断
    -- 输入循环，事件不丢失。回调签名 on_event(sig_table)（sig[1]=ev,
    -- sig[3]=sender, sig[4]=port, sig[6]=payload...），返回 true 表示
    -- 已消费。
    if on_event and ev ~= "key_down" and ev ~= "interrupted"
        and ev ~= "key_up" and ev ~= "clipboard" then
      local handled = on_event(sig)
      if handled then
        pcall(tui.drawInput)
        -- fallthrough: 继续输入循环（事件已消费）
      end
    end

    -- 光标闪烁
    local now = now_seconds()
    if now - lastBlink >= 0.5 then
      cursorVisible = not cursorVisible
      lastBlink = now
      -- 简化: 闪烁只做定时重绘提示（块光标常亮，不闪烁——机器人帧率友好）
    end

    if ev == "interrupted" then
      -- Ctrl+C 双语义（v0.3.72）: 游戏端 Ctrl+C 发 interrupted 事件。
      -- 输入行有选中文本 → 复制到进程内剪贴板 + 清除选中 + 继续输入
      -- （不中断——用户意图是复制，不是中断）；
      -- 无选中 → 原有中断行为（return nil 退出输入循环）。
      -- v0.3.100: 内容区有选中（state.csel）→ 同样复制（优先于输入行）。
      if state.csel and state.csel_active then
        tui.copyContentSelection()
      elseif state.sel and state.sel.a ~= state.sel.b then
        local sa, sb = math.min(state.sel.a, state.sel.b),
          math.max(state.sel.a, state.sel.b)
        state.clipboard = usub(state.inputBuffer, sa + 1, sb)
        tui.setStatus("Copied " .. ulen(state.clipboard) .. " chars (Ctrl+V to paste)")
        state.sel = nil
        state.sel_active = nil
        pcall(tui.drawInput)
      else
        return nil
      end
    elseif ev == "key_down" then
      local ch = char or 0

      -- 键盘浏览/选择模式（v0.3.109, tmux copy-mode 移植）:
      -- /browse 进入。hjkl 移动虚拟光标（复用派生选中渲染——
      -- Space 设置 csel anchor 为当前浏览位置，移动扩展选中，
      -- y 复制选中文本，q/Escape 退出浏览）。
      -- 浏览模式下所有按键只做浏览/选择操作，不碰输入行。
      if state.browseMode then
        local _, _, _, bh = getContentBounds()
        if ch == 104 then -- h: 左移（落到 padding 格回走——v0.3.111）
          state.browsePos.x = math.max(1, state.browsePos.x - 1)
          snapBrowseFromPadding(state.browsePos)
        elseif ch == 108 then -- l: 右移（同）
          state.browsePos.x = math.min(state.width - 2, state.browsePos.x + 1)
          snapBrowseFromPadding(state.browsePos)
        elseif ch == 106 then -- j: 下移
          local maxScroll = math.max(0, #state.history - bh)
          local _, cyb, _, chb = getContentBounds()  -- v0.3.112: 内容区动态高度
          if state.browsePos.y >= cyb + chb - 1 then
            -- 到底: 滚动内容（视口下移），浏览位置保持
            if state.scrollOffset > 0 then
              scrollView(state.scrollOffset - 1)  -- v0.3.112: 无 fill 防闪烁
            end
          else
            state.browsePos.y = state.browsePos.y + 1
          end
        elseif ch == 107 then -- k: 上移
          if state.browsePos.y <= 2 then
            -- 到顶: 滚动内容（视口上移）
            local maxScroll = math.max(0, #state.history - bh)
            if state.scrollOffset < maxScroll then
              scrollView(state.scrollOffset + 1)  -- v0.3.112: 无 fill 防闪烁
            end
          else
            state.browsePos.y = state.browsePos.y - 1
          end
        elseif ch == 32 then -- Space: 开始/结束选中
          if not state.csel then
            -- 开始选中（anchor = 当前浏览位置）
            state.csel = {ax = state.browsePos.x, ay = state.browsePos.y,
              bx = state.browsePos.x, by = state.browsePos.y}
            state.csel_active = true
            pcall(tui.redrawContent)
          else
            -- 已有选中: 结束（保持选中，光标移动不取消）
          end
        elseif ch == 121 then -- y: 复制选中
          if state.csel then
            tui.copyContentSelection()
            -- 复制后退出浏览（tmux copy-pipe-and-cancel）
            state.browseMode = false
            state.browsePos = nil
            state.csel = nil
            state.csel_active = nil
            pcall(tui.redrawContent)
            return nil
          end
        elseif ch == 113 or ch == 27 then -- q / Escape: 退出浏览
          state.browseMode = false
          state.browsePos = nil
          state.csel = nil
          state.csel_active = nil
          pcall(tui.redrawContent)
          pcall(tui.setStatus, "Ready")
          -- 继续输入循环（返回 nil 会退出 readInput 主循环——用 continue 语义）
        elseif ch == 13 then -- Enter: 退出浏览（回到输入）
          state.browseMode = false
          state.browsePos = nil
          state.csel = nil
          state.csel_active = nil
          pcall(tui.redrawContent)
        end
        -- 选中激活时移动 → 扩展选中终点
        if state.csel and state.csel_active and ch ~= 32 then
          state.csel.bx = state.browsePos.x
          state.csel.by = state.browsePos.y
        end
        -- 浏览模式重绘（h/l/j/k 移动后派生选中或光标移动）
        pcall(tui.redrawContent)
        goto continue_browse
      end

      -- v0.3.112: 编辑边界 = 光标所在行（多行编辑——Up/Down 跨行移动,
      -- Left/Right/Backspace/Delete/Home/End 以当前行为界, 不跨行不删
      -- \n; 历史翻页仅限单行 buffer）
      local multiline = state.inputBuffer:find("\n", 1, true) ~= nil
      local line_start, line_end = lineBoundsAt(state.inputBuffer, state.inputCursor)
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
      elseif ch == 8 or code == 14 then -- Backspace（v0.3.114: 有选中删整段; 否则限当前行，不删 \n）
        if not deleteSelection() then
          if state.inputCursor > line_start then
            setInputBufferText(usub(state.inputBuffer, 1, state.inputCursor - 1)
              .. usub(state.inputBuffer, state.inputCursor + 1))
            state.inputCursor = state.inputCursor - 1
            state.completionCycle = nil
          end
        end
      elseif code == 203 then -- Left（不跨行; v0.3.114 shift 扩展选中）
        local oldCursor = state.inputCursor
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
        applyShiftSelect(oldCursor)
        state.completionCycle = nil
      elseif code == 205 then -- Right（限当前行; v0.3.114 shift 扩展选中）
        local oldCursor = state.inputCursor
        if keyboard.isControlDown and keyboard.isControlDown() then
          -- Ctrl+Right: 下一个单词边界（当前行内）
          local len = line_end
          local pos = state.inputCursor
          while pos < len and not usub(state.inputBuffer, pos + 1, pos + 1):match("%s") do
            pos = pos + 1
          end
          while pos < len and usub(state.inputBuffer, pos + 1, pos + 1):match("%s") do
            pos = pos + 1
          end
          state.inputCursor = pos
        elseif state.inputCursor < line_end then
          state.inputCursor = state.inputCursor + 1
        end
        applyShiftSelect(oldCursor)
        state.completionCycle = nil
      elseif code == 199 then -- Home（行首; Ctrl=滚到顶; v0.3.114 shift 扩展）
        if keyboard.isControlDown and keyboard.isControlDown() then
          tui.scrollToTop()
        else
          local oldCursor = state.inputCursor
          state.inputCursor = line_start
          applyShiftSelect(oldCursor)
        end
      elseif code == 207 then -- End（当前行尾; Ctrl=滚到底; v0.3.114 shift 扩展）
        if keyboard.isControlDown and keyboard.isControlDown() then
          tui.scrollToBottom()
        else
          local oldCursor = state.inputCursor
          state.inputCursor = line_end  -- v0.3.112: 光标所在行尾（原 buffer 尾）
          applyShiftSelect(oldCursor)
        end
      elseif code == 211 then -- Delete（v0.3.114: 有选中删整段; 否则当前行内）
        if not deleteSelection() then
          local len = line_end
          if state.inputCursor < len then
            setInputBufferText(usub(state.inputBuffer, 1, state.inputCursor)
              .. usub(state.inputBuffer, state.inputCursor + 2))
          end
        end
        state.completionCycle = nil
      elseif code == 200 then -- Up: Ctrl=上滚 1 行; bash 标准——多行时光标在顶行（首行）↑ = 历史上翻，否则跨行上移; 单行恒历史上翻（v0.3.115）
        if keyboard.isControlDown and keyboard.isControlDown() then
          tui.scrollUp(1)
        elseif multiline and line_start > 0 then
          -- v0.3.112 多行编辑: 列保持上移一个显示行（clamp 到目标行宽）
          local oldCursor = state.inputCursor
          moveCursorByDisplayLine(-1)
          applyShiftSelect(oldCursor)  -- v0.3.114
        else
          historyUp()
        end
      elseif code == 208 then -- Down: Ctrl=下滚 1 行; bash 标准——多行时光标在底行（末行）↓ = 历史下翻，否则跨行下移; 单行恒历史下翻（v0.3.115）
        if keyboard.isControlDown and keyboard.isControlDown() then
          tui.scrollDown(1)
        elseif multiline and line_end < charCount(state.inputBuffer) then
          -- v0.3.112 多行编辑: 列保持下移一个显示行
          local oldCursor = state.inputCursor
          moveCursorByDisplayLine(1)
          applyShiftSelect(oldCursor)  -- v0.3.114
        else
          historyDown()
        end
      elseif code == 201 then -- PgUp: 上滚
        tui.scrollUp(tui.pageStep())
      elseif code == 209 then -- PgDn: 下滚
        tui.scrollDown(tui.pageStep())
      elseif ch == 1 then -- Ctrl+A: 全选输入缓冲（v0.3.115 功能1; ch==1=SOH,
        -- 无既有绑定——原落入 else 诊断分支）。0 基 [0, charCount) 字符区间,
        -- 与 shift 选中/Backspace 删整段/输入替换共用 state.sel 语义。
        state.sel = {a = 0, b = charCount(state.inputBuffer)}
        state.sel_active = true
        state.completionCycle = nil
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
          setInputBufferText(state.completionCycle[2].cmd)
          state.inputCursor = charCount(state.inputBuffer)  -- v0.3.111: 字符索引
          tui.setStatus("Tab: " .. state.completionCycle[2].cmd
            .. (#cands > 1 and (" (" .. #cands .. " candidates)") or ""))
        else
          tui.setStatus("Tab: no match")
        end
      elseif ch >= 32 and ch < 127 then -- 可打印 ASCII
        -- Ctrl+C 复制选中（v0.3.72）: Ctrl+C 时 ch==3（ETX）。
        -- 有选中 → 复制到进程内剪贴板 + 清除选中；无选中 → 落到
        -- 下方原 Ctrl+C 中断处理（读事件循环 break）。
        if ch == 3 and state.sel and state.sel.a ~= state.sel.b then
          local sa, sb = math.min(state.sel.a, state.sel.b),
            math.max(state.sel.a, state.sel.b)
          state.clipboard = usub(state.inputBuffer, sa + 1, sb)
          tui.setStatus("Copied " .. ulen(state.clipboard) .. " chars (Ctrl+V to paste)")
          state.sel = nil
          state.sel_active = nil
          pcall(tui.drawInput)
        else
          if state.sel and state.sel_active and state.sel.a ~= state.sel.b then
            -- v0.3.114: 可打印字符替换选中（等效删选中 + 插入）
            local lo, hi = math.min(state.sel.a, state.sel.b),
              math.max(state.sel.a, state.sel.b)
            setInputBufferText(usub(state.inputBuffer, 1, lo)
              .. string.char(ch)
              .. usub(state.inputBuffer, hi + 1))
            state.inputCursor = lo + 1
            state.sel = nil
            state.sel_active = nil
            state.completionCycle = nil
          else
            -- 有输入时清除选中（高亮区间基于旧文本，输入后错位）
            state.sel = nil
            state.sel_active = nil
            setInputBufferText(usub(state.inputBuffer, 1, state.inputCursor)
              .. string.char(ch)
              .. usub(state.inputBuffer, state.inputCursor + 1))
            state.inputCursor = state.inputCursor + 1
            state.completionCycle = nil
          end
        end
      else
        -- 诊断（v0.3.29 临时）: 未匹配任何分支的 key_down——用于定位荒野大师
        -- 真机 Tab 无反应：若 Tab 事件到达但 char/code 值不同，会落入此分支
        -- 并显示实际值；若状态栏仍无变化则事件根本未到达 agent。
        tui.setStatus("kd?" .. tostring(char) .. "/" .. tostring(code))
      end
      -- v0.3.112: 输入高度随内容变化（粘贴/编辑增删行）→ 内容区高度变
      -- → 全量重绘; 高度不变 → 只重绘输入框（防闪烁）; 任何键活动
      -- = 焦点回到光标 → 输入窗口恢复跟随
      state.inputFollow = true
      if syncInputHeight() then
        pcall(tui.redrawContent)
      else
        pcall(tui.drawInput)
      end
    elseif ev == "clipboard" then
      if char then
        -- v0.3.106 改: Ctrl+V 恢复游戏剪贴板粘贴（用户: 选中复制
        -- "占用了正常的从游戏外粘贴到游戏内操作"）。原实现优先
        -- state.clipboard（选中复制）——抢占游戏剪贴板。现在选中复制
        -- 走 /paste 命令（读 selected.txt），Ctrl+V 永远是游戏剪贴板。
        local paste = char
        if state.sel and state.sel_active and state.sel.a ~= state.sel.b then
          -- v0.3.114: 粘贴替换选中（与可打印字符语义一致）
          local lo, hi = math.min(state.sel.a, state.sel.b),
            math.max(state.sel.a, state.sel.b)
          setInputBufferText(usub(state.inputBuffer, 1, lo) .. paste .. usub(state.inputBuffer, hi + 1))
          state.inputCursor = lo + charCount(paste)
          state.sel = nil
          state.sel_active = nil
        else
          setInputBufferText(usub(state.inputBuffer, 1, state.inputCursor)
            .. paste
            .. usub(state.inputBuffer, state.inputCursor + 1))
          state.inputCursor = state.inputCursor + charCount(paste)  -- v0.3.111: 字符索引
        end
        state.completionCycle = nil
        state.sel = nil
        state.sel_active = nil
        -- v0.3.112: 粘贴多行可能增高输入框 → 内容区高度变 → 全量重绘
        state.inputFollow = true
        if syncInputHeight() then
          pcall(tui.redrawContent)
        else
          pcall(tui.drawInput)
        end
      end
    elseif ev == "touch" or ev == "drag" then
      -- 指针定位 + 拖选（v0.3.68 点击定位；v0.3.72 拖选高亮+Ctrl+C
      -- 复制）。
      -- 事件布局（源码实证 TextBuffer.scala:887-909 sendMouseEvent +
      -- Machine.scala:633 信号首参数=源组件地址）:
      --   (touch, screenAddr, x, y, button, [player])
      --   → sig[1]=touch, sig[2]=screen地址(字符串), sig[3]=x,
      --     sig[4]=y, sig[5]=button
      -- v0.3.103 曾误改成 sig[2]=x, sig[3]=y——tx 拿到 screen 地址字符串
      -- → 'tx <= state.width-1' 字符串比数字崩溃（真机 tui.lua:896
      -- attempt to compare number with string）。v0.3.68 的 sig[3]/sig[4]
      -- 位置才是对的。加类型防御: 非数字直接忽略（不崩溃）。
      local tx, ty, button = sig[3], sig[4], sig[5]
      if type(tx) == "number" and type(ty) == "number" then
        state.lastTouchY = ty  -- v0.3.112 滚轮路由: 最后点击位置决定滚哪边
        local inputY = state.height - (state.scrollSafe and 1 or 0)   -- 输入框底行
        local ih = math.max(1, state.inputHeight or 1)
        local inputTop = inputY - ih + 1                              -- 输入框顶行
        if ty >= inputTop and ty <= inputY then
          -- 输入框（v0.3.112 多行窗口化）: 点击 y → 窗口内行 k → 显示行
          -- → 该行字符起点 + 列换算（charIndexAtCol——中文落在 padding
          -- 格定位到该字符）→ inputCursor。点击可见行即编辑该行。
          local lines, ranges, multiline = inputDisplayLines()
          local k = ty - inputTop                 -- 窗口内行号 0 基
          local lineIdx = state.inputScroll + k + 1  -- 1 基显示行
          if lineIdx < 1 then lineIdx = 1 end
          if lineIdx > #lines then lineIdx = #lines end
          local r = ranges[lineIdx] or {0, 0}
          local text = lines[lineIdx] or ""
          local textStart = (k == 0 and state.inputScroll == 0 and not multiline) and 4 or 5
          local rel = tx - textStart
          if rel < 0 then rel = 0 end
          local charIdx = r[1] + charIndexAtCol(text, rel)
          if ev == "touch" then
            -- 按下: 起点 = 终点 = 点击位（清除旧选中）
            state.sel = {a = charIdx, b = charIdx}
            state.sel_active = true
          elseif state.sel and state.sel_active then
            -- 拖动: 更新终点（起点保持）——不移动光标
            state.sel.b = charIdx
          end
          state.inputCursor = charIdx
          state.inputFollow = true  -- 点击输入框 → 恢复光标跟随
          state.completionCycle = nil
          pcall(tui.drawInput)
        elseif ev == "drag" and state.sel and state.sel_active then
          -- 拖出输入框: 终点 = 锚点所在行行首/行尾（向拖动方向延伸）
          local as_, ae_ = lineBoundsAt(state.inputBuffer, state.sel.a or 0)
          state.sel.b = ty < inputTop and as_ or ae_
          pcall(tui.drawInput)
        else
          -- 内容区选中（v0.3.105 修复）: 原结构误放在"坐标非数字"的
          -- else 分支——真机坐标是数字 → 内容区选中永不执行（v0.3.100
          -- 引入; v0.3.103 字符串坐标恰好走进来但 896 行崩溃;
          -- v0.3.104 坐标修复回数字后又不执行 = 用户"仍然不成功"根因）。
          -- 正确: 数字坐标分支内、ty~=inputY（内容区）时执行。
          local _, cy, cw, ch = getContentBounds()
        if ev == "touch" then
          if ty >= cy and ty <= cy + ch - 1 and tx >= 2 and tx <= state.width - 1 then
            -- v0.3.115 功能2: 连击检测（双击选词 / 三击选行）——同位置
            -- （|dx|,|dy|<=1，宽容误点）且间隔 <500ms 递增计数; 否则复位 1。
            local t = now_seconds()
            local samePos = state.lastClickX and state.lastClickY
              and math.abs(tx - state.lastClickX) <= 1
              and math.abs(ty - state.lastClickY) <= 1
            local quick = state.lastClickTime and (t - state.lastClickTime) < 0.5
            if samePos and quick then
              state.clickCount = (state.clickCount or 0) + 1
            else
              state.clickCount = 1
            end
            state.lastClickTime = t
            state.lastClickX = tx
            state.lastClickY = ty
            state.sel = nil
            state.sel_active = nil
            if state.clickCount >= 3 then
              -- 三击: 选整行（x..xmax, 同 y）; 复位计数（下次点击重新计）
              state.csel = {ax = 2, ay = ty, bx = 2 + cw - 1, by = ty}
              state.csel_active = true
              state.clickCount = 0
              pcall(tui.redrawContent)
            elseif state.clickCount == 2 then
              -- 双击: 选词（点中词内 → 扩到词起止列; 点空白/标点 → 单格）
              local ws, we = wordSpanAt(tx, ty)
              if ws then
                state.csel = {ax = ws, ay = ty, bx = we, by = ty}
                state.csel_active = true
                pcall(tui.redrawContent)
              else
                state.csel = {ax = tx, ay = ty, bx = tx, by = ty}
                state.csel_active = true
                pcall(tui.redrawContent)
              end
            else
              -- 单击: 起点 = 终点 = 点击位（清除旧选中 + 输入行选中）
              state.csel = {ax = tx, ay = ty, bx = tx, by = ty}
              state.csel_active = true
              pcall(tui.redrawContent)
            end
          end
        elseif ev == "drag" and state.csel and state.csel_active then
          -- 拖动: 更新终点 + 派生重绘（v0.3.108 无状态模式，抄
          -- tmux window_copy_redraw_selection）——只重绘受影响行区间
          -- [min(old_y,new_y), max(old_y,new_y)]，每行从 history
          -- 重新派生选中着色。无 gpu.get、无"恢复反色"逻辑——
          -- 方向反转（向下再向上）时选中区间跨过锚点，重绘行
          -- 重新计算命中与否，天然无残留、不闪烁。
          -- v0.3.109 P1-2 拖选自动滚动（tmux window-copy.c:7123-7131
          -- 模式）: 拖到内容区顶/底边缘外时视口自动滚动（scrollOffset
          -- 平移）——选中矩形跟随内容整体平移（内容下移选中下移），
          -- 终点 clamp 到边缘行。跨屏选中可达（此前选中只能拖到屏内，
          -- 历史超一屏时跨屏选中不可达）。
          local maxScroll = math.max(0, #state.history - ch)
          tx = math.max(2, math.min(state.width - 1, tx))
          if ty < cy and state.scrollOffset < maxScroll then
            -- 顶部之上: 视口向更早历史滚（scrollOffset+1，内容下移1行）
            -- v0.3.115: csel 平移统一由 scrollView 内完成（delta 跟随内容
            -- + clamp）——这里不再手动平移（会与 scrollView 双重平移）;
            -- 终点 clamp 到边缘行保持拖动延续
            ty = cy
            scrollView(state.scrollOffset + 1)
          elseif ty > cy + ch - 1 and state.scrollOffset > 0 then
            -- 底部之下: 视口向更晚历史滚（scrollOffset-1，内容上移1行）
            ty = cy + ch - 1
            scrollView(state.scrollOffset - 1)
          else
            -- 常规拖动（视口内）: 增量重绘受影响行区间
            local old_a, old_b = normalizeCsel()
            state.csel.bx = tx
            state.csel.by = ty
            local new_a, new_b = normalizeCsel()
            -- 受影响行区间 = 新旧选中行的并集
            local y0 = math.min(old_a.y, new_a.y)
            local y1 = math.max(old_b.y, new_b.y)
            redrawRowRange(y0, y1)
            pcall(tui.drawInput)
          end
        end
      end
      end  -- 关闭 if type(tx)（v0.3.105 结构修复）——else 内容区选中
           -- 挂在 if ty == inputY 分支，外层 if type 的 end 独立补回
    elseif ev == "drop" then
      -- 内容区拖选结束（button 抬起）: 复制选中文本
      -- （touch 按下 → drag 拖动 → drop 结束——gpu.get 读回矩形）
      -- 事件布局同 touch/drag: sig[2]=screen地址, sig[3]=x, sig[4]=y
      -- （v0.3.103 误用 sig[2]/sig[3]——tx 拿到地址字符串, 修正回
      -- sig[3]/sig[4]）
      local tx, ty = sig[3], sig[4]
      if type(tx) == "number" and type(ty) == "number" then
        if state.csel and state.csel_active then
          -- 终点更新为释放点（若在内容区内）或保持最后 drag 点
          local _, cy, _, ch = getContentBounds()
          if ty >= cy and ty <= cy + ch - 1 then
            state.csel.bx = tx
            state.csel.by = ty
          end
          tui.copyContentSelection()
        end
      end
    elseif ev == "scroll" then
      -- 鼠标滚轮: 事件布局同 touch——sig[2]=screen地址, sig[3]=x,
      -- sig[4]=y, sig[5]=delta（TextBuffer.scala:862 sendMouseEvent
      -- 传 delta; v0.3.103 误用 sig[4]=delta 实为 y——修正 sig[5]）
      -- v0.3.112 滚轮路由（用户设计: "通过...最后点击的位置分辨 scroll
      -- 的是对话框还是输入框"）: 最后 touch/drag 的 y 在输入框区域 →
      -- 滚输入窗口（inputScroll ∓ delta, 边界 no-op 防闪烁——同 A）;
      -- 否则滚内容区。无 touch 记录 → 默认滚内容区（旧行为）。
      local delta = sig[5]
      local ih = math.max(1, state.inputHeight or 1)
      local inputTop = state.height - ih - (state.scrollSafe and 1 or 0) + 1
      local ly = state.lastTouchY
      if ly and ly >= inputTop then
        local lines = inputDisplayLines()
        local maxScroll = math.max(0, #lines - ih)
        if delta == 1 then
          if state.inputScroll > 0 then
            state.inputScroll = state.inputScroll - 1
            state.inputFollow = false  -- 手动浏览输入历史: 不跟随光标
            pcall(tui.drawInput)
          end
        elseif delta == -1 then
          if state.inputScroll < maxScroll then
            state.inputScroll = state.inputScroll + 1
            state.inputFollow = false
            pcall(tui.drawInput)
          end
        end
      else
        if delta == 1 then
          tui.scrollUp(3)
        elseif delta == -1 then
          tui.scrollDown(3)
        end
      end
    end
    -- 浏览模式 continue（v0.3.109 P1-1）: browse 分支按键处理后
    -- goto 跳到这里——跳过本事件周期剩余处理（正常输入分支等），
    -- 直接进入下一轮事件循环（goto 跳出局部变量作用域，Lua 合法）。
    ::continue_browse::
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
  setInputBufferText(tostring(s or ""))
  state.inputCursor = charCount(state.inputBuffer)  -- v0.3.111: 字符索引
  state.inputFollow = true
  syncInputHeight()  -- v0.3.112: 注入多行 → 高度/窗口立即同步
end

-- v0.3.112 测试只读钩子（输入框多行 + 滚动防闪烁断言用）
function tui.debug_input_height()
  return state.inputHeight or 1
end
function tui.debug_input_scroll()
  return state.inputScroll or 0
end
function tui.debug_input_cursor()
  return state.inputCursor or 0
end
-- v0.3.113: 折行重算计数（输入卡顿回归断言: 光标移动 0 重算, 编辑 1 次）
function tui.debug_input_reflow_count()
  return state.inputReflowCount or 0
end
-- v0.3.114: shift 选中状态只读钩子（选中扩展断言用）
function tui.debug_input_sel()
  local s = state.sel
  if not (s and state.sel_active) then return nil end
  return {a = s.a, b = s.b}
end
-- v0.3.115: 内容区选中只读钩子（滚动跟随/双击选词/三击选行断言用）
function tui.debug_csel()
  local c = state.csel
  if not (c and state.csel_active) then return nil end
  return {ax = c.ax, ay = c.ay, bx = c.bx, by = c.by}
end
function tui.debug_input_buffer()
  return state.inputBuffer or ""
end
function tui.debug_scroll_offset()
  return state.scrollOffset or 0
end

return tui
