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
--   - 总重试预算 MAX_RETRY_BUDGET 秒（默认 1 小时）——预算耗尽返回
--     最后一次结果。opencode 无总预算（单请求可挂 24 天），但 OC
--     单线程场景必须有界（用户指定上限 1 小时）
--   - 单次等待封顶 RETRY_DELAY_CAP（300s），避免极端退避
-- 讯飞星辰等免费端点频繁 429/慢响应，需要更长的重试窗口。
-- ═══════════════════════════════════════════════════════════════
local RETRY_BASE_DELAY = 2         -- 指数退避基数（秒）
local RETRY_DELAY_CAP = 300        -- 单次等待封顶（秒）
-- 总重试预算: 生产 1 小时；测试环境（_TEST_MODE）缩短为 60s，
-- 避免 e2e/回归在端点持续故障时长时间挂起
local MAX_RETRY_BUDGET = _TEST_MODE and 60 or 3600

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
  local iter_ok, iter_err = pcall(function()
    local n = 0
    for chunk in handle do
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
  local deadline = os.clock() + MAX_RETRY_BUDGET
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

return { post = http_post }
