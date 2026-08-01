-- ══════════════════════════════════════════════════════
-- OC Mock — shim OC APIs for host-side testing
-- ══════════════════════════════════════════════════════

-- OC-like serialization (simple version)
local mock_serialization = {}
function mock_serialization.serialize(val, pretty)
  if val == nil then return "nil" end
  if type(val) == "boolean" then return tostring(val) end
  if type(val) == "number" then return tostring(val) end
  if type(val) == "string" then
    local s = val:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n"):gsub("\r", "\\r")
    return '"' .. s .. '"'
  end
  if type(val) == "table" then
    local parts = {}
    parts[#parts + 1] = "{"
    local first = true
    for k, v in pairs(val) do
      if not first then parts[#parts + 1] = "," end
      first = false
      local ks = type(k) == "string" and k or "[" .. mock_serialization.serialize(k) .. "]"
      -- numeric keys: prefer [N]= for non-sequential
      if type(k) == "number" then
        ks = "[" .. mock_serialization.serialize(k) .. "]"
      end
      -- string keys that are valid identifiers can omit brackets
      if type(k) == "string" and k:match("^[%a_][%w_]*$") then
        ks = k
      end
      parts[#parts + 1] = ks .. "=" .. mock_serialization.serialize(v, pretty)
    end
    parts[#parts + 1] = "}"
    return table.concat(parts)
  end
  error("cannot serialize " .. type(val))
end

function mock_serialization.unserialize(str)
  local fn = load("return " .. str)
  if not fn then error("unserialize: " .. tostring(fn)) end
  return fn()
end

-- OC mock environment
local OC = {
  _components = {
    ["e1e2e3e4-1234-5678-9abc-def012345678"] = "gpu",
    ["a1b2c3d4-5678-90ab-cdef-123456789abc"] = "screen",
    ["deadbeef-1234-5678-9abc-9876543210ab"] = "internet",
    ["cafe1234-5678-9abc-def0-123456789abc"] = "filesystem",
    ["babe1234-5678-9abc-def0-123456789abc"] = "redstone",
  },
  _free_mem = 524288,
  _uptime = 1234.5,
  _address = "computer-addr-001",
}

local mock_component = {}
function mock_component.list(filter)
  local filter = filter or ""
  local i = 0
  local keys = {}
  for addr, typ in pairs(OC._components) do
    if typ:find(filter, 1, true) then
      keys[#keys + 1] = addr
    end
  end
  return function()
    i = i + 1
    local addr = keys[i]
    if not addr then return nil end
    return addr, OC._components[addr]
  end
end
function mock_component.isAvailable(typ)
  for _, t in pairs(OC._components) do
    if t == typ then return true end
  end
  return false
end
function mock_component.getPrimary(typ)
  for addr, t in pairs(OC._components) do
    if t == typ then return {type = t, address = addr} end
  end
  error("no primary " .. typ)
end

local mock_computer = {}
function mock_computer.address() return OC._address end
function mock_computer.uptime() return OC._uptime end
function mock_computer.freeMemory() return OC._free_mem end
function mock_computer.totalMemory() return 1048576 end
function mock_computer.energy() return 100 end
function mock_computer.maxEnergy() return 200 end
function mock_computer.users() return end
function mock_computer.pushSignal(name, ...) end
function mock_computer.pullSignal(timeout) return nil end

local mock_filesystem = {}
-- delegate to Lua's io for testing
function mock_filesystem.exists(path)
  local f = io.open(path, "r")
  if f then f:close(); return true end
  return false
end
function mock_filesystem.list(path)
  -- minimal implementation
  local parts = {}
  local handle = io.popen('cmd /c dir /b "' .. path .. '" 2>nul')
  if handle then
    for line in handle:lines() do
      parts[#parts + 1] = line .. "/"
    end
    handle:close()
  end
  return function()
    local i = 0
    return function()
      i = i + 1
      return parts[i]
    end
  end
end
function mock_filesystem.isDirectory(path) return false end
function mock_filesystem.makeDirectory(path) return true end
function mock_filesystem.size(path) return 0 end

local mock_shell = {}
function mock_shell.execute(cmd)
  local handle = io.popen(cmd .. " 2>&1")
  if not handle then return false, "failed" end
  local result = handle:read("*a")
  handle:close()
  return true, result
end

local mock_internet = {}
function mock_internet.request(url, data, headers, method)
  -- For testing, handle file:// URLs for local testing
  if url:match("^file://") then
    local path = url:sub(8)
    local f = io.open(path, "r")
    if f then
      local content = f:read("*a")
      f:close()
      -- Return iterator-like function
      local started = false
      return function()
        if started then return nil end
        started = true
        return content
      end
    end
    error("file not found: " .. path)
  end
  error("internet.mock: cannot handle " .. url)
end

-- Register mocks globally for agent.lua to use
local M = {
  component = mock_component,
  computer = mock_computer,
  filesystem = mock_filesystem,
  shell = mock_shell,
  internet = mock_internet,
  serialization = mock_serialization,
}

return M
