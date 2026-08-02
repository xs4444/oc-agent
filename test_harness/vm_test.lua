-- ══════════════════════════════════════════════════════
-- in-vm test runner: loads agent.lua, runs unit tests,
-- writes results to /mnt/test_result.txt
-- ══════════════════════════════════════════════════════

local results = {}
local function log(...)
  local parts = {}
  for i = 1, select("#", ...) do
    parts[i] = tostring(select(i, ...))
  end
  results[#results + 1] = table.concat(parts, " ")
end

log("=== OC Agent In-VM Test ===")
log("Lua version: " .. _VERSION)

-- Load agent.lua in test mode (skips main())
_TEST_MODE = true
local ok, err = pcall(dofile, "/mnt/agent.lua")
if not ok then
  log("AGENT LOAD FAILED: " .. tostring(err))
else
  log("agent.lua loaded OK")
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
  if type(val) == "table" then
    log(label .. ": OK (enc=" .. encoded .. ")")
  elseif val == decoded then
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
tt("comp_list", "component_list", '{}')
tt("comp_list filter", "component_list", '{"filter":"internet"}')
tt("unknown", "unknown_tool", '{}')

-- component list full check
local comp = require("component")
local cnt = 0
for addr, typ in comp.list() do
  cnt = cnt + 1
end
log("component count: " .. cnt)

-- filesystem check
local fs = require("filesystem")
log("fs.exists /mnt/agent.lua: " .. tostring(fs.exists("/mnt/agent.lua")))
log("fs.exists /bin/ls: " .. tostring(fs.exists("/bin/ls")))

-- Write results
local f = io.open("/mnt/test_result.txt", "w")
if f then
  f:write(table.concat(results, "\n") .. "\n")
  f:close()
  log("Results written to /mnt/test_result.txt")
else
  log("ERROR: could not write /mnt/test_result.txt")
  -- try /home
  local f2 = io.open("/home/test_result.txt", "w")
  if f2 then
    f2:write(table.concat(results, "\n") .. "\n")
    f2:close()
    log("Results written to /home/test_result.txt")
  end
end
