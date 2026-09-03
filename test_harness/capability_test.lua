-- capability_test.lua: probe LLM capability boundaries via agent
-- Runs sequential tasks, each recorded with result + which tools were used
local results = {}
local function log(...)
  local parts = {}
  for i = 1, select("#", ...) do
    parts[i] = tostring(select(i, ...))
  end
  results[#results + 1] = table.concat(parts, " ")
end

local args = {...}
local api_key = args[1] or "free"
local model = args[2] or "deepseek-v4-flash-free"
local api_url = args[3] or "https://opencode.ai/zen/v1/chat/completions"

log("=== Capability Boundary Test ===")
log("model: " .. model)
log("url: " .. api_url)

local fs = require("filesystem")
local agent_path
for item in fs.list("/mnt") do
  local full = "/mnt/" .. item
  if fs.exists(full .. "/agent.lua") then
    agent_path = full .. "/agent.lua"
    break
  end
end
if not agent_path then
  log("ERROR: agent.lua not found")
else
  _TEST_MODE = true
  local ok, err = pcall(dofile, agent_path)
  if not ok then
    log("agent load failed: " .. tostring(err))
  else
    log("agent loaded from " .. agent_path)
    local config = {api_key = api_key, model = model, api_url = api_url}

    -- Full agent loop simulation: messages + tool execution
    local function run_turn(user_msg, label, max_iters)
      max_iters = max_iters or 6
      local messages = {{role = "user", content = user_msg}}
      log("")
      log("=== " .. label .. " ===")
      log("USER: " .. user_msg)
      local tools_used = {}
      local final_text = ""
      local iters = 0
      while iters < max_iters do
        iters = iters + 1
        local chat_ok, response = pcall(agent_test.chat, messages, config)
        if not chat_ok then
          log("chat threw: " .. tostring(response))
          break
        elseif response.error then
          log("chat error: " .. tostring(response.error))
          break
        end
        if response.content and #response.content > 0 then
          final_text = response.content
        end
        local tcs = response.tool_calls
        if not tcs or #tcs == 0 then
          break
        end
        local assistant_msg = {role = "assistant", content = response.content or ""}
        assistant_msg.tool_calls = tcs
        messages[#messages + 1] = assistant_msg
        for _, tc in ipairs(tcs) do
          local tname = tc["function"].name
          local targs = tc["function"].arguments
          tools_used[#tools_used + 1] = tname
          log("[tool] " .. tname .. " " .. targs)
          local result = execute_tool(tname, targs)
          log("[result] " .. tostring(result):sub(1, 400))
          messages[#messages + 1] = {role = "tool", tool_call_id = tc.id, content = result}
        end
      end
      log("[tools used] " .. table.concat(tools_used, ", "))
      log("[final] " .. tostring(final_text):sub(1, 500))
      return final_text, tools_used
    end

    -- Task 1: basic chat
    run_turn("Reply with exactly: CAPABILITY_OK", "T1 basic chat", 2)

    -- Task 2: file write+read roundtrip
    run_turn("Write the text 'HELLO_GTNH' to the file /hello.txt using write_file, then read it back with read_file and tell me what it says.", "T2 file roundtrip", 6)

    -- Task 3: component discovery chain (v0.3.124: shell components + lua -e)
    run_turn("Use shell_execute to run the 'components' command and see what components exist, find the internet component's address, then use shell_execute with lua -e to call component.invoke on that address with method 'isHttpEnabled'. Tell me the result.", "T3 component chain", 8)

    -- Task 4: computation via lua -e (execute_lua removed)
    run_turn("Use shell_execute to run lua -e 'print(17*23)' and tell me the result.", "T4 lua exec", 4)

    -- Task 5: multi-step combined (use several tools in sequence)
    run_turn("First use shell_execute to run 'components filesystem' to list filesystem components, then use shell_execute with lua -e to call component.invoke getLabel on one of them. Tell me what labels you found.", "T5 combined", 8)
  end
end

for item in fs.list("/mnt") do
  local f = io.open("/mnt/" .. item .. "/capability_result.txt", "w")
  if f then f:write(table.concat(results, "\n") .. "\n") f:close() end
end
