-- test_main.lua: load agent.lua with main() active, capture any error
local results = {}
local function log(...)
  local parts = {}
  for i = 1, select("#", ...) do
    parts[i] = tostring(select(i, ...))
  end
  results[#results + 1] = table.concat(parts, " ")
end

log("=== main() test ===")
local ok, err = pcall(dofile, "/mnt/2c2/agent.lua")
if not ok then
  log("ERROR from main: " .. tostring(err))
  log(debug.traceback and debug.traceback(err, 2) or "no traceback")
else
  log("main() returned without error")
end

local fs = require("filesystem")
for item in fs.list("/mnt") do
  local f = io.open("/mnt/" .. item .. "/test_main_result.txt", "w")
  if f then
    f:write(table.concat(results, "\n") .. "\n")
    f:close()
  end
end
