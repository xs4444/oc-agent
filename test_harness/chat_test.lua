-- chat_test.lua: end-to-end chat() test against real LLM API
-- Usage: lua chat_test.lua <api_key> [model] [api_url]
local results = {}
local function log(...)
  local parts = {}
  for i = 1, select("#", ...) do
    parts[i] = tostring(select(i, ...))
  end
  results[#results + 1] = table.concat(parts, " ")
end

log("=== chat() End-to-End Test ===")
log("_VERSION: " .. _VERSION)

-- args come as varargs in OpenOS (no global `arg`)
local args = {...}
local api_key = args[1]
local model = args[2] or "openai/gpt-4o-mini"
local api_url = args[3] or "https://openrouter.ai/api/v1/chat/completions"

if not api_key or api_key == "" then
  log("ERROR: no API key provided. Usage: lua chat_test.lua <api_key> [model] [url]")
else
  log("model: " .. model)
  log("url: " .. api_url)
  log("key: " .. api_key:sub(1, 8) .. "...")

  _TEST_MODE = true
  local ok, err = pcall(dofile, "/mnt/2c2/agent.lua")
  if not ok then
    log("agent load failed: " .. tostring(err))
  else
    log("agent.lua loaded OK")

    local config = {api_key = api_key, model = model, api_url = api_url}
    local messages = {
      {role = "user", content = "Reply with exactly: PONG_OK"}
    }

    log("--- calling chat() ---")
    local chat_ok, response = pcall(chat, messages, config)
    if not chat_ok then
      log("chat() threw: " .. tostring(response))
    elseif response.error then
      log("chat() error: " .. tostring(response.error))
    else
      log("finish_reason: " .. tostring(response.finish_reason))
      if response.content then
        log("content: " .. tostring(response.content))
      else
        log("content: nil")
      end
      if response.tool_calls then
        log("tool_calls: " .. #response.tool_calls)
        for _, tc in ipairs(response.tool_calls) do
          log("  tool: " .. tostring(tc["function"] and tc["function"].name))
          log("  args: " .. tostring(tc["function"] and tc["function"].arguments))
        end
      else
        log("tool_calls: none")
      end
    end
  end
end

-- Write results
local fs = require("filesystem")
for item in fs.list("/mnt") do
  local f = io.open("/mnt/" .. item .. "/chat_test_result.txt", "w")
  if f then
    f:write(table.concat(results, "\n") .. "\n")
    f:close()
  end
end
