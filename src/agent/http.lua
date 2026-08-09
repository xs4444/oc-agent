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
-- 讯飞星辰等免费端点频繁 429/慢响应，需要更长的重试窗口。
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
-- 默认 120s；config.response_timeout 可调（chat() 每次请求前同步）
local MAX_RESPONSE_WAIT = 120
-- 单次请求响应体累积上限（字节）: 结构性内存护栏——OOM 无法预测（单次
-- 工具调用/响应峰值不可知），正确解法是给所有已知分配源设硬上限，任何
-- 单次峰值都落在安全线内。http_post_once 的 chunks 累积此前无上限，
-- max_tokens 8192 的 reasoning 响应 JSON 可能 100KB+，decode 峰值 2-3x
-- 单次就爆（真机 2MB 内存）。默认 131072（128KB）——合法响应 ≈60KB
-- 足够容纳且防爆。超限返回明确 error（不静默截断——截断的 JSON 会解析
-- 失败，明确 error 让 chat() 走错误路径）。config.response_body_limit
-- 可调（chat() 每次请求前同步）
local MAX_RESPONSE_BODY = 131072

-- Single request attempt. Returns code, body, err.
local function http_post_once(url, headers, body)
  local internet = require("internet")
  local ok, handle = pcall(function()
    -- 3-arg form: body presence auto-selects POST (compatible with ocvm
    -- and real OC; explicit 4th method arg is ignored by some emulators)
    return internet.request(url, body, headers)
  end)
  if not ok then
    return nil, nil, "connection failed: " .. tostring(handle)
  end

  local chunks = {}
  local timed_out = false
  local too_large = false
  local iter_ok, iter_err = pcall(function()
    local n = 0
    -- 响应迭代 deadline（挂起保护）: 荒野大师 JVM internet 迭代器连接
    -- 建立后流可能永不结束，无超时则无限等（重试预算检查不到——预算在
    -- once 返回后才执行）。保持每 chunk os.sleep(0.02) yield——OC 调度器
    -- 看到进展，避免 "too long without yielding" 崩溃。
    local read_deadline = os.clock() + MAX_RESPONSE_WAIT
    local total = 0
    for chunk in handle do
      if os.clock() >= read_deadline then
        timed_out = true
        return
      end
      -- 响应体累积字节检查（结构性上限）: 任何单次响应峰值不得超过
      -- MAX_RESPONSE_BODY——超限立即返回明确 error（不静默截断，截断的
      -- JSON 解析失败只会让错误更难诊断）。与超时 deadline 共存。
      total = total + #chunk
      if total > MAX_RESPONSE_BODY then
        too_large = true
        return
      end
      n = n + 1
      chunks[#chunks + 1] = chunk
      -- Yield on EVERY chunk: OC's scheduler sees progress even while the
      -- iterator waits for slow (reasoning) model responses. Otherwise the
      -- computer crashes with "too long without yielding".
      os.sleep(0.02)
    end
  end)
  if not iter_ok then
    return nil, nil, "http read failed: " .. tostring(iter_err)
  end
  if timed_out then
    return nil, nil, "http read timeout after " .. tostring(MAX_RESPONSE_WAIT) .. "s"
  end
  if too_large then
    return nil, nil, "http response too large (>" .. tostring(MAX_RESPONSE_BODY) .. " bytes)"
  end
  local response_body = table.concat(chunks)

  -- Some emulators (ocvm) fill the response asynchronously; retry briefly.
  local code
  local mt = getmetatable(handle)
  if mt and mt.__index and mt.__index.response then
    for _ = 1, 10 do
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
local function http_post(url, headers, body)
  local attempt = 0
  local deadline = os.clock() + retry_budget
  while true do
    attempt = attempt + 1
    local code, resp, err = http_post_once(url, headers, body)
    local transient = err ~= nil or code == 429 or (code and code >= 500)
    if not transient then
      return code, resp, err
    end
    local now = os.clock()
    if now >= deadline then
      -- 预算耗尽: 返回最后一次结果（调用方按错误处理）
      return code, resp, err
    end
    local wait = RETRY_BASE_DELAY * 2 ^ (attempt - 1)
    if wait > RETRY_DELAY_CAP then wait = RETRY_DELAY_CAP end
    local remaining = deadline - now
    if wait > remaining then wait = remaining end
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
