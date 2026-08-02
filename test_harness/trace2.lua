-- trace2.lua: get full traceback for build_system_prompt
local results = {}
local function log(...)
  local parts = {}
  for i = 1, select("#", ...) do
    parts[i] = tostring(select(i, ...))
  end
  results[#results + 1] = table.concat(parts, " ")
end

log("=== trace2 ===")
_TEST_MODE = true
local ok, err = pcall(dofile, "/mnt/2c2/agent.lua")
log("agent load: " .. tostring(ok) .. " " .. tostring(err))

-- probe computer API directly
local comp = require("computer")
log("computer type: " .. type(comp))
if type(comp) == "table" then
  log("computer.address: " .. type(comp.address))
  log("computer.uptime: " .. type(comp.uptime))
  log("computer.freeMemory: " .. type(comp.freeMemory))
end

local component = require("component")
log("component type: " .. type(component))
log("component.list: " .. type(component.list))

-- call build_system_prompt with full traceback
local fn, cerr = load("return build_system_prompt()")
if not fn then
  log("load build_system_prompt: " .. tostring(cerr))
else
  local ok2, r2 = xpcall(fn, debug.traceback)
  if ok2 then
    log("build_system_prompt OK, len=" .. #r2)
  else
    log("build_system_prompt FAIL:")
    log(tostring(r2))
  end
end

local fs = require("filesystem")
for item in fs.list("/mnt") do
  local f = io.open("/mnt/" .. item .. "/trace2_result.txt", "w")
  if f then f:write(table.concat(results, "\n") .. "\n") f:close() end
end
