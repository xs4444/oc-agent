-- debug_io.lua: test io.read behavior in ocvm
local results = {}
local function log(...)
  local parts = {}
  for i = 1, select("#", ...) do
    parts[i] = tostring(select(i, ...))
  end
  results[#results + 1] = table.concat(parts, " ")
end

log("=== io.read test ===")
log("_VERSION: " .. _VERSION)

-- Try reading with timeout approach: check what io.read returns
local ok, r1 = pcall(function()
  return io.read()
end)
log("io.read() pcall: ok=" .. tostring(ok) .. " result=" .. tostring(r1))

if ok and r1 ~= nil then
  log("io.read() returned: " .. tostring(r1))
end

-- try io.stdin:read
local ok2, r2 = pcall(function()
  return io.stdin:read()
end)
log("io.stdin:read() pcall: ok=" .. tostring(ok2) .. " result=" .. tostring(r2))

-- term.read
local ok3, r3 = pcall(function()
  return term.read()
end)
log("term.read() pcall: ok=" .. tostring(ok3) .. " result=" .. tostring(r3))

-- event pull with short timeout
local ok4, r4 = pcall(function()
  local event = require("event")
  return event.pull(2)
end)
log("event.pull(2): ok=" .. tostring(ok4) .. " result=" .. tostring(r4))

local fs = require("filesystem")
for item in fs.list("/mnt") do
  local f = io.open("/mnt/" .. item .. "/debug_io_result.txt", "w")
  if f then
    f:write(table.concat(results, "\n") .. "\n")
    f:close()
  end
end
