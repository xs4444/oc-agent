-- ══════════════════════════════════════════════════════
-- OC Mock — shim OC APIs for host-side testing
-- ══════════════════════════════════════════════════════

-- 原始 os.sleep 引用（中断补丁前保存）: agent.interrupt 的补丁会替换
-- os.sleep（多过滤 event.pull），mock_event.pull 内部必须用原版避免
-- 递归（补丁版 os.sleep 内部又 event.pull → 互调死循环）。
raw_os_sleep = os.sleep

-- OC-like serialization (simple version)
local mock_serialization = {}
function mock_serialization.serialize(val, pretty)
  if val == nil then return "nil" end
  if type(val) == "boolean" then return tostring(val) end
  if type(val) == "number" then return tostring(val) end
  if type(val) == "string" then
    local s = val:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n"):gsub("\r", "\\r")
    return '"' .. s .. '"'
  end
  if type(val) == "table" then
    local parts = {}
    parts[#parts + 1] = "{"
    local first = true
    for k, v in pairs(val) do
      if not first then parts[#parts + 1] = "," end
      first = false
      local ks = type(k) == "string" and k or "[" .. mock_serialization.serialize(k) .. "]"
      -- numeric keys: prefer [N]= for non-sequential
      if type(k) == "number" then
        ks = "[" .. mock_serialization.serialize(k) .. "]"
      end
      -- string keys that are valid identifiers can omit brackets
      if type(k) == "string" and k:match("^[%a_][%w_]*$") then
        ks = k
      end
      parts[#parts + 1] = ks .. "=" .. mock_serialization.serialize(v, pretty)
    end
    parts[#parts + 1] = "}"
    return table.concat(parts)
  end
  error("cannot serialize " .. type(val))
end

function mock_serialization.unserialize(str)
  local fn = load("return " .. str)
  if not fn then error("unserialize: " .. tostring(fn)) end
  return fn()
end

-- OC mock environment
local OC = {
  _components = {
    ["e1e2e3e4-1234-5678-9abc-def012345678"] = "gpu",
    ["a1b2c3d4-5678-90ab-cdef-123456789abc"] = "screen",
    ["deadbeef-1234-5678-9abc-9876543210ab"] = "internet",
    ["cafe1234-5678-9abc-def0-123456789abc"] = "filesystem",
    ["babe1234-5678-9abc-def0-123456789abc"] = "redstone",
  },
  _free_mem = 524288,
  _uptime = 1234.5,
  _uptime_offset = nil,  -- 首次 uptime() 时基准=真实时钟，之后随真实时钟前进
  _uptime_base_clock = nil,
  _address = "computer-addr-001",
}

-- 真实 GPU 屏幕模拟（v0.3.109）: 80x25 字符缓冲 + 前景/背景色缓冲 +
-- fg/bg 状态（与真机 gpu API 语义一致: set/fill 使用当前 fg/bg）。
-- 用于模拟鼠标渲染测试——断言 drawRow 的颜色输出（字体全黑 bug 的
-- 本地复现路径: 选中段反色后 fg/bg 状态泄漏到后续行）。
-- 注意: tui.lua 通过 component.gpu 代理调用（component.invoke 转来）。
-- 测试可经 oc_mock 导出函数读取缓冲:
--   oc_mock.debug_gpu_screen()  → {text[y][x], fg[y][x], bg[y][x]}
--   oc_mock.debug_gpu_fg/bg()   → 当前状态
local mock_component = {}
local GPU_W, GPU_H = 80, 25
local GPU_Screen = {}   -- [y][x] = char
local GPU_FG = {}       -- [y][x] = 前景色
local GPU_BG = {}       -- [y][x] = 背景色
local GPU_curFG, GPU_curBG = 0xffffff, 0x000000
-- v0.3.112: gpu.set 调用计数（滚动防闪烁测试——断言边界滚动 no-op
-- 时不再全屏重绘; 只计 set, 不计 fill）
local GPU_setCount = 0
-- v0.3.114: shift 修饰键状态（keyboard_proxy.isShiftDown 读取;
-- debug_set_shift 设置; debug_gpu_reset 复位; event.pull 的 test_shift
-- 控制事件原位切换）。声明在文件顶部——debug_gpu_reset(193)/event.pull(331)
-- 都在 keyboard 段(569)之前定义, 靠前声明才能共享同一 upvalue。
local _shiftDown = false
local function gpu_ensure()
  if GPU_Screen[1] then return end
  for y = 1, GPU_H do
    GPU_Screen[y] = {}
    GPU_FG[y] = {}
    GPU_BG[y] = {}
    for x = 1, GPU_W do
      GPU_Screen[y][x] = " "
      GPU_FG[y][x] = GPU_curFG
      GPU_BG[y][x] = GPU_curBG
    end
  end
end
-- v0.3.111: GPU 模拟对齐真机 TextBuffer 宽字符语义（repos/opencomputers
-- TextBuffer.scala:108-144/245-260 + FontUtils.scala:14 实证）:
--   · ≥3 字节 UTF-8 宽字符占 2 格——首格存完整字符, 第 2 格写 padding 空格
--   · ASCII 占 1 格; set 原子覆盖（宽字符一次写 2 格）
--   · gpu.get 宽字符首格返回完整 3 字节字符, padding 格返回 " "
-- 旧实现按【字节】逐格写（中文 3 字节拆 3 格）——tui 宽字符渲染路径
-- 在 mock 下永远测不到真机行为（readContentSelection padding 跳过 /
-- browse 吸附都是死代码）。
local function gpu_set(x, y, text)
  gpu_ensure()
  GPU_setCount = GPU_setCount + 1
  text = tostring(text or "")
  local col = x
  for ch in text:gmatch("([\1-\127\194-\244][\128-\191]*)") do
    local wide = ch:byte(1) >= 128
    if y >= 1 and y <= GPU_H and col >= 1 and col <= GPU_W then
      GPU_Screen[y][col] = ch
      GPU_FG[y][col] = GPU_curFG
      GPU_BG[y][col] = GPU_curBG
      if wide and col + 1 <= GPU_W then
        -- padding 空格（真机 TextBuffer 自动补, 原子覆盖 2 格）
        GPU_Screen[y][col + 1] = " "
        GPU_FG[y][col + 1] = GPU_curFG
        GPU_BG[y][col + 1] = GPU_curBG
      end
    end
    col = col + (wide and 2 or 1)
  end
  return true
end
local function gpu_get(x, y)
  gpu_ensure()
  if y >= 1 and y <= GPU_H and x >= 1 and x <= GPU_W then
    return GPU_Screen[y][x]
  end
  return " "
end
-- v0.3.111: fill 同样宽字符感知——首字符宽度决定每格步长（宽字符 →
-- 每 2 格一对: 字符+padding 空格），与真机 TextBuffer fill 语义一致
local function gpu_fill(x, y, w, h, text)
  gpu_ensure()
  text = tostring(text or " ")
  local ch = text:match("([\1-\127\194-\244][\128-\191]*)") or " "
  local wide = ch:byte(1) >= 128
  for yy = y, math.min(GPU_H, y + h - 1) do
    local col = x
    local xmax = math.min(GPU_W, x + w - 1)
    while col <= xmax do
      if yy >= 1 and col >= 1 then
        GPU_Screen[yy][col] = ch
        GPU_FG[yy][col] = GPU_curFG
        GPU_BG[yy][col] = GPU_curBG
        if wide and col + 1 <= xmax then
          GPU_Screen[yy][col + 1] = " "
          GPU_FG[yy][col + 1] = GPU_curFG
          GPU_BG[yy][col + 1] = GPU_curBG
        end
      end
      col = col + (wide and 2 or 1)
    end
  end
  return true
end
local function OC_gpu(method, ...)
  gpu_ensure()
  if method == "set" then
    return gpu_set(...)
  elseif method == "get" then
    return gpu_get(...)
  elseif method == "fill" then
    return gpu_fill(...)
  elseif method == "setForeground" then
    GPU_curFG = ...
    return true
  elseif method == "setBackground" then
    GPU_curBG = ...
    return true
  elseif method == "getForeground" then
    return GPU_curFG
  elseif method == "getBackground" then
    return GPU_curBG
  end
  return false
end

-- 导出调试读取（测试断言用）
function mock_component.debug_gpu_screen()
  gpu_ensure()
  local out = {}
  for y = 1, GPU_H do
    out[y] = {}
    for x = 1, GPU_W do
      out[y][x] = {ch = GPU_Screen[y][x], fg = GPU_FG[y][x], bg = GPU_BG[y][x]}
    end
  end
  return out
end
function mock_component.debug_gpu_reset()
  GPU_Screen = {}
  GPU_FG = {}
  GPU_BG = {}
  GPU_curFG, GPU_curBG = 0xffffff, 0x000000
  GPU_setCount = 0
  _shiftDown = false  -- v0.3.114: 复位 shift 状态（fresh 模式默认无 shift）
end
-- v0.3.112: gpu.set 调用计数（滚动防闪烁测试: 边界滚动 no-op = 0 次 set）
function mock_component.debug_gpu_set_count()
  return GPU_setCount
end
function mock_component.debug_gpu_set_reset()
  GPU_setCount = 0
end

function mock_component.list(filter)
  local filter = filter or ""
  local i = 0
  local keys = {}
  for addr, typ in pairs(OC._components) do
    if typ:find(filter, 1, true) then
      keys[#keys + 1] = addr
    end
  end
  return function()
    i = i + 1
    local addr = keys[i]
    if not addr then return nil end
    return addr, OC._components[addr]
  end
end
function mock_component.isAvailable(typ)
  for _, t in pairs(OC._components) do
    if t == typ then return true end
  end
  return false
end
function mock_component.getPrimary(typ)
  for addr, t in pairs(OC._components) do
    if t == typ then return {type = t, address = addr} end
  end
  error("no primary " .. typ)
end
function mock_component.get(addr, typ)
  -- resolve abbreviated address
  for full, t in pairs(OC._components) do
    if full == addr or full:sub(1, #addr) == addr then
      if not typ or t == typ then return full end
    end
  end
  return nil, "no such component"
end
function mock_component.type(addr)
  for full, t in pairs(OC._components) do
    if full == addr or full:sub(1, #addr) == addr then return t end
  end
  return nil
end
function mock_component.methods(addr)
  for full, t in pairs(OC._components) do
    if full == addr or full:sub(1, #addr) == addr then
      if t == "redstone" then
        return {getInput = true, setOutput = true, getOutput = true, setBundledOutput = true}
      elseif t == "internet" then
        return {request = true, isHttpEnabled = true, isTcpEnabled = true, connect = true}
      elseif t == "filesystem" then
        return {list = true, exists = true, open = true, size = true}
      elseif t == "gpu" then
        return {bind = true, set = true, get = true, fill = true}
      elseif t == "screen" then
        return {isOn = true, turnOn = true, turnOff = true}
      end
      return {ping = true}
    end
  end
  return nil
end
function mock_component.doc(addr, method)
  for full, t in pairs(OC._components) do
    if full == addr or full:sub(1, #addr) == addr then
      return ("function %s(): %s method documentation"):format(method or "?", t)
    end
  end
  return nil
end
function mock_component.invoke(addr, method, ...)
  local resolved = mock_component.get(addr)
  if not resolved then error("no such component: " .. tostring(addr)) end
  local typ = mock_component.type(resolved)
  if typ == "redstone" and method == "getInput" then
    local side = ...
    return 15
  elseif typ == "internet" and method == "isHttpEnabled" then
    return true
  elseif typ == "gpu" and method == "getResolution" then
    return 80, 25
  elseif typ == "gpu" and (method == "set" or method == "get" or method == "fill"
      or method == "setForeground" or method == "setBackground"
      or method == "getForeground" or method == "getBackground") then
    -- 真实 GPU 屏幕模拟（v0.3.109 鼠标渲染测试）: 维护屏幕缓冲 +
    -- fg/bg 状态。set/fill 用当前 fg/bg 写字符与颜色——单测可断言
    -- 渲染结果（此前 invoke 返回 0，drawRow 的字体全黑/状态泄漏
    -- 无法在本地复现，只能靠真机）。
    return OC_gpu(method, ...)
  elseif typ == "screen" and method == "isOn" then
    return true
  end
  return 0
end

local mock_computer = {}
function mock_computer.address() return OC._address end
function mock_computer.uptime() 
  -- v0.3.88: uptime 随真实时钟前进（interrupt 补丁改用 uptime 基准后，
  -- 固定值会导致 os.sleep(t>0) deadline 永不达到 → 单测死循环）。
  -- 首次调用建立基准，之后返回 基准 + 真实流逝时间。
  if OC._uptime_base_clock == nil then
    OC._uptime_base_clock = os.clock()
  end
  return OC._uptime + (os.clock() - OC._uptime_base_clock)
end
function mock_computer.freeMemory() return OC._free_mem end
function mock_computer.totalMemory() return 2097152 end  -- 2MB 基准（与 config.lua 内存自适应 scale 一致）
function mock_computer.energy() return 100 end
function mock_computer.maxEnergy() return 200 end
function mock_computer.users() return end
function mock_computer.pushSignal(name, ...) end
function mock_computer.pullSignal(timeout) return nil end

-- modem (network card) + event loop mock for subagent protocol testing.
-- Supports single-machine loopback: modem.send() enqueues a modem_message
-- event that event.pull() will deliver (as if another computer replied).
OC._modem_queue = {}
OC._event_queue = {}
OC._modem_open_ports = {}

local mock_event = {}
function mock_event.pull(timeout, ...)
  local filter = {...}
  local deadline = os.clock() + (timeout or 5)
  -- 保存原版 sleep 引用: 中断补丁（agent.interrupt）替换 os.sleep 后，
  -- 这里若用 os.sleep 会递归进补丁版（补丁内部又 event.pull）→ 死循环。
  -- 用原始 sleep（mock 环境下是 no-op fallback）。
  local raw_sleep = raw_os_sleep or (function() end)
  -- 过滤语义（v0.3.89 对齐真机 OpenOS）: 参数1 是事件名 pattern（match，
  -- 非精确），后续参数匹配事件【参数位置】（signal[2]、signal[3]…）——
  -- AND 位置匹配，不是"匹配多个事件名"。例: pull(t,"modem_message",
  -- "interrupted") 要求事件名 match "modem_message" 且 参数1=="interrupted"。
  local name_pat, pos_filters = nil, {}
  if #filter > 0 then
    name_pat = filter[1]
    for i = 2, #filter do pos_filters[i - 1] = filter[i] end
  end
  while true do
    -- v0.3.114 测试控制事件: 排头 test_shift → 原位应用 shift 状态并吞掉
    -- （不返回给 readInput）——事件是预排队的, 处理时才能读到 shift 状态,
    -- 测试需要"事件流中途"切换 shift（shift+方向 → 松开 shift → 普通方向）。
    -- 事件名/参数不参与调用方 filter 匹配（控制事件永远不投递）。
    while #OC._event_queue > 0 and OC._event_queue[1][1] == "test_shift" do
      _shiftDown = not not OC._event_queue[1][2]
      table.remove(OC._event_queue, 1)
    end
    -- deliver queued modem events first
    if #OC._event_queue > 0 then
      local sig = table.remove(OC._event_queue, 1)
      local match = name_pat == nil
      if not match and type(sig[1]) == "string" and sig[1]:match(name_pat) then
        match = true
      end
      if match then
        for i, f in ipairs(pos_filters) do
          if f ~= nil and f ~= sig[i + 1] then match = false break end
        end
      end
      if match then
        return table.unpack(sig)
      end
      -- non-matching event: drop and continue (keeps test simple)
    end
    if os.clock() >= deadline then return nil end
    -- small yield so the deadline check happens; no-op if os.sleep absent
    if raw_sleep then raw_sleep(0.01) end
  end
end
function mock_event.timer(interval, func, ...) return 1 end
function mock_event.cancel(timer) end

local modem_addr = "11aa22bb-3344-5566-7788-99aabbccddee"

local mock_modem = {}
function mock_modem.address() return modem_addr end
function mock_modem.isWireless() return false end
function mock_modem.maxPacketSize() return 8192 end
function mock_modem.isOpen(port)
  return OC._modem_open_ports[port] ~= nil
end
function mock_modem.open(port)
  OC._modem_open_ports[port] = true
  return true
end
function mock_modem.close(port)
  if port then OC._modem_open_ports[port] = nil else OC._modem_open_ports = {} end
  return true
end
function mock_modem.broadcast(port, ...)
  local args = {...}
  table.insert(OC._event_queue, {"modem_message", modem_addr, modem_addr, port, 0, table.unpack(args)})
  return true
end
function mock_modem.send(addr, port, ...)
  local args = {...}
  -- loopback: deliver to self (testing single machine)
  table.insert(OC._event_queue, {"modem_message", modem_addr, modem_addr, port, 0, table.unpack(args)})
  return true
end
function mock_modem.getStrength() return 0 end
function mock_modem.setStrength(v) return 0 end

-- register modem in component list
OC._components[modem_addr] = "modem"

local mock_filesystem = {}
-- delegate to Lua's io for testing
function mock_filesystem.exists(path)
  local f = io.open(path, "r")
  if f then f:close(); return true end
  return false
end
function mock_filesystem.list(path)
  -- real-dir enumeration via cmd (Windows). Returns a proper OC-style
  -- iterator (single function level) so callers can use
  -- `for f in fs.list(path) do` — used by agent.lua's list_directory
  -- and by agent.tools directory scanning.
  local parts = {}
  local handle = io.popen('cmd /c dir /b "' .. tostring(path):gsub("/", "\\") .. '" 2>nul')
  if handle then
    for line in handle:lines() do
      if line ~= "" then parts[#parts + 1] = line end
    end
    handle:close()
  end
  local i = 0
  return function()
    i = i + 1
    return parts[i]
  end
end
function mock_filesystem.isDirectory(path) return false end
function mock_filesystem.makeDirectory(path) return true end
function mock_filesystem.size(path) return 0 end
function mock_filesystem.mounts()
  -- local test env: current directory is writable; expose it as a mount.
  -- Real OC: iterator yields (proxy, mount_path) per iteration.
  local called = false
  local cwd = "./"
  return function()
    if called then return nil end
    called = true
    return {}, cwd  -- (proxy, mount_path)
  end
end

local mock_shell = {}
function mock_shell.execute(cmd)
  local handle = io.popen(cmd .. " 2>&1")
  if not handle then return false, "failed" end
  local result = handle:read("*a")
  handle:close()
  return true, result
end

local mock_internet = {}

-- Mock HTTP response handle: callable table with .response
-- (mimics real OC internet request handle; Lua 5.4 forbids setmetatable on
-- functions, so we use a table with __call)
local function make_handle(body, code)
  local started = false
  local handle = {}
  setmetatable(handle, {
    __call = function()
      if started then return nil end
      started = true
      return body
    end,
    __index = {
      response = function() return code or 200 end,
    },
  })
  return handle
end

function mock_internet.request(url, data, headers, method)
  -- For testing, handle file:// URLs for local testing
  if url:match("^file://") then
    local path = url:sub(8)
    local f = io.open(path, "r")
    if f then
      local content = f:read("*a")
      f:close()
      return make_handle(content)
    end
    error("file not found: " .. path)
  end
  -- Simulate chat completions (LLM API). The mock looks at the request body:
  --   "summarize" trigger in the user content → return a summary response
  --   otherwise → return a generic assistant reply
  if url:match("chat/completions") then
    local body = data or ""
    local reply
    if body:find("Summarize this conversation") then
      reply = "[mock summary] user asked about memory; key facts: 2MB limit, no leak"
    else
      reply = "This is a mock assistant response"
    end
    local resp = '{"choices":[{"message":{"role":"assistant","content":"' .. reply .. '"},"finish_reason":"stop"}]}'
    return make_handle(resp)
  end
  -- Simulate HN Algolia search response
  if url:match("^https://hn%.algolia%.com/") then
    local q = url:match("query=([^&]+)") or "test"
    local body = '{"hits":[{"title":"Result 1 for ' .. q .. '","url":"https://example.com/1","objectID":"1"},{"title":"Result 2 for ' .. q .. '","url":"https://example.com/2","objectID":"2"}],"nbHits":2}'
    return make_handle(body)
  end
  -- Simulate Tavily search response
  if url:match("^https://api%.tavily%.com/") then
    local body = '{"query":"' .. (data or "") .. '","results":[{"title":"Tavily Result 1","url":"https://tavily.example/1","content":"snippet one"},{"title":"Tavily Result 2","url":"https://tavily.example/2","content":"snippet two"}]}'
    return make_handle(body)
  end
  error("internet.mock: cannot handle " .. url)
end

-- OpenOS thread mock (used by agent.tools.shell's shell_execute timeout guard).
-- The real thread library runs the function in a cooperative child thread and
-- waitForAll honors a timeout; this mock runs synchronously and always reports
-- the thread as dead, so local tests exercise the thread branch (require
-- succeeds) without ever really blocking. The true timeout path (thread stays
-- alive past the deadline, killed via t:kill()) must be validated on real OC /
-- ocvm.
local mock_thread = {}
function mock_thread.create(fp, ...)
  -- synchronous execution; stores result in the thread object
  local t = {}
  local args = {...}
  -- select("#", ...) counts varargs on both Lua 5.3 (OC) and 5.4 (test env);
  -- table.maxn was removed in 5.4.
  local n = select("#", ...)
  local ok, res = pcall(fp, table.unpack(args, 1, n))
  t.result = ok and res or nil
  t.err = ok and nil or res
  t.status_ = "dead"
  function t:kill() self.status_ = "dead" end
  return t
end
function mock_thread.waitForAll(threads, timeout)
  for _, t in ipairs(threads) do
    if t.status_ ~= "dead" then return nil, "thread join timed out" end
  end
  return true
end
function mock_thread.waitForAny(threads, timeout)
  return mock_thread.waitForAll(threads, timeout)
end

-- Register mocks globally for agent.lua to use
-- keyboard 组件（v0.3.110 鼠标测试关键）: tui.readInput 开头检测
-- keyboard.isAvailable——缺失时回退 io.read 阻塞读行，事件驱动分支
-- （touch/drag/key_down 处理）永不执行，鼠标渲染测试全假阳性。
-- 真机 OpenOS 中 keyboard 是全局注入（开机组件），这里显式提供。
local keyboard_proxy = setmetatable({}, {
  __index = function(_, method)
    return function(...)
      return mock_component.invoke("k1k2k3k4-5678-9abc-def0-1234567890ab", method, ...)
    end
  end,
})
local function keyboard_isAvailable() return true end
keyboard_proxy.isAvailable = keyboard_isAvailable
keyboard_proxy.isKeyDown = function() return false end
-- v0.3.112: 真机 keyboard 有 isControlDown/isShiftDown/isAltDown——
-- __index 兜底会返回抛错的 invoke 代理（未注册地址），方向键/Home/
-- End 分支的 Ctrl 组合检测一调用即炸。显式提供（返回 false = 无修饰键）。
-- v0.3.114: isShiftDown 支持测试设置（shift 选中编辑测试用 debug_set_shift）。
keyboard_proxy.isControlDown = function() return false end
keyboard_proxy.isShiftDown = function() return _shiftDown end
keyboard_proxy.isAltDown = function() return false end
-- shift 状态可设置（v0.3.114）: 测试前 debug_set_shift(true) 注入 shift
-- 按下状态, 测试后复位。debug_gpu_reset 一并复位（fresh 模式默认无 shift）。
function mock_component.debug_set_shift(v)
  _shiftDown = not not v
end
-- v0.3.115 双击/三击测试: uptime 前推（真实时钟在事件间只走微秒,
-- 连击永远"快"——需要手动推进模拟"慢点击"复位连击计数）。
function mock_component.debug_advance_uptime(seconds)
  OC._uptime = OC._uptime + (seconds or 0)
end
mock_component.keyboard = keyboard_proxy
OC.keyboard = keyboard_proxy

local M = {
  component = mock_component,
  computer = mock_computer,
  filesystem = mock_filesystem,
  shell = mock_shell,
  internet = mock_internet,
  serialization = mock_serialization,
  event = mock_event,
  thread = mock_thread,
  keyboard = keyboard_proxy,
  -- 事件队列导出（文件服务协议测试用手动入队模拟远端请求）
  _event_queue = OC._event_queue,
}

-- component.modem — real OC exposes primary component proxies like this
mock_component.modem = mock_modem

-- component.gpu — real OC exposes primary component proxies like this.
-- v0.3.109: 此前缺失 → tui.init 里 component.gpu 为 nil → 静默降级
-- 80x25 → 本地单测从不执行真实渲染（drawRow 崩溃/字体黑均无法暴露）。
-- proxy: 方法调用 → mock_component.invoke(gpu_addr, method, ...)。
local GPU_ADDR = "e1e2e3e4-1234-5678-9abc-def012345678"
local gpu_proxy = setmetatable({}, {
  __index = function(_, method)
    return function(...)
      return mock_component.invoke(GPU_ADDR, method, ...)
    end
  end,
})
mock_component.gpu = gpu_proxy

return M
