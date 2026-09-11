-- ═══════════════════════════════════════════════════════════════
-- agent.patch — OpenOS 运行时补丁层（v0.3.99）
--
-- 基于 OpenOS 底层架构勘察（GTNH fork，源码行号实测）的运行时修补。
-- 不碰模组 jar（重编译不现实、改 jar 内 Lua 会被模组更新覆盖），
-- 随 agent 分发，GTNH 真机 + ocvm 双环境生效——agent 构建基于
-- OpenOS 架构的落地。
--
-- 统一安装入口 patch.install()，一次修补:
--   P0  可中断 os.sleep          → 复用 agent.interrupt（正式化）:
--        OpenOS 原版 os.sleep 用无过滤 event.pull（boot/02_os.lua:25-31），
--        Ctrl+C 的 interrupted 被消费不中断 sleep → 非 Ready 状态无法中断
--   P1  internet.request 连接超时 → thread + waitForAll 兜底:
--        InternetCard.scala:511 DNS 无超时 + setReadTimeout 仅 POST（:521）
--        + requestTimeout:0 默认无限 → 连接挂起时 Lua 层不运行
--   P2  墙钟工具 now()           → computer.uptime() 优先（世界墙钟），
--        回退 os.clock——http.lua 的 deadline 用 os.clock（CPU 时间），
--        等待网络/退避期间 CPU 不走 → 超时失效（v0.3.88 教训残留）
--   P3  event.pull_any           → 多事件名匹配包装:
--        OpenOS event.pull 多参 = 位置匹配（事件名 match 参数1 且
--        参数N 匹配事件第 N 参数），不是多事件名（v0.3.89 踩过）
--
-- 所有补丁幂等（重复 install 安全），失败静默（无对应环境不破坏）。
-- ═══════════════════════════════════════════════════════════════

local event = require("event")

-- 连接阶段超时（秒）: OC internet.request 连接（DNS+握手）无超时——
-- 包装用 thread + waitForAll 兜底，超时抛错（调用方 pcall 捕获走
-- 错误路径，如 http.lua 的 connection failed）。
local CONNECT_TIMEOUT = 30

local M = {}

-- ── P2: 墙钟 ──────────────────────────────────────────────────
-- computer.uptime() = 游戏世界墙钟（Machine.upTime，世界暂停不走）;
-- os.clock() = CPU 时间（machine.lua sandbox 透传），等待期间不走。
-- 回退顺序: uptime → realTime（GTNH 新增真实墙钟）→ os.clock。
-- 测试环境（oc_mock）的 computer.uptime() 已随时间前进（v0.3.88 修）。
local NOW = nil
local function resolve_now()
  local ok_c, comp = pcall(require, "computer")
  if ok_c and comp and comp.uptime then
    return function() return comp.uptime() end
  end
  if ok_c and comp and comp.realTime then
    return function() return comp.realTime() end
  end
  return os.clock
end
M.now = function()
  if not NOW then NOW = resolve_now() end
  return NOW()
end

-- ── P4: 协作式让出闸门（OpenOS 看门狗）────────────────────────
-- 背景（真机 2026-08-09 实证）: machine.lua:1519 每轮 resume 设
--   deadline = computer.realTime() + system.timeout()（默认 5s），
-- 由 debug count hook（checkDeadline, machine.lua:45-53）在**不被打断的
-- 纯 CPU 段**超时后 error "too long without yielding"。
-- ⚠️ 该错误的 traceback 无诊断价值: machine.lua:836 用
--   pcall(msgh, tostring(tooLongWithoutYielding))
-- 在**栈已展开之后**调用 message handler → handler 里的 debug.traceback()
-- 只能看到 handler 自己的栈（实测真机: init:56 → pcall → machine:836 →
-- init:53 → bios:61，没有任何 agent 帧）→ 真正的崩溃点要在候选路径上逐段
-- 计时找。
-- 真机成本画像（两次独立测量，决定闸门该盖在哪里）:
--   · 逐行读取  ~87.4 KB/s（635 行/550707B = 6.3s）← 会话文件路径的主成本
--   · read("*a") ~290 KB/s（同数据 1.90s，单次调用，<5s 可接受）
--   · json.decode 0.001s/12.7KB 行（几乎免费——曾误判它是瓶颈，改错过一轮）
--   ⇒ 闸门要盖在**读取/迭代循环**上（每行一次），只盖解码处不够。
-- 让出 = os.sleep/event.pull（sysyield）→ 主循环重设 deadline。
-- 用 realTime（**与看门狗同一个钟**）而非 uptime: uptime 是世界时间，
-- 世界停摆时不走，会让闸门误判"还没到点"→ 让出太晚仍崩。
local YIELD_BUDGET = 0.7
local YIELD_SLEEP = 0.05   -- 一个 tick; 不用 0（OC #3779 os.sleep(0) 曾不
                           -- 保证让出——正数才确定重置看门狗）
local REALNOW = nil
local function resolve_realnow()
  local ok_c, comp = pcall(require, "computer")
  if ok_c and comp then
    if comp.realTime then return function() return comp.realTime() end end
    if comp.uptime then return function() return comp.uptime() end end
  end
  return os.clock
end
-- 看门狗同源钟（真实墙钟）。与 M.now() 的区别: now() 优先 uptime（世界
-- 墙钟，供重试/超时预算用），realnow() 优先 realTime（供让出闸门用）。
M.realnow = function()
  if not REALNOW then REALNOW = resolve_realnow() end
  return REALNOW()
