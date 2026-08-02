-- debug_print.lua: verify print visibility in ocvm
local results = {}
local function log(...)
  local parts = {}
  for i = 1, select("#", ...) do
    parts[i] = tostring(select(i, ...))
  end
  results[#results + 1] = table.concat(parts, " ")
end

print("VISIBLE_MARKER_1")
io.write("VISIBLE_MARKER_2\n")
log("log marker 1")

-- check what io.read returns immediately
local r = io.read()
log("io.read() immediate result: " .. tostring(r) .. " (type=" .. type(r) .. ")")

-- after read, write results
local fs = require("filesystem")
for item in fs.list("/mnt") do
  local f = io.open("/mnt/" .. item .. "/debug_print_result.txt", "w")
  if f then
    f:write(table.concat(results, "\n") .. "\n")
    f:close()
  end
end
