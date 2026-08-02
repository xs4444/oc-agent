-- chat_test3.lua: full chat() E2E in OCEmu
local results = {}
local function flush()
  local ok, fs = pcall(require, "filesystem")
  if not ok then return end
  local ok2, iter = pcall(fs.list, "/mnt")
  if not ok2 then return end
  for item in iter do
    local f2 = io.open("/mnt/" .. item .. "/chat3.txt", "w")
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
local model = args[2] or "deepseek-v4-flash-free"
local api_url = args[3] or "https://opencode.ai/zen/v1/chat/completions"
log("model: " .. model)
local fs = require("filesystem")
local agent_path
for item in fs.list("/mnt") do
  local full = "/mnt/" .. item
  if fs.exists(full .. "/agent.lua") then agent_path = full .. "/agent.lua" break end
end
log("agent: " .. tostring(agent_path))
_TEST_MODE = true
local ok, err = pcall(dofile, agent_path)
log("load: " .. tostring(ok) .. " " .. tostring(err))
if ok and agent_test then
  local config = {api_key = api_key, model = model, api_url = api_url}
  local messages = {{role = "user", content = "Reply with exactly: OCEMU_OK"}}
  log("--- chat() ---")
  local chat_ok, response = pcall(agent_test.chat, messages, config)
  if not chat_ok then
    log("chat threw: " .. tostring(response))
  elseif response.error then
    log("chat error: " .. tostring(response.error))
  else
    log("finish: " .. tostring(response.finish_reason))
    log("content: " .. tostring(response.content))
    log("tools: " .. tostring(response.tool_calls and #response.tool_calls or 0))
  end
end