end

local gate_last = nil
local gate_off = false
local NOW_FN = nil
-- 时钟探测只做一次（热路径每行都调这个闸门，不能每次都 pcall 组件调用）
local function ensure_clock()
  if NOW_FN then return true end
  local ok, fn = pcall(resolve_realnow)
  if not ok or type(fn) ~= "function" then return false end
  local ok2, v = pcall(fn)
  if not ok2 or type(v) ~= "number" then return false end
  NOW_FN = fn
  return true
end
-- 让出闸门: 在"单次迭代成本可观"的循环体内每轮调一次（per 行/条）。
-- 累计 ~YIELD_BUDGET 秒未让出则让出一次。别放进逐字符内循环——realTime
-- 是组件调用，比迭代本身贵。无 os.sleep/无钟的环境（部分测试）自动降级
-- 为空操作（闸门关，行为与修复前一致）。
M.yield_gate = function()
  if gate_off then return end
  if not NOW_FN and not ensure_clock() then gate_off = true return end
  local now = NOW_FN()
  if gate_last == nil then gate_last = now return end
  if (now - gate_last) < YIELD_BUDGET then return end
  gate_last = now
  if type(os.sleep) ~= "function" then gate_off = true return end
  -- pcall: os.sleep 被 interrupt 补丁包装过（Ctrl+C 时抛 interrupted，
  -- 此处不吞掉用户中断的语义由外层命令循环处理——与既有 loadHistory
  -- 的 pcall(os.sleep, ...) 一致）
  pcall(os.sleep, YIELD_SLEEP)
end

-- 供测试断言: 闸门状态与预算（真机路径不得依赖它们的值）。
M.YIELD_BUDGET = YIELD_BUDGET

-- 测试缝隙: 注入虚拟钟。oc_mock 下真实钟不前进，毫秒级跑完的测试永远
-- 攒不满预算 → 单测需要可控时间轴（watchdog_yield_test.lua 用虚拟钟 +
-- 模拟看门狗 hook 复现真机崩溃类）。传 nil 恢复真实钟。
M._set_clock = function(fn)
  NOW_FN = fn
  gate_last = nil
  gate_off = false
end

-- ── P3: 多事件名匹配 pull ─────────────────────────────────────
-- OpenOS event.pull(timeout, "a", "b") 语义是"事件名 match a 且
-- 参数1==b"（位置匹配）——想要"匹配多个事件名"必须无过滤 pull + 自判
-- （v0.3.89 interrupt 修复同模式）。本包装收敛该模式为直观 API。
-- 返回事件签名（sig[1]=事件名, sig[2]=参数1...），超时返回 nil。
-- 不匹配的事件被消费（与 OpenOS 行为一致——pull 即消费）。
M.pull_any = function(timeout, events)
  local deadline = M.now() + (timeout or 0)
  while true do
    local remaining = deadline - M.now()
    if remaining <= 0 then return nil end
    local sig = {event.pull(remaining)}
    if not sig[1] then return nil end
    for _, e in ipairs(events) do
      if sig[1] == e then
        return table.unpack(sig)
      end
    end
    -- 不匹配: 忽略继续
  end
end

-- ── P1: internet.request 连接超时包装 ─────────────────────────
-- 原版连接阶段无超时（DNS 可挂数分钟）。thread 包装: 创建请求在
-- 线程里跑，waitForAll 超时兜底——超时抛错（调用方 pcall 捕获），
-- 线程后台继续（连接最终由响应迭代 deadline 兜底）。
-- 注意: thread 不可用（精简环境/测试）时回退原版（不破坏）。
local wrapped_request = false
local function wrap_internet_request()
  if wrapped_request then return end
  local ok_i, internet = pcall(require, "internet")
  if not ok_i or not internet or type(internet.request) ~= "function" then return end
  local ok_th, thread = pcall(require, "thread")
  if not ok_th or not thread or not thread.create or not thread.waitForAll then
    wrapped_request = true  -- 不可用也标记（幂等）
    return
  end
  local orig = internet.request
  internet.request = function(url, data, headers, method)
    local result = {}
    local t = thread.create(function()
      -- 线程内 pcall: orig 连接失败抛错会杀死线程——捕获转 err，
      -- 主线程拿 err 明确报"连接失败"而非迭代 nil 崩溃。
      local ok_r, h = pcall(orig, url, data, headers, method)
      if ok_r then
        result.handle = h
      else
        result.err = tostring(h)
      end
    end)
    local ok_w, werr = pcall(thread.waitForAll, {t}, CONNECT_TIMEOUT)
    if not ok_w or not werr then
      -- 超时: 抛错让 pcall 调用方走错误路径（如 http.lua
      -- "connection failed"）。线程后台继续，不阻塞主流程。
      error("connection timeout after " .. CONNECT_TIMEOUT .. "s", 0)
    end
    if result.err then
      error("connection failed: " .. result.err, 0)
    end
    return result.handle
  end
  wrapped_request = true
end

-- ── install: 统一安装（幂等）──────────────────────────────────
M.install = function()
  -- P0: 可中断 os.sleep（agent.interrupt，install 本身幂等）
  local ok_i, interrupt = pcall(require, "agent.interrupt")
  if ok_i and interrupt and interrupt.install then
    interrupt.install()
  end
  -- P1: internet.request 连接超时
  wrap_internet_request()
  return true
end

M.CONNECT_TIMEOUT = CONNECT_TIMEOUT

return M
