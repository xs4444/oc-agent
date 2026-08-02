-- mem_test.lua: measure memory across multi-turn tool-heavy conversation
local results = {}
local function flush()
  local ok, fs = pcall(require, "filesystem")
  if not ok then return end
  local ok2, iter = pcall(fs.list, "/mnt")
  if not ok2 then return end
  for item in iter do
    local f2 = io.open("/mnt/" .. item .. "/mem_test.txt", "w")
    if f2 then f2:write(table.concat(results, "\n") .. "\n") f2:close() end
  end
end
local function log(...)
  local parts = {}
  for i = 1, select("#", ...) do parts[i] = tostring(select(i, ...)) end
  results[#results + 1] = table.concat(parts, " ")
  flush()
end

local args = {...}
local api_key = args[1] or "free"
local model = args[2] or "deepseek-v4-flash"
local api_url = args[3] or "https://opencode.ai/zen/go/v1/chat/completions"

local fs = require("filesystem")
local agent_path
for item in fs.list("/mnt") do
  local full = "/mnt/" .. item
  if fs.exists(full .. "/agent.lua") then agent_path = full .. "/agent.lua" break end
end
_TEST_MODE = true
local ok, err = pcall(dofile, agent_path)
log("agent: " .. tostring(ok) .. " " .. tostring(err))

local computer = require("computer")
local function mem()
  return computer.freeMemory()
end

log("baseline free: " .. mem())
if ok and agent_test then
  local config = {api_key = api_key, model = model, api_url = api_url}
  local messages = {}
  for turn = 1, 4 do
    log("--- turn " .. turn .. " ---")
    messages[#messages + 1] = {role = "user", content = "Turn " .. turn .. ": run execute_lua returning 'ok" .. turn .. "' and tell me the result."}
    for it = 1, 4 do
      local chat_ok, response = pcall(agent_test.chat, messages, config)
      if not chat_ok then log("chat threw: " .. tostring(response)) break
      elseif response.error then log("chat error: " .. tostring(response.error)) break end
      local tcs = response.tool_calls
      local assistant_msg = {role = "assistant", content = response.content or ""}
      if tcs then assistant_msg.tool_calls = tcs end
      messages[#messages + 1] = assistant_msg
      if not tcs or #tcs == 0 then break end
      for _, tc in ipairs(tcs) do
        local r = execute_tool(tc["function"].name, tc["function"].arguments)
        messages[#messages + 1] = {role = "tool", tool_call_id = tc.id, content = r}
      end
    end
    messages = agent_test.trim_history(messages)
    log("free after turn " .. turn .. ": " .. mem() .. " (messages=" .. #messages .. ")")
  end
  log("final free: " .. mem())
end
