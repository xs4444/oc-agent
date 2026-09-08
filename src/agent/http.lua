-- ═══════════════════════════════════════════════════════════════
-- agent.http — HTTP client (Phase 2 split).
--
-- Verbatim move of the old agent.lua Section 2 (http_post_once +
-- http_post with retry/backoff), renamed exports to { post = ... }.
-- Constants MAX_RETRIES / RETRY_BASE_DELAY live here.
--
-- Depends on agent.json (declared with a local require, never the
-- global): the request body passed to post() is pre-encoded JSON.
-- ═══════════════════════════════════════════════════════════════

local json = require("agent.json")
local interrupt = require("agent.interrupt")  -- v0.3.86: Ctrl+C 中断支持
local patch = require("agent.patch")  -- v0.3.99: 墙钟 now()（uptime 优先）

-- 墙钟（v0.3.99）: os.clock 是 CPU 时间——等待网络/退避期间不走，
-- deadline 永不触发（v0.3.88 教训残留: 连接挂起时读超时失效）。
-- patch.now() = computer.uptime()（世界墙钟）优先，回退 os.clock。
local now = patch.now

-- ═══════════════════════════════════════════════════════════════
-- Retry policy（参考 opencode src/session/retry.ts 指数退避重试:
-- 2000ms 基数 ×2，瞬态失败无限重试直到成功或不可重试错误）:
--   - 瞬态 = 网络错误 / HTTP 429 / 5xx；4xx 永久失败不重试
--   - 总重试预算 retry_budget 秒（生产默认 300s，config.retry_budget
--     可调——chat() 每次请求前同步，热更新生效；测试环境 _TEST_MODE
--     默认 60s）。预算耗尽返回最后一次结果。opencode 无总预算（单请求
--     可挂 24 天），但 OC 单线程场景必须有界：3600s（1h）对交互式
--     TUI 是"无反馈挂起 1 小时"；300s（5 分钟）折中——端点瞬态故障
--     足够，超时返回最后结果让用户看到错误
--   - 单次等待封顶 RETRY_DELAY_CAP（300s），避免极端退避
-- 免费端点频繁 429/慢响应，需要更长的重试窗口。
-- ═══════════════════════════════════════════════════════════════
local RETRY_BASE_DELAY = 2         -- 指数退避基数（秒）
local RETRY_DELAY_CAP = 300        -- 单次等待封顶（秒）
-- 总重试预算: 生产默认 300s；测试环境（_TEST_MODE）缩短为 60s，
-- 避免 e2e/回归在端点持续故障时长时间挂起。chat() 每次请求前用
-- config.retry_budget 覆盖（热更新）
local retry_budget = _TEST_MODE and 60 or 300
-- 单次请求响应读超时（秒）: 真机荒野大师 internet 迭代器可能在连接
-- 建立后流不结束（JVM 实现可能无 OS 超时）——响应迭代若无超时则无限
-- 等，而重试预算检查（os.clock()）在 once 返回后才执行，预算形同虚设。
-- 默认 900s（15 分钟）——真机 27B vLLM 冷 prefill 实测可超 2 分钟
-- （2026-09 用户确认：冷 prefill 长会真实发生，允许上限 15 分钟）。
-- 与 300s 重试预算配合：单次读超时后预算必然耗尽→不重试，等效"单次
-- 最长 15 分钟"；秒级瞬态失败（连接拒绝/快速 5xx）仍可在预算内重试。
-- 中断随时可杀（chunk 循环子线程化，v0.3.126r1）。
-- config.response_timeout 可覆盖（chat() 每次请求前同步）
local MAX_RESPONSE_WAIT = 900
-- 单次请求响应体累积上限（字节）: 结构性内存护栏——OOM 无法预测（单次
-- 工具调用/响应峰值不可知），正确解法是给所有已知分配源设硬上限，任何
-- 单次峰值都落在安全线内。http_post_once 的 chunks 累积此前无上限，
-- max_tokens 8192 的 reasoning 响应 JSON 可能 100KB+，decode 峰值 2-3x
-- 单次就爆（真机 2MB 内存）。默认 131072（128KB）——合法响应 ≈60KB
-- 足够容纳且防爆。超限返回明确 error（不静默截断——截断的 JSON 会解析
-- 失败，明确 error 让 chat() 走错误路径）。config.response_body_limit
-- 可调（chat() 每次请求前同步）
local MAX_RESPONSE_BODY = 131072

