-- probe3_cache.lua — 验证 ocvm 上端点前缀缓存行为
-- 用法: lua /mnt/<short>/probe3_cache.lua /mnt/<short> <api_key> <model> <api_url>
-- 1) 两次完全相同请求 → 第二次应命中（若端点支持）
-- 2) 第三次加一条 assistant+user 扩展前缀 → 应命中 system 整块部分
local base = ({...})[1] or "/mnt"
local api_key = ({...})[2] or "free"
local model = ({...})[3] or "deepseek-v4-flash-free"
local api_url = ({...})[4] or "https://opencode.ai/zen/v1/chat/completions"

local out = base .. "/probe3_result.txt"
local f = io.open(out, "w")
local function log(s)
  if f then f:write(s .. "\n"); f:flush() end
  print(s)
end

package.path = base .. "/?.lua;" .. (package.path or "")
local ok_json, json = pcall(require, "agent.json")
local ok_http, http = pcall(require, "agent.http")
if not (ok_json and ok_http) then log("FATAL: json=" .. tostring(ok_json) .. " http=" .. tostring(ok_http)); return end

local headers = {["Content-Type"] = "application/json"}
if api_key ~= "" and api_key ~= "free" then
  headers["Authorization"] = "Bearer " .. api_key
end

local sys = {role = "system", content = ("You are a helpful assistant. "):rep(300)}
local u1 = {role = "user", content = "Reply with exactly: ROUND_ONE_OK"}
local ass = {role = "assistant", content = "ROUND_ONE_OK"}
local u2 = {role = "user", content = "Reply with exactly: ROUND_TWO_OK"}

local function attempt(label, msgs)
  local ok_enc, encoded = pcall(json.encode, {
    model = model, messages = msgs, max_tokens = 64,
  })
  if not ok_enc then log(label .. " ENCODE FAIL: " .. tostring(encoded)); return end
  local code, resp, err = http.post(api_url, headers, encoded)
  if err then log(label .. " ERR: " .. tostring(err):sub(1, 150)); return end
  local ok_d, data = pcall(json.decode, resp)
  if not ok_d or not data then log(label .. " DECODE FAIL: " .. tostring(data)); return end
  local u = data.usage or {}
  log(label .. " HTTP " .. tostring(code) .. " hit=" .. tostring(u.prompt_cache_hit_tokens or 0)
    .. " miss=" .. tostring(u.prompt_cache_miss_tokens or 0)
    .. " total=" .. tostring(u.prompt_tokens or 0)
    .. " cached=" .. tostring((u.prompt_tokens_details or {}).cached_tokens or 0))
end

-- 完全相同的请求两次（A1, A2）→ 第二次应命中
attempt("A1 [sys+u1]      ", {sys, u1})
attempt("A2 [sys+u1] again", {sys, u1})
-- 扩展前缀（B = A + assistant + u2）→ 应命中 A 的整块部分
attempt("B  [sys+u1+ass+u2]", {sys, u1, ass, u2})
-- 完全相同请求再两次（B2）→ 命中 B
attempt("B2 [sys+u1+ass+u2] again", {sys, u1, ass, u2})

if f then f:close() end
log("probe3 done")
