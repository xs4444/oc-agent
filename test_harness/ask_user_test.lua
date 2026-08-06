-- ask_user_test.lua: chat e2e — 尝试调用 ask_user 工具
-- 用法: lua /mnt/<short>/ask_user_test.lua /mnt/<short> [api_key] [model] [api_url]
-- 结果: /mnt/<short>/ask_user_test_result.txt
local base = ({...})[1] or "/mnt"
local api_key = ({...})[2] or "free"
local model = ({...})[3] or "deepseek-v4-flash-free"
local api_url = ({...})[4] or "https://opencode.ai/zen/v1/chat/completions"

local function log(...)
  local parts = {}
  for i = 1, select("#", ...) do parts[i] = tostring(select(i, ...)) end
  local line = table.concat(parts, " ")
  print(line)
  local f = io.open(base .. "/ask_user_test_result.txt", "a")
  if f then f:write(line .. "\n") f:close() end
end

io.open(base .. "/ask_user_test_result.txt", "w"):close()

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
  log("ERROR: agent.lua not found under /mnt")
  log("RESULT: 0 pass, 0 fail")
  return
end

_TEST_MODE = true
local ok, err = pcall(dofile, agent_path)
if not ok then
  log("agent load failed: " .. tostring(err))
  log("RESULT: 0 pass, 0 fail")
  return
end
log("agent.lua loaded OK from " .. agent_path)
log("model: " .. model)

-- 1) 确认 TOOLS 声明里含 ask_user
local found = false
for _, t in ipairs(agent_test.TOOLS or {}) do
  local fn = t["function"] or {}
  if fn.name == "ask_user" then
    found = true
    log("TOOLS contains ask_user: " .. fn.description:sub(1, 80) .. "...")
  end
end
log("ask_user in TOOLS list: " .. tostring(found))

-- 2) chat: 尝试调用 ask_user
local config = {api_key = api_key, model = model, api_url = api_url}
local messages = {{role = "user", content = "尝试调用 ask_user 工具"}}
local chat_ok, response = pcall(agent_test.chat, messages, config)
if not chat_ok then
  log("chat threw: " .. tostring(response))
elseif response.error then
  log("chat error: " .. tostring(response.error))
else
  log("finish_reason: " .. tostring(response.finish_reason))
  log("content: " .. tostring(response.content and response.content:sub(1, 500) or "(nil)"))
  if response.tool_calls and #response.tool_calls > 0 then
    log("tool_calls: " .. #response.tool_calls)
    for _, tc in ipairs(response.tool_calls) do
      local fn = tc["function"] or {}
      log("  name: " .. tostring(fn.name))
      log("  args: " .. tostring(fn.arguments))
    end
    local used = false
    for _, tc in ipairs(response.tool_calls) do
      local fn = tc["function"] or {}
      if fn.name == "ask_user" then used = true end
    end
    log("RESULT: " .. (used and "PASS" or "FAIL") .. " - ask_user declared in tool_calls")
  else
    log("tool_calls: none")
    log("RESULT: FAIL - no tool_calls at all")
  end
end