-- 单请求 chunk 收集（主线程/子线程共用）: interrupt/deadline/size 检查
-- 每 chunk 执行（流式正常时按 chunk 粒度生效）。结果写入 box:
--   box.chunks / box.timed_out / box.too_large / box.interrupted
local function collect_chunks(handle, box)
  -- 响应迭代 deadline（挂起保护）: 荒野大师 JVM internet 迭代器连接
  -- 建立后流可能永不结束，无超时则无限等（重试预算检查不到——预算在
  -- once 返回后才执行）。v0.3.99: 用 patch.now()（uptime 墙钟）——
  -- os.clock 是 CPU 时间，等待流数据期间不走 → deadline 永不触发。
  local read_deadline = now() + MAX_RESPONSE_WAIT
  local total = 0
  for chunk in handle do
    -- v0.3.86: Ctrl+C 中断——interrupt.install() 补丁的 os.sleep 检测到
    -- interrupted 事件设标志; 每 chunk 检查, 提前终止响应读取
    if interrupt.poll() then
      box.interrupted = true
      return
    end
    if now() >= read_deadline then
      box.timed_out = true
      return
    end
    -- 响应体累积字节检查（结构性上限）: 任何单次响应峰值不得超过
    -- MAX_RESPONSE_BODY——超限立即返回明确 error（不静默截断，截断的
    -- JSON 解析失败只会让错误更难诊断）。与超时 deadline 共存。
    total = total + #chunk
    if total > MAX_RESPONSE_BODY then
      box.too_large = true
      return
    end
    box.chunks[#box.chunks + 1] = chunk
    -- Yield on EVERY chunk: OC's scheduler sees progress even while the
    -- iterator waits for slow (reasoning) model responses. Otherwise the
    -- computer crashes with "too long without yielding".
    os.sleep(0.02)
  end
end

-- Single request attempt. Returns code, body, err.
--
-- v0.3.126r1 无 chunk 挂起防护（真机事故: vLLM 冷 prefill 长时间不产生
-- 首 chunk——旧实现的 interrupt/deadline 检查只在 chunk 循环体内执行,
-- `for chunk in handle` 无限等待时两者永不运行: 120s 超时失效 + Ctrl+C
-- 的 interrupted 事件被迭代器带过滤等待丢弃（interrupt.lua:6-7）→ TUI
-- 定格 "thinking...+0s" 且无法终止）。
--
-- 修复: chunk 循环移入子线程; 主线程有界等待——os.sleep(0.2) 切片
-- （interrupt 补丁: 无过滤 event.pull, interrupted 设标志）+ 每片检查
-- interrupt/deadline。超时/中断 → thread.kill（dead 标志, 子线程下个
-- yield 点生效）+ handle:close()（释放连接槽——maxTcpConnections=4,
-- 孤儿槽位持续到重启）。
-- 安全性（真机实证依据）:
--   1. Java internet read() 轮询后台 ConcurrentLinkedQueue
--      （InternetCard.scala:432）——数据投递独立于机器事件队列,
--      主线程事件泵不会饿死子线程数据。
--   2. remote.lua read_guarded（thread.create + waitForAll）同形状,
--      真机连跑数日健康。
--   3. 子线程每 chunk os.sleep(0.02) yield——无紧循环调度器饿死
--      （r6b ocvm 教训）。
local function http_post_once(url, headers, body, on_wait)
  local internet = require("internet")
  local ok, handle = pcall(function()
    -- 3-arg form: body presence auto-selects POST (compatible with ocvm
    -- and real OC; explicit 4th method arg is ignored by some emulators)
    return internet.request(url, body, headers)
  end)
  if not ok then
    return nil, nil, "connection failed: " .. tostring(handle)
  end

  local box = { chunks = {}, done = false }
  local ok_th, thread = pcall(require, "thread")
  if ok_th then
    local t = thread.create(function()
      local iter_ok, iter_err = pcall(collect_chunks, handle, box)
      if not iter_ok then box.err = tostring(iter_err) end
      box.done = true
    end)
    local read_deadline = now() + MAX_RESPONSE_WAIT
    local call_start = now()
    local last_tick = 0
    while not box.done do
      if interrupt.poll() then
        interrupt.clear()
        pcall(t.kill, t)
        pcall(handle.close, handle)
        return nil, nil, "interrupted"
      end
      if now() >= read_deadline then
        pcall(t.kill, t)
        pcall(handle.close, handle)
        return nil, nil, "http read timeout after " .. tostring(MAX_RESPONSE_WAIT) .. "s"
      end
      -- v0.3.126r1: on_wait 心跳——TUI 状态栏 "Thinking... +Ns" 在无 chunk
      -- prefill 期间继续计时（此前 drawStatus 只在事件驱动重绘, 主循环冻结
      -- 时 +0s 定格）。节流 ~1/s。
      local t_now = now()
      if on_wait and t_now - last_tick >= 1 then
        last_tick = t_now
        local ok_w, werr = pcall(on_wait, t_now - call_start)
      end
      os.sleep(0.2)
    end
    if box.err then
      return nil, nil, "http read failed: " .. box.err
    end
    if box.timed_out then
      return nil, nil, "http read timeout after " .. tostring(MAX_RESPONSE_WAIT) .. "s"
    end
    if box.too_large then
      return nil, nil, "http response too large (>" .. tostring(MAX_RESPONSE_BODY) .. " bytes)"
    end
    if box.interrupted then
      interrupt.clear()
      return nil, nil, "interrupted"
    end
  else
    -- thread 库不可用（降级环境）: 旧路径——检查在主线程按 chunk 执行。
    -- 失去无 chunk 挂起防护（严格好于报错——保持服务）。
    local iter_ok, iter_err = pcall(collect_chunks, handle, box)
    if not iter_ok then
      return nil, nil, "http read failed: " .. tostring(iter_err)
    end
    if box.timed_out then
      return nil, nil, "http read timeout after " .. tostring(MAX_RESPONSE_WAIT) .. "s"
    end
    if box.too_large then
      return nil, nil, "http response too large (>" .. tostring(MAX_RESPONSE_BODY) .. " bytes)"
    end
    if box.interrupted then
      interrupt.clear()
      return nil, nil, "interrupted"
    end
  end

  local response_body = table.concat(box.chunks)

  -- Some emulators (ocvm) fill the response asynchronously; retry briefly.
  local code
  local mt = getmetatable(handle)
  if mt and mt.__index and mt.__index.response then
    for _ = 1, 10 do
      -- v0.3.86: 中断检查（补丁 os.sleep 已设标志）
      if interrupt.poll() then
        interrupt.clear()
        return nil, nil, "interrupted"
      end
      local ok2, c = pcall(mt.__index.response)
      if ok2 and type(c) == "number" then
        code = c
        break
      end
      os.sleep(0.2)
    end
  end

  return code or 0, response_body, nil
end

-- POST with automatic retry（指数退避 + 总预算上限）
-- v0.3.118: 可选第 4 参 on_retry(attempt, code, err, wait)——每轮退避前
-- 触发（os.sleep 前）。状态栏透出"重试第 N 次/原因/退避多久"——否则
-- 重试期间状态栏冻结在 "Thinking..."，用户看到的是无限 thking。
-- v0.3.126r1: 可选第 5 参 on_wait(elapsed)——单次请求读取期间 ~1/s 心跳
-- （无 chunk prefill 时状态栏 "Thinking... +Ns" 继续计时的数据源）。
-- pcall 包裹: 回调异常不阻断重试（透出是增强，不能成为新故障源）。
local function http_post(url, headers, body, on_retry, on_wait)
  local attempt = 0
  -- v0.3.99: patch.now() 墙钟——os.clock 是 CPU 时间，os.sleep 退避期间
  -- 不走 → 预算 deadline 永不触发（v0.3.88 教训）
  local deadline = now() + retry_budget
  while true do
    attempt = attempt + 1
    local code, resp, err = http_post_once(url, headers, body, on_wait)
    -- v0.3.86: 用户中断——不重试，直接返回（Ctrl+C 语义: 立即停）
    if err == "interrupted" then
      return code, resp, err
    end
    local transient = err ~= nil or code == 429 or (code and code >= 500)
    if not transient then
      return code, resp, err
    end
    local now_t = now()
    if now_t >= deadline then
      -- 预算耗尽: 返回最后一次结果（调用方按错误处理）。v0.3.118: 网络
      -- 错误路径追加"重试 N 次后预算耗尽"——状态栏/错误摘要能看出不是
      -- 静默挂起（HTTP 码路径不动 resp, 避免破坏调用方对码的解析）。
      if err and err ~= "interrupted" then
        err = err .. "（重试 " .. tostring(attempt) .. " 次后预算耗尽）"
      end
      return code, resp, err
    end
    local wait = RETRY_BASE_DELAY * 2 ^ (attempt - 1)
    if wait > RETRY_DELAY_CAP then wait = RETRY_DELAY_CAP end
    local remaining = deadline - now_t
    if wait > remaining then wait = remaining end
    if type(on_retry) == "function" then
      local ok_r, rerr = pcall(on_retry, attempt, code, err, wait)
      if not ok_r then
        -- 回调异常静默（已有 pcall 捕获; 调试时可在此挂 print）
      end
    end
    os.sleep(wait)
  end
end

-- 运行时策略调整（config 热更新: chat() 每次请求前调用）
local function set_budget(b)
  retry_budget = b
end

local function set_response_timeout(t)
  MAX_RESPONSE_WAIT = t
end

local function set_response_body_limit(b)
  MAX_RESPONSE_BODY = b
end

return {
  post = http_post,
  set_budget = set_budget,
  set_response_timeout = set_response_timeout,
  set_response_body_limit = set_response_body_limit,
}
