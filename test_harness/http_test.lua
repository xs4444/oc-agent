-- ══════════════════════════════════════════════════════
-- in-vm HTTP test: verify internet.request works in ocvm
-- ══════════════════════════════════════════════════════

local results = {}
local function log(...)
  local parts = {}
  for i = 1, select("#", ...) do
    parts[i] = tostring(select(i, ...))
  end
  results[#results + 1] = table.concat(parts, " ")
end

log("=== HTTP Test ===")

local component = require("component")
local internet_component_available = component.isAvailable("internet")
log("internet component available: " .. tostring(internet_component_available))

if internet_component_available then
  local comp = component.getPrimary("internet")
  log("internet.isHttpEnabled: " .. tostring(comp.isHttpEnabled()))
  log("internet.isTcpEnabled: " .. tostring(comp.isTcpEnabled()))
end

-- Simple GET request to httpbin
local internet = require("internet")
log("--- GET httpbin.org/ip ---")
local ok, handle = pcall(function()
  return internet.request("http://httpbin.org/ip")
end)
if not ok then
  log("request failed: " .. tostring(handle))
else
  local chunks = {}
  local iter_ok, iter_err = pcall(function()
    for chunk in handle do
      chunks[#chunks + 1] = chunk
    end
  end)
  if not iter_ok then
    log("iter failed: " .. tostring(iter_err))
  else
    local body = table.concat(chunks)
    log("body length: " .. #body)
    log("body: " .. body:sub(1, 200))
    local mt = getmetatable(handle)
    if mt and mt.__index and mt.__index.response then
      local code, msg = mt.__index.response()
      log("response code: " .. tostring(code) .. " " .. tostring(msg))
    end
  end
end

-- POST test
log("--- POST httpbin.org/post ---")
local ok2, handle2 = pcall(function()
  return internet.request("http://httpbin.org/post", "test=123", {["Content-Type"]="application/x-www-form-urlencoded"}, "POST")
end)
if not ok2 then
  log("post failed: " .. tostring(handle2))
else
  local chunks = {}
  for chunk in handle2 do
    chunks[#chunks + 1] = chunk
  end
  local body = table.concat(chunks)
  log("post body length: " .. #body)
  log("post body: " .. body:sub(1, 200))
  local mt = getmetatable(handle2)
  if mt and mt.__index and mt.__index.response then
    local code, msg = mt.__index.response()
    log("post response code: " .. tostring(code) .. " " .. tostring(msg))
  end
end

-- Write results
local fs = require("filesystem")
for item in fs.list("/mnt") do
  local f = io.open("/mnt/" .. item .. "/http_test_result.txt", "w")
  if f then
    f:write(table.concat(results, "\n") .. "\n")
    f:close()
    log("Results written to /mnt/" .. item)
  end
end
