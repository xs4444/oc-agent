-- ══════════════════════════════════════════════════════
-- in-vm test runner v2: auto-find agent.lua, run tests,
-- write results to /mnt/<first-mount>/test_result.txt
-- ══════════════════════════════════════════════════════

local results = {}
local function log(...)
  local parts = {}
  for i = 1, select("#", ...) do
    parts[i] = tostring(select(i, ...))
  end
  results[#results + 1] = table.concat(parts, " ")
end

log("=== OC Agent In-VM Test v2 ===")
log("Lua version: " .. _VERSION)

local fs = require("filesystem")
local component = require("component")

-- Find agent.lua: scan all mounts under /mnt
local agent_path = nil
local test_out_path = nil
for addr, typ in component.list("filesystem") do
  if typ == "filesystem" then
    local proxy = component.proxy(addr)
    local label = proxy.getLabel()
    -- list root of each fs
    local ok, list = pcall(function()
      local t = {}
      for name in proxy.list("/") do t[#t+1] = name end
      return t
    end)
    if ok then
      for _, name in ipairs(list) do
        if name:match("^agent%.lua") then
          agent_path = "/" .. name
          log("Found agent.lua on fs labeled: " .. tostring(label) .. " at /" .. name)
        end
        if name:match("^vm_test") then
          test_out_path = "/" .. name
        end
      end
    end
  end
end

-- Also check /mnt mount points
local function scan_dir(path)
  local ok, items = pcall(function()
    local t = {}
    for name in fs.list(path) do t[#t+1] = name end
    return t
  end)
  return ok and items or {}
end

for _, item in ipairs(scan_dir("/mnt")) do
  local full = "/mnt/" .. item
  for _, name in ipairs(scan_dir(full)) do
    if name:match("^agent%.lua") then
      agent_path = full .. "/agent.lua"
      log("Found agent.lua at " .. agent_path)
    end
  end
end

if not agent_path then
  log("ERROR: agent.lua not found on any mount")
  local f = io.open("/mnt/test_result.txt", "w")
  if f then f:write(table.concat(results, "\n") .. "\n") f:close() end
  return
end

-- Load agent.lua in test mode
_TEST_MODE = true
local ok, err = pcall(dofile, agent_path)
if not ok then
  log("AGENT LOAD FAILED: " .. tostring(err))
else
  log("agent.lua loaded OK from " .. agent_path)
end

-- Test JSON codec
log("--- JSON tests ---")
local function jt(label, val)
  local enc_ok, encoded = pcall(json.encode, val)
  if not enc_ok then
    log(label .. ": ENCODE FAIL " .. tostring(encoded))
    return
  end
  local dec_ok, decoded = pcall(json.decode, encoded)
  if not dec_ok then
    log(label .. ": DECODE FAIL " .. tostring(decoded) .. " (enc=" .. encoded .. ")")
    return
  end
  if type(val) == "table" or val == decoded then
    log(label .. ": OK (enc=" .. encoded .. ")")
  else
    log(label .. ": MISMATCH (enc=" .. encoded .. ", dec=" .. tostring(decoded) .. ")")
  end
end

jt("null", nil)
jt("bool true", true)
jt("int", 42)
jt("float", 3.14)
jt("string", "hello")
jt("escapes", 'a\nb\t"c"\\d')
jt("array", {1,2,3})
jt("object", {key="value", num=42})
jt("nested", {a={b={c=1}}})

-- Test decode of API-style JSON
local dec_ok, msg = pcall(json.decode, '{"role":"user","content":"hi","n":1,"arr":[1,2],"flag":true}')
if dec_ok then
  log("decode api json: OK role=" .. msg.role .. " n=" .. tostring(msg.n) .. " arr1=" .. tostring(msg.arr[1]) .. " flag=" .. tostring(msg.flag))
else
  log("decode api json: FAIL " .. tostring(msg))
end

-- Test tool execution
log("--- Tool tests ---")
local function tt(label, name, args)
  local r = execute_tool(name, args)
  log(label .. ": " .. tostring(r))
end

tt("exec_lua math", "execute_lua", '{"code":"return 2+2"}')
tt("exec_lua io", "execute_lua", '{"code":"io.write(\\"hello from lua\\")"}')
tt("exec_lua err", "execute_lua", '{"code":"error(\\"boom\\")"}')
-- v0.3.124: component_list 工具已删，改用 shell `components` 命令观察组件
tt("comp_list", "shell_execute", '{"command":"components"}')
tt("comp_list filter", "shell_execute", '{"command":"components internet"}')
tt("unknown", "unknown_tool", '{}')

-- component list full check
local comp = require("component")
local cnt = 0
for addr, typ in comp.list() do
  cnt = cnt + 1
end
log("component count: " .. cnt)

-- filesystem check
log("fs.exists /bin/ls: " .. tostring(fs.exists("/bin/ls")))

-- Write results to each mount's root via io.open
local written = false
for _, item in ipairs(scan_dir("/mnt")) do
  local f = io.open("/mnt/" .. item .. "/test_result.txt", "w")
  if f then
    f:write(table.concat(results, "\n") .. "\n")
    f:close()
    log("Results written to /mnt/" .. item)
    written = true
  end
end
if not written then
  log("WARNING: could not write results to any /mnt mount")
end
