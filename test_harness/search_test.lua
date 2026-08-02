-- search_test.lua: test web_search tool directly
local results = {}
local function flush()
  local ok, fs = pcall(require, "filesystem")
  if not ok then return end
  local ok2, iter = pcall(fs.list, "/mnt")
  if not ok2 then return end
  for item in iter do
    local f2 = io.open("/mnt/" .. item .. "/search_test.txt", "w")
    if f2 then f2:write(table.concat(results, "\n") .. "\n") f2:close() end
  end
end
local function log(...)
  local parts = {}
  for i = 1, select("#", ...) do parts[i] = tostring(select(i, ...)) end
  results[#results + 1] = table.concat(parts, " ")
  flush()
end
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
if ok then
  log("--- web_search via execute_tool ---")
  local r = execute_tool("web_search", '{"query": "opencomputers"}')
  log("result: " .. tostring(r))
end
