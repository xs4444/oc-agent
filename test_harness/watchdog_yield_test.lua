-- ════════════════════════════════════════════════════════════════
-- OpenOS 看门狗 / 协作让出回归测试（v0.3.127）
--
-- 真机崩溃（2026-09-08 + 2026-08-09 两次同形）: TUI `/resume` 报
--   "too long without yielding"
--
-- 机制（源码锚定）:
--   · machine.lua:1519 每轮 resume 设
--       deadline = computer.realTime() + system.timeout()   -- 默认 5s
--   · machine.lua:45-53 count hook checkDeadline: 不被打断的纯 CPU 段
--     累计超 deadline → error("too long without yielding")
--   · 让出（os.sleep → pullSignal → sysyield）才重置 deadline
--   · ⚠️ 崩溃 traceback 无诊断价值: machine.lua:836 是
--       pcall(msgh, tostring(tooLongWithoutYielding))
--     —— 栈展开**之后**才调 message handler，handler 里 debug.traceback()
--     只能看到 handler 自己那条栈（真机实测: init:56 → pcall →
--     machine:836 → init:53 → bios:61，零 agent 帧）。
--
-- 真机实测成本分布（2026-08-09，两次独立测量）——**瓶颈是读取不是解码**:
--   · 单行 12784B 的 json.decode = 0.001s        （解码几乎免费）
--   · 635 行 f:lines() 迭代      = 6.3s          （逐行读取 ~87.4 KB/s）
--   · 同数据 read("*a")          = 1.90s         （整读 ~290 KB/s）
--   · unserialize 348KB          ≈ 0.00s
--   ⇒ /resume 的 picker + load_history 各跑一趟 635 行逐行读取，单趟 6.3s
--     > 5s 阈值 → 崩。**只给 decode 加让出是不够的，必须在读取循环里让出。**
--
-- 本测试把该性质搬进 CI: 虚拟钟按**真机实测速率**给 json.decode/encode
-- **以及文件读取**计时（io.open 句柄包成代理，read/lines 按字节计费），
-- 再用 debug.sethook 复刻 machine.lua 的 checkDeadline（超阈值 error）。
-- os.sleep = 让出点 → 重置。于是:
--   · 对照组（无让出的整份读取 / 整份解码）必触发——证明量具有效
--   · 修复后的 /resume 全流程必须不触发
--   · 反向对照（冻住闸门钟）会让 /resume 报出与真机逐字相同的错误
--
-- 独立文件原因: 同 session_resume_test.lua（run_tests.lua 主 chunk 局部
-- 变量贴近 200 上限，新增段落一律独立文件 + dofile 接入）。
--
-- 运行:
--   独立:  cd test_harness && lua5.3 watchdog_yield_test.lua
--   接入:  run_tests.lua 设 _IN_RUN_TESTS=true 后 dofile，本文件跳过
--          os.exit 并 return pass, fail 由宿主累加。
-- ════════════════════════════════════════════════════════════════

io.stdout:setvbuf("no")

-- 环境搭建（幂等: 被 run_tests dofile 时 oc_mock/agent 已加载）
if not package.loaded["oc_mock"] then
  package.path = "./?.lua;" .. package.path
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
if not package.loaded["agent.session"] then
  package.path = "../src/?.lua;" .. package.path
  pcall(dofile, "../src/agent/init.lua")
end
local json = require("agent.json")
local patch = require("agent.patch")

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

-- ═══════════════════════════════════════════════════════════════
-- 虚拟看门狗（复刻 machine.lua:1519 + 45-53）
-- ═══════════════════════════════════════════════════════════════
local LIMIT = 5                       -- system.timeout() 默认 5s
local DECODE_RATE  = 106427           -- B/s  真机实测 json.decode
local READ_LINE_RATE = 87400          -- B/s  真机实测逐行读取（635 行/550707B=6.3s）
local READ_ALL_RATE  = 289845         -- B/s  真机实测 read("*a")（550707B=1.90s）

