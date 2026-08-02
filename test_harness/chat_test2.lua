-- chat_test2.lua: end-to-end via agent_test hooks (dynamic path)
local results = {}
local function log(...)
  local parts = {}
  for i = 1, select("#", ...) do
    parts[i] = tostring(select(i, ...))
  end
  results[#results + 1] = table.concat(parts, " ")
end

log("=== chat() End-to-End (via agent_test) ===")
local args = {...}
local api_key = args[1] or "free"
local model = args[2] or "deepseek-v4-flash-free"
local api_url = args[3] or "https://opencode.ai/zen/v1/chat/completions"
log("model: " .. model)
log("url: " .. api_url)

local fs = require("filesystem")

-- locate agent.lua dynamically under /mnt
local agent_path
for item in fs.list("/mnt") do
  local full = "/mnt/" .. item
  if fs.exists(full .. "/agent.lua") then
    agent_path = full .. "/agent.lua"
    break
  end
end
if not agent_path then
  log("ERROR: agent.lua not found under /mnt")
else
  _TEST_MODE = true
  local ok, err = pcall(dofile, agent_path)
  if not ok then
    log("agent load failed: " .. tostring(err))
  else
    log("agent.lua loaded OK from " .. agent_path)
    if not agent_test then
      log("ERROR: agent_test hooks missing")
    else
      log("hooks: chat=" .. type(agent_test.chat) .. " http_post=" .. type(agent_test.http_post))

      local config = {api_key = api_key, model = model, api_url = api_url}

      -- test 1: plain chat
      log("--- chat #1 (plain) ---")
      local messages = {{role = "user", content = "Reply with exactly: PONG_OK"}}
      local chat_ok, response = pcall(agent_test.chat, messages, config)
      if not chat_ok then
        log("chat threw: " .. tostring(response))
      elseif response.error then
        log("chat error: " .. tostring(response.error))
      else
        log("finish_reason: " .. tostring(response.finish_reason))
        log("content: " .. tostring(response.content))
        log("tool_calls: " .. tostring(response.tool_calls and #response.tool_calls or 0))
      end

      -- test 2: tool use
      log("--- chat #2 (tool use) ---")
      messages = {{role = "user", content = "List the components connected to this computer using the component_list tool."}}
      local chat_ok2, response2 = pcall(agent_test.chat, messages, config)
      if not chat_ok2 then
        log("chat threw: " .. tostring(response2))
      elseif response2.error then
        log("chat error: " .. tostring(response2.error))
      else
        log("finish_reason: " .. tostring(response2.finish_reason))
        log("content: " .. tostring(response2.content))
        if response2.tool_calls then
          log("tool_calls: " .. #response2.tool_calls)
          for _, tc in ipairs(response2.tool_calls) do
            log("  name: " .. tostring(tc["function"] and tc["function"].name))
            log("  args: " .. tostring(tc["function"] and tc["function"].arguments))
          end
        else
          log("tool_calls: none")
        end
      end
    end
  end
end

for item in fs.list("/mnt") do
  local f = io.open("/mnt/" .. item .. "/chat_test2_result.txt", "w")
  if f then f:write(table.concat(results, "\n") .. "\n") f:close() end
end
