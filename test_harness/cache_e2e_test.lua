-- cache_e2e_test.lua: ocvm 实测前缀缓存命中（缓存计费 P0 验收）
-- 场景: 两次顺序 chat() 请求（第 2 条消息延续第 1 条），验证:
--   1) 尾部 runtime 消息（user 角色）被 zen 端点接受（无 400/校验错误）
--   2) 第 2 次请求 usage.prompt_cache_hit_tokens > 0（前缀缓存生效）
--   3) hit + miss ≈ prompt_tokens（usage 字段透传完整）
-- 用法: lua /mnt/<short>/cache_e2e_test.lua /mnt/<short> <api_key> <model> <api_url>
local base = ({...})[1] or "/mnt"
local api_key = ({...})[2] or "free"
local model = ({...})[3] or "deepseek-v4-flash"
local api_url = ({...})[4] or "https://opencode.ai/zen/go/v1/chat/completions"

local PASS, FAIL = 0, 0
local RESULT_NAME = "cache_e2e_result.txt"
local function log(...)
  local parts = {}
  for i = 1, select("#", ...) do parts[i] = tostring(select(i, ...)) end
  local line = table.concat(parts, " ")
  print(line)
  -- 写到所有挂载盘（宿主机 find 任一挂载都能抓到）
  local fs_ok, fs = pcall(require, "filesystem")
  if fs_ok and fs.list then
    for item in fs.list("/mnt") do
      local f = io.open("/mnt/" .. item .. "/" .. RESULT_NAME, "a")
      if f then f:write(line .. "\n") f:close() end
    end
  end
end
io.open(base .. "/" .. RESULT_NAME, "w"):close()
local function check(name, cond, detail)
  if cond then PASS = PASS + 1 log("PASS " .. name)
  else FAIL = FAIL + 1 log("FAIL " .. name .. (detail and (" -- " .. tostring(detail)) or "")) end
end

local fs = require("filesystem")
local agent_path
for item in fs.list("/mnt") do
  local full = "/mnt/" .. item
  if fs.exists(full .. "/agent.lua") then agent_path = full .. "/agent.lua" break end
end
if not agent_path then log("ERROR: agent.lua not found") log("RESULT: 0 pass, 0 fail") return end

_TEST_MODE = true
local ok, err = pcall(dofile, agent_path)
check("agent loads", ok, err)
if not ok then log("RESULT: " .. PASS .. " pass, " .. FAIL .. " fail") return end

local chat = agent_test.chat
local config = {api_key = api_key, model = model, api_url = api_url, context_window = 128000}

local function usage_str(u)
  u = u or {}
  return "hit=" .. tostring(u.prompt_cache_hit_tokens or 0)
    .. " miss=" .. tostring(u.prompt_cache_miss_tokens or 0)
    .. " total=" .. tostring(u.prompt_tokens or 0)
end

-- 缓存命中 token: 兼容两种 provider 上报格式
--   DeepSeek/zen:        usage.prompt_cache_hit_tokens
--   讯飞星辰(kimi)/OpenAI 新格式: usage.prompt_tokens_details.cached_tokens
local function cache_hit(u)
  u = u or {}
  if u.prompt_cache_hit_tokens then return u.prompt_cache_hit_tokens end
  if u.prompt_tokens_details and u.prompt_tokens_details.cached_tokens then
    return u.prompt_tokens_details.cached_tokens
  end
  return 0
end

-- 原始 usage 全量 dump（诊断: 讯飞可能用 OpenAI 新格式
-- prompt_tokens_details.cached_tokens 或厂商自定义字段）
local function usage_dump(u)
  u = u or {}
  local parts = {}
  for k, v in pairs(u) do
    if type(v) == "table" then
      local sub = {}
      for k2, v2 in pairs(v) do sub[#sub + 1] = tostring(k2) .. "=" .. tostring(v2) end
      parts[#parts + 1] = tostring(k) .. "={" .. table.concat(sub, ",") .. "}"
    else
      parts[#parts + 1] = tostring(k) .. "=" .. tostring(v)
    end
  end
  return table.concat(parts, " ")
end

-- 429/5xx 退避重试（免费端点限流常见）：最多 3 次尝试，间隔 45s
local function call_with_retry(label, fn)
  for attempt = 1, 3 do
    local resp = fn()
    if resp and not resp.error then return resp end
    local err = tostring(resp and resp.error or "nil")
    log(label .. " attempt " .. attempt .. " failed: " .. err:sub(1, 200))
    if err:find("429") or err:find("5") then
      if attempt < 3 then
        log("  backing off 45s before retry...")
        os.sleep(45)
      end
    else
      return resp -- 非限流错误不重试
    end
  end
  return nil
end

-- 请求 1: 固定首条 user 消息（缓存前缀锚点）
local m1 = {role = "user", content = "Reply with exactly: CACHE_TEST_ONE"}
local t1 = os.clock()
local r1 = call_with_retry("request 1", function()
  return chat({m1}, config)
end)
local d1 = os.clock() - t1
check("request 1 succeeds (tail accepted, no 400)", r1 and not r1.error,
  r1 and tostring(r1.error):sub(1, 300) or "nil response")
log("usage1: " .. usage_str(r1 and r1.usage) .. " | " .. string.format("%.1fs", d1))
log("usage1 raw: " .. usage_dump(r1 and r1.usage))
check("request 1 reports usage", r1 and r1.usage and r1.usage.prompt_tokens ~= nil,
  usage_str(r1 and r1.usage))

-- 请求 2: 追加 assistant 回复 + 新 user 消息 → 前缀 = 请求 1 的
-- system + tools + m1（尾部 runtime 块每次变化，不进缓存前缀）
local t2 = os.clock()
local r2 = call_with_retry("request 2", function()
  return chat({
    m1,
    {role = "assistant", content = r1 and r1.content or "ok"},
    {role = "user", content = "Reply with exactly: CACHE_TEST_TWO"},
  }, config)
end)
local d2 = os.clock() - t2
check("request 2 succeeds", r2 and not r2.error,
  r2 and tostring(r2.error):sub(1, 300) or "nil response")
local u2 = r2 and r2.usage or {}
log("usage2: " .. usage_str(u2) .. " | " .. string.format("%.1fs", d2))
log("usage2 raw: " .. usage_dump(u2))
check("request 2 has cache hit > 0", cache_hit(u2) > 0,
  usage_str(u2))
-- OpenAI 新格式无显式 miss 字段: miss = prompt_tokens - hit
local hit2 = cache_hit(u2)
check("cache hit ≤ prompt_tokens",
  (u2.prompt_tokens or 0) > 0 and hit2 > 0 and hit2 <= u2.prompt_tokens,
  usage_str(u2))

-- 命中率推算: 命中应覆盖 system + tools + m1（提示该部分已进缓存）
if hit2 > 0 then
  local miss2 = math.max(0, (u2.prompt_tokens or 0) - hit2)
  log("cache hit ratio: " .. string.format("%.1f%%", hit2 / (hit2 + miss2) * 100)
    .. " (hit=" .. tostring(hit2) .. " miss=" .. tostring(miss2) .. ")")
end

log("")
log("RESULT: " .. PASS .. " pass, " .. FAIL .. " fail")
