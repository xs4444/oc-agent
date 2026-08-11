-- probe4_chatpath.lua — 用 chat() 完整路径验证前缀缓存
-- 用法: lua /mnt/<short>/probe4_chatpath.lua /mnt/<short> <api_key> <model> <api_url>
-- 完全模拟 chat2_test: round1 [user1] → round2 [user1,assistant,user2]
-- 走 agent_test.chat()（含 system prompt + runtime block + 19 tools）
local base = ({...})[1] or "/mnt"
local api_key = ({...})[2] or "free"
local model = ({...})[3] or "deepseek-v4-flash-free"
local api_url = ({...})[4] or "https://opencode.ai/zen/v1/chat/completions"

local out = base .. "/probe4_result.txt"
local f = io.open(out, "w")
local function log(s)
  if f then f:write(s .. "\n"); f:flush() end
  print(s)
end

package.path = base .. "/?.lua;" .. (package.path or "")
_TEST_MODE = true  -- 跳过 First Run Setup 交互（chat2_test 同款）
local ok_load, load_err = pcall(dofile, base .. "/agent/agent.lua")
if not ok_load then log("FATAL: agent.lua load: " .. tostring(load_err)); return end

local chat = agent_test.chat
local config = {api_key = api_key, model = model, api_url = api_url, context_window = 128000}

local function usage_str(u)
  u = u or {}
  return "hit=" .. tostring(u.prompt_cache_hit_tokens or 0)
    .. " miss=" .. tostring(u.prompt_cache_miss_tokens or 0)
    .. " total=" .. tostring(u.prompt_tokens or 0)
    .. " cached=" .. tostring((u.prompt_tokens_details or {}).cached_tokens or 0)
end

-- round1 形状
local messages = {}
messages[1] = {role = "user", content = "Reply with exactly: ROUND_ONE_OK"}
local r1 = chat(messages, config)
log("R1 chat err=" .. tostring(r1 and r1.error) .. " content=" .. tostring(r1 and r1.content):sub(1, 30))
log("R1 usage: " .. usage_str(r1 and r1.usage))

-- round2 形状（扩展前缀）
messages[2] = {role = "assistant", content = r1 and r1.content or ""}
messages[3] = {role = "user", content = "Reply with exactly: ROUND_TWO_OK"}
local r2 = chat(messages, config)
log("R2 chat err=" .. tostring(r2 and r2.error) .. " content=" .. tostring(r2 and r2.content):sub(1, 30))
log("R2 usage: " .. usage_str(r2 and r2.usage))

-- round3: 相同消息再发一次（应全命中）
local r3 = chat(messages, config)
log("R3 chat err=" .. tostring(r3 and r3.error) .. " content=" .. tostring(r3 and r3.content):sub(1, 30))
log("R3 usage: " .. usage_str(r3 and r3.usage))

if f then f:close() end
log("probe4 done")