local VCLOCK = 0                      -- 虚拟秒（只被计量操作推进 = 不间断 CPU 段）
local LAST_YIELD = 0
local fired = false
local sleep_calls = 0
local decode_calls, decode_bytes = 0, 0
local read_bytes = 0

local real_decode, real_encode = json.decode, json.encode
local real_sleep = os.sleep
local real_io_open = io.open

local function charge(bytes, rate)
  VCLOCK = VCLOCK + bytes / rate
end

-- io.open 句柄代理: read/lines 按真机速率计费（其余方法透传）
local function wrap_handle(h)
  local proxy = {}
  proxy.lines = function(_, ...)
    local it = h:lines(...)
    return function()
      local line = it()
      if line ~= nil then
        read_bytes = read_bytes + #line + 1
        charge(#line + 1, READ_LINE_RATE)
      end
      return line
    end
  end
  proxy.read = function(_, fmt, ...)
    local r = h:read(fmt, ...)
    if type(r) == "string" then
      local rate = (fmt == "*a" or fmt == "a") and READ_ALL_RATE or READ_LINE_RATE
      read_bytes = read_bytes + #r
      charge(#r, rate)
    end
    return r
  end
  proxy.write = function(_, s)
    if type(s) == "string" then
      read_bytes = read_bytes + #s
      charge(#s, READ_ALL_RATE)      -- 写同量级计费（保守）
    end
    return h:write(s)
  end
  return setmetatable(proxy, {
    __index = function(_, k)
      local v = h[k]
      if type(v) == "function" then
        return function(_, ...) return v(h, ...) end
      end
      return v
    end,
  })
end

local function install_instrumentation()
  json.decode = function(s)
    local n = type(s) == "string" and #s or 0
    decode_calls = decode_calls + 1
    decode_bytes = decode_bytes + n
    charge(n, DECODE_RATE)
    return real_decode(s)
  end
  json.encode = function(v)
    local out = real_encode(v)
    charge(#out, DECODE_RATE)
    return out
  end
  io.open = function(path, ...)
    local h = real_io_open(path, ...)
    if not h then return nil end
    return wrap_handle(h)
  end
  os.sleep = function(s)
    sleep_calls = sleep_calls + 1
    LAST_YIELD = VCLOCK            -- 让出 = 重置看门狗（machine.lua 主循环重设 deadline）
    if real_sleep then pcall(real_sleep, s) end
  end
  patch._set_clock(function() return VCLOCK end)
end

install_instrumentation()

local function arm()
  VCLOCK, LAST_YIELD, fired = 0, 0, false
  sleep_calls = 0
  decode_calls, decode_bytes, read_bytes = 0, 0, 0
  patch._set_clock(function() return VCLOCK end)
  debug.sethook(function()
    if VCLOCK - LAST_YIELD >= LIMIT then
      fired = true
      error("too long without yielding", 0)
    end
  end, "", 1000)
end
local function disarm()
  debug.sethook()
end

-- ═══════════════════════════════════════════════════════════════
-- 语料: 635 行 / ~550KB（对齐真机 agent_history_162903596.4.jsonl
-- 实测 635 行 / 550707B / maxline 12784 / 101 行 >2KB）
-- ═══════════════════════════════════════════════════════════════
local TMPDIR = "test_wd_tmp"
os.execute("mkdir -p " .. TMPDIR)
local BIG = TMPDIR .. "/big_session.jsonl"

local function build_corpus(path, target_lines)
  local small = {80, 150, 250, 400, 600, 900}
  local big = {2000, 3000, 4000, 12784}
  local f = assert(real_io_open(path, "w"))
  local total, n = 0, 0
  for i = 1, target_lines do
    local role, sz
    local roll = i % 10
    if roll == 0 then
      sz = big[(i // 10) % #big + 1]
      role = "tool"
    else
      sz = small[i % #small + 1]
      if roll <= 4 then role = "assistant" else role = "tool" end
    end
    if i % 17 == 0 then role = "user" sz = 60 + (i % 200) end
    local m = {role = role, content = string.rep("x", sz)}
    if role == "assistant" and i % 7 == 0 then
      m.tool_calls = {{["function"] = {name = "read_file", arguments = '{"path":"/home/x.lua"}'}}}
    end
    local line = real_encode(m)
    f:write(line, "\n")
    total = total + #line + 1
    n = n + 1
  end
  f:close()
  return n, total
end

local nlines, nbytes = build_corpus(BIG, 635)
test("语料: 行数/字节数达标（模拟真机会话体量）",
  nlines >= 600 and nbytes >= 550000,
  "lines=" .. nlines .. " bytes=" .. nbytes)

-- 真机换算: 逐行读取与解码各自的虚拟耗时
do
  local read_est = nbytes / READ_LINE_RATE
  local dec_est = nbytes / DECODE_RATE
  test("语料: 逐行读取虚拟耗时 > 阈值（本测试针对真瓶颈）",
    read_est > LIMIT, string.format("read_est=%.2fs limit=%ds", read_est, LIMIT))
  test("语料: 解码虚拟耗时 < 逐行读取耗时（纠正「解码是瓶颈」的误判）",
    dec_est < read_est, string.format("dec=%.2fs read=%.2fs", dec_est, read_est))
end

-- ═══════════════════════════════════════════════════════════════
-- ① 对照组 A: 无让出的**逐行读取** → 必须触发（真根因的等价物）
-- ═══════════════════════════════════════════════════════════════
do
  arm()
  local ok_c, err_c = pcall(function()
    local f = assert(io.open(BIG, "r"))
    for _ in f:lines() do end
    f:close()
  end)
  disarm()
  test("control A: 无让出整份逐行读取触发看门狗（真根因复现）",
    (not ok_c) and tostring(err_c):find("too long without yielding", 1, true) ~= nil,
    "ok=" .. tostring(ok_c) .. " err=" .. tostring(err_c))
end

-- ② 对照组 B: 无让出的整份解码（旧认知）
do
  arm()
  local ok_c, err_c = pcall(function()
    local f = assert(io.open(BIG, "r"))
    for line in f:lines() do json.decode(line) end
    f:close()
  end)
  disarm()
  test("control B: 无让出整份解码也触发（读取+解码合计）",
    (not ok_c) and tostring(err_c):find("too long without yielding", 1, true) ~= nil,
    "ok=" .. tostring(ok_c) .. " err=" .. tostring(err_c))
end

-- ═══════════════════════════════════════════════════════════════
-- ③ 让出闸门契约（patch.yield_gate）
-- ═══════════════════════════════════════════════════════════════
do
  patch._set_clock(function() return VCLOCK end)
  VCLOCK, sleep_calls = 0, 0
  local max_gap, since = 0, 0
  for _ = 1, 30 do
    VCLOCK = VCLOCK + 0.2
    local before = sleep_calls
    patch.yield_gate()
    if sleep_calls > before then
      max_gap = math.max(max_gap, since)
      since = 0
    else
      since = since + 0.2
    end
  end
  test("gate: 累计超预算即让出（最长不间断 < 阈值）",
    sleep_calls > 0 and max_gap < LIMIT,
    string.format("max_gap=%.1fs sleeps=%d", max_gap, sleep_calls))
  test("gate: 不会每轮都让出（预算生效，非无脑 sleep）",
    sleep_calls <= 10, "sleeps=" .. sleep_calls)
end

-- ═══════════════════════════════════════════════════════════════
-- ④ 生产路径: /resume 全流程
-- ═══════════════════════════════════════════════════════════════
local agent_test = _G.agent_test
local sess_mod = require("agent.session")
local cfg_mod = require("agent.config")
test("agent_test.handle_command 测试钩子可用",
  type(agent_test) == "table" and type(agent_test.handle_command) == "function",
  tostring(type(agent_test)))

if type(agent_test) == "table" and agent_test.handle_command then
  local saved_sdir = sess_mod.get_sessions_dir()
  local saved_path = sess_mod.current_path()
  local ok_cfg, cfg = pcall(cfg_mod.load)
  if not ok_cfg or type(cfg) ~= "table" then cfg = cfg_mod end

  sess_mod.set_sessions_dir(TMPDIR)
  agent_test.set_history_path(TMPDIR .. "/main_history.jsonl")

  arm()
  local ok_r, e_r, _c_r, m_r = pcall(agent_test.handle_command,
    "/resume big_session", cfg, {})
  disarm()
  local resumed = type(m_r) == "table" and #m_r or -1
  test("resume: 看门狗下不崩（含 picker 逐行读取全流程）",
    ok_r and not fired,
    "ok=" .. tostring(ok_r) .. " err=" .. tostring(e_r)
      .. " fired=" .. tostring(fired) .. " vclock=" .. string.format("%.2f", VCLOCK))
  test("resume: 确实恢复出消息表", resumed > 0, "msgs=" .. tostring(resumed))
  -- picker 不再整份解码: 解码量只应 ≈ 一趟（load_history），而非两趟
  test("resume: 解码量只相当于一趟（picker 零解码）",
    decode_bytes > 0 and decode_bytes < nbytes * 1.35,
    string.format("decoded=%d file=%d ratio=%.2f",
      decode_bytes, nbytes, decode_bytes / nbytes))
  -- 让出确实发生（读取循环与解码循环都过闸门）
  test("resume: 全流程确实让出（读取循环也被闸门覆盖）",
    sleep_calls > 0, "sleeps=" .. sleep_calls)

  -- ⑤ load_history: 逐行读取 + 解码，必须让出
  nlines, nbytes = build_corpus(BIG, 635)
  agent_test.set_history_path(BIG)
  arm()
  local ok_l, err_l = pcall(agent_test.load_history)
  disarm()
  test("load_history: 看门狗下不崩", ok_l and not fired,
    "ok=" .. tostring(ok_l) .. " err=" .. tostring(err_l))
  test("load_history: 读取/解码途中确实让出",
    sleep_calls > 0, "sleeps=" .. sleep_calls)

  -- ⑥ tui.loadHistory: 每条消息过闸门（结构性断言）
  do
    local tui = require("agent.tui")
    pcall(tui.init, {})
    local msgs = {}
    for i = 1, 200 do
      msgs[i] = {role = "assistant", content = string.rep("y", 300 + i)}
    end
    local gate_calls = 0
    local orig_gate = patch.yield_gate
    patch.yield_gate = function() gate_calls = gate_calls + 1 end
    local ok_t, err_t = pcall(function() tui.loadHistory(msgs) end)
    patch.yield_gate = orig_gate
    test("tui.loadHistory: 每条消息调用让出闸门",
      ok_t and gate_calls >= #msgs,
      "ok=" .. tostring(ok_t) .. " err=" .. tostring(err_t)
        .. " calls=" .. tostring(gate_calls) .. "/" .. #msgs)
  end

  sess_mod.set_sessions_dir(saved_sdir)
  agent_test.set_history_path(saved_path or (TMPDIR .. "/main_history.jsonl"))
  agent_test.set_history_path(saved_path)
end

-- ═══════════════════════════════════════════════════════════════
-- 收尾: 还原被包装的全局（本文件被 run_tests dofile 时不能污染后续用例）
-- ═══════════════════════════════════════════════════════════════
os.sleep = real_sleep
io.open = real_io_open
json.decode = real_decode
json.encode = real_encode
patch._set_clock(nil)
os.execute("rm -rf " .. TMPDIR)

print(string.format("RESULT: %d pass, %d fail", pass, fail))
if not _IN_RUN_TESTS then
  os.exit(fail > 0 and 1 or 0)
end
return pass, fail
