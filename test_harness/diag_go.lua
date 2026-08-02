-- diag_go.lua: diagnose HTTP 400 from opencode-go via agent's http_post
local results = {}
local function log(...)
  local parts = {}
  for i = 1, select("#", ...) do
    parts[i] = tostring(select(i, ...))
  end
  results[#results + 1] = table.concat(parts, " ")
end

local args = {...}
local api_key = args[1]
local model = args[2] or "deepseek-v4-flash"
local api_url = args[3] or "https://opencode.ai/zen/go/v1/chat/completions"
log("key: " .. tostring(api_key and api_key:sub(1,8)))
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
_TEST_MODE = true
pcall(dofile, agent_path)
log("agent loaded")

local config = {api_key = api_key, model = model, api_url = api_url}

-- Build exactly what chat() builds
local system_prompt = agent_test.build_system_prompt()
log("system prompt len: " .. #system_prompt)

local body = json.encode({
  model = config.model,
  messages = {
    {role = "system", content = system_prompt},
    {role = "user", content = "Reply with exactly: CAPABILITY_OK"}
  },
  tools = agent_test.TOOLS,
  max_tokens = 2048,
  temperature = 0.7
})
log("body len: " .. #body)

local headers = {["Content-Type"] = "application/json"}
if config.api_key and config.api_key ~= "" and config.api_key ~= "free" then
  headers["Authorization"] = "Bearer " .. config.api_key
end

-- direct internet.request to inspect raw
local internet = require("internet")
log("--- direct internet.request ---")
local ok, handle = pcall(function()
  return internet.request(api_url, body, headers)
end)
if not ok then
  log("request error: " .. tostring(handle))
else
  local chunks = {}
  local iter_ok, iter_err = pcall(function()
    for chunk in handle do chunks[#chunks + 1] = chunk end
  end)
  log("iter ok: " .. tostring(iter_ok) .. " " .. tostring(iter_err))
  local resp = table.concat(chunks)
  log("resp len: " .. #resp)
  log("resp head: " .. resp:sub(1, 600))
  local mt = getmetatable(handle)
  if mt and mt.__index and mt.__index.response then
    for i = 1, 10 do
      local okc, c, m = pcall(mt.__index.response)
      if okc and type(c) == "number" then
        log("response(): code=" .. tostring(c) .. " msg=" .. tostring(m))
        break
      end
      os.sleep(0.3)
    end
  end
end

for item in fs.list("/mnt") do
  local f = io.open("/mnt/" .. item .. "/diag_go_result.txt", "w")
  if f then f:write(table.concat(results, "\n") .. "\n") f:close() end
end
