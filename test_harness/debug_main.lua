-- debug_main.lua: step-by-step probe of agent main() path
local results = {}
local function log(...)
  local parts = {}
  for i = 1, select("#", ...) do
    parts[i] = tostring(select(i, ...))
  end
  results[#results + 1] = table.concat(parts, " ")
end

log("=== debug main path ===")
log("_VERSION: " .. tostring(_VERSION))

-- 1. component
local ok1, comp = pcall(require, "component")
log("require(component): ok=" .. tostring(ok1) .. " type=" .. type(comp))
if ok1 and comp then
  log("  component.isAvailable: " .. type(comp.isAvailable))
  log("  component.list: " .. type(comp.list))
  local ok_avail, avail = pcall(comp.isAvailable, "internet")
  log("  isAvailable(internet): ok=" .. tostring(ok_avail) .. " val=" .. tostring(avail))
end

-- 2. filesystem / config path
local ok2, fs = pcall(require, "filesystem")
log("require(filesystem): ok=" .. tostring(ok2) .. " type=" .. type(fs))
if ok2 and fs then
  local ok_ex, exists = pcall(fs.exists, "/home/agent_config.txt")
  log("  fs.exists(/home/agent_config.txt): " .. tostring(exists))
  local ok_ex2, exists2 = pcall(fs.exists, "/mnt/2c2/agent_config.txt")
  log("  fs.exists(/mnt/2c2/agent_config.txt): " .. tostring(exists2))
end

-- 3. serialization
local ok3, ser = pcall(require, "serialization")
log("require(serialization): ok=" .. tostring(ok3) .. " type=" .. type(ser))
if ok3 and ser then
  log("  ser.serialize: " .. type(ser.serialize))
  log("  ser.unserialize: " .. type(ser.unserialize))
  local ok_ser, s = pcall(ser.serialize, {a=1, b="x"})
  log("  serialize({a=1,b=x}): " .. tostring(s))
end

-- 4. io behavior
log("io.read type: " .. type(io.read))
log("io.write type: " .. type(io.write))
log("io.stdout type: " .. type(io.stdout))

-- 5. print behavior
log("print is function: " .. tostring(type(print) == "function"))

-- write results
local fs2 = require("filesystem")
for item in fs2.list("/mnt") do
  local f = io.open("/mnt/" .. item .. "/debug_main_result.txt", "w")
  if f then
    f:write(table.concat(results, "\n") .. "\n")
    f:close()
  end
end
