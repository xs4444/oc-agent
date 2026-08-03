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

local MAX_RETRIES = 3            -- retries for transient HTTP failures
local RETRY_BASE_DELAY = 2       -- seconds, doubled per attempt

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

-- POST with automatic retry: transient failures (network errors, 429, 5xx)
-- are retried with exponential backoff. 4xx errors are permanent, never retried.
local function http_post(url, headers, body)
  for attempt = 1, MAX_RETRIES + 1 do
    local code, resp, err = http_post_once(url, headers, body)
    if err then
      if attempt > MAX_RETRIES then return code, resp, err end
    else
      local transient = (code == 429 or code >= 500)
      if not transient or attempt > MAX_RETRIES then
        return code, resp, err
      end
    end
    os.sleep(RETRY_BASE_DELAY * 2 ^ (attempt - 1))
  end
end

return { post = http_post }
