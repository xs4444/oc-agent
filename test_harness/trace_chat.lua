-- trace_chat.lua: step-by-step trace of chat() internals
local results = {}
local function log(...)
  local parts = {}
  for i = 1, select("#", ...) do
    parts[i] = tostring(select(i, ...))
  end
  results[#results + 1] = table.concat(parts, " ")
end

log("=== trace chat() ===")
local args = {...}
local api_key = args[1] or "free"
local model = args[2] or "deepseek-v4-flash-free"
local api_url = args[3] or "https://opencode.ai/zen/v1/chat/completions"

_TEST_MODE = true
local ok, err = pcall(dofile, "/mnt/2c2/agent.lua")
log("agent load: " .. tostring(ok) .. (err and (" " .. tostring(err)) or ""))
if not ok then
  local fs = require("filesystem")
  for item in fs.list("/mnt") do
    local f = io.open("/mnt/" .. item .. "/trace_chat_result.txt", "w")
    if f then f:write(table.concat(results, "\n") .. "\n") f:close() end
  end
  return
end

-- step 1: build_system_prompt
local s1, r1 = pcall(build_system_prompt)
log("build_system_prompt: ok=" .. tostring(s1) .. (s1 and (" len=" .. #r1) or (" err=" .. tostring(r1))))

-- step 2: json.encode of body
local body_table = {
  model = model,
  messages = {{role = "user", content = "Reply with exactly: PONG_OK"}},
  tools = TOOLS,
  max_tokens = 2000,
  temperature = 0.7
}
local s2, r2 = pcall(json.encode, body_table)
log("json.encode body: ok=" .. tostring(s2) .. (s2 and (" len=" .. #r2) or (" err=" .. tostring(r2))))

-- step 3: http_post
log("--- http_post ---")
local config = {api_key = api_key, model = model, api_url = api_url}
local headers = {
  ["Content-Type"] = "application/json",
  ["Authorization"] = "Bearer " .. config.api_key
}
local s3, code, body, err3 = pcall(function()
  return http_post(api_url, headers, r2)
end)
log("http_post: ok=" .. tostring(s3))
if s3 then
  log("  code=" .. tostring(code) .. " body_len=" .. tostring(#(body or "")))
  log("  body head: " .. tostring(body or ""):sub(1, 300))
else
  log("  err=" .. tostring(code))
end

-- step 4: json.decode response
if s3 and code == 200 then
  local s4, r4 = pcall(json.decode, body)
  log("json.decode response: ok=" .. tostring(s4) .. (s4 and "" or (" err=" .. tostring(r4))))
  if s4 and r4 then
    local choice = r4.choices and r4.choices[1]
    if choice then
      local msg = choice.message or {}
      log("  finish_reason=" .. tostring(choice.finish_reason))
      log("  content=" .. tostring(msg.content))
      log("  tool_calls=" .. tostring(msg.tool_calls and #msg.tool_calls))
    else
      log("  no choices")
    end
  end
end

local fs = require("filesystem")
for item in fs.list("/mnt") do
  local f = io.open("/mnt/" .. item .. "/trace_chat_result.txt", "w")
  if f then f:write(table.concat(results, "\n") .. "\n") f:close() end
end
