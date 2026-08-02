-- ══════════════════════════════════════════════════════
-- OC Agent Test Runner
-- Loads agent.lua with OC mock and runs unit tests
-- ══════════════════════════════════════════════════════

local oc_mock = require("oc_mock")

-- Override globals that agent.lua expects
component = oc_mock.component
computer = oc_mock.computer
filesystem = oc_mock.filesystem
shell = oc_mock.shell
internet = oc_mock.internet
serialization = oc_mock.serialization

-- Intercept require() to return mocked OC modules
local orig_require = require
package.loaded["component"] = oc_mock.component
package.loaded["computer"] = oc_mock.computer
package.loaded["filesystem"] = oc_mock.filesystem
package.loaded["shell"] = oc_mock.shell
package.loaded["internet"] = oc_mock.internet
package.loaded["serialization"] = oc_mock.serialization

-- Prevent main() from auto-running
_TEST_MODE = true

-- Load the agent
local agent_path = arg and arg[1] or "../agent.lua"
print("Loading agent.lua from " .. agent_path .. "...")
local ok, err = pcall(dofile, agent_path)
if not ok then
  print("AGENT LOAD FAILED:")
  print(err)
  os.exit(1)
end
print("agent.lua loaded (this is expected — main() will fail without internet card mock)")
print("")

-- Now test individual modules
print("═══════════════════════════════════════")
print("JSON Codec Tests")
print("═══════════════════════════════════════")

local pass = 0
local fail = 0

local function test_encode(label, input, expected)
  local result = json.encode(input)
  if result == expected then
    pass = pass + 1
    print("  ✓ " .. label)
  else
    fail = fail + 1
    print("  ✗ " .. label)
    print("    expected: " .. tostring(expected))
    print("    got:      " .. tostring(result))
  end
end

local function test_decode(label, input, validator)
  local ok, result = pcall(json.decode, input)
  if not ok then
    fail = fail + 1
    print("  ✗ " .. label .. " (decode threw: " .. tostring(result) .. ")")
    return
  end
  local match = validator(result)
  if match then
    pass = pass + 1
    print("  ✓ " .. label)
  else
    fail = fail + 1
    print("  ✗ " .. label)
    print("    got: " .. tostring(result))
  end
end

local function test_roundtrip(label, value)
  local encoded = json.encode(value)
  local ok, decoded = pcall(json.decode, encoded)
  if not ok then
    fail = fail + 1
    print("  ✗ " .. label .. " (decode failed: " .. tostring(decoded) .. ")")
    return
  end
  if type(value) == "table" and type(decoded) == "table" then
    -- deep compare
    local function deep_eq(a, b)
      if type(a) ~= type(b) then return false end
      if type(a) ~= "table" then return a == b end
      local ka = {}; for k in pairs(a) do ka[#ka+1] = k end
      local kb = {}; for k in pairs(b) do kb[#kb+1] = k end
      if #ka ~= #kb then return false end
      for _, k in ipairs(ka) do
        if not deep_eq(a[k], b[k]) then return false end
      end
      return true
    end
    if deep_eq(value, decoded) then
      pass = pass + 1; print("  ✓ " .. label)
    else
      fail = fail + 1
      print("  ✗ " .. label)
      print("    original: " .. json.encode(value, true))
      print("    decoded:  " .. json.encode(decoded, true))
    end
  elseif value == decoded then
    pass = pass + 1; print("  ✓ " .. label)
  else
    fail = fail + 1
    print("  ✗ " .. label)
    print("    original: " .. tostring(value))
    print("    decoded:  " .. tostring(decoded))
  end
end

-- Basic types
test_roundtrip("null", nil)
test_roundtrip("true", true)
test_roundtrip("false", false)
test_roundtrip("integer", 42)
test_roundtrip("negative", -17)
test_roundtrip("float", 3.14)
test_roundtrip("string", "hello")
test_roundtrip("empty string", "")
test_roundtrip("string with escapes", 'hello\nworld\t"quoted"\\backslash')

-- Arrays
test_roundtrip("empty array", {})
test_roundtrip("number array", {1, 2, 3})
test_decode("simple array", "[1,2,3]", function(r)
  return type(r) == "table" and r[1] == 1 and r[2] == 2 and r[3] == 3
end)
test_decode("mixed types", '[1,"two",false,null]', function(r)
  return r[1] == 1 and r[2] == "two" and r[3] == false and r[4] == nil
end)

-- Objects
test_roundtrip("empty object", {})
test_roundtrip("simple object", {key="value", num=42})
test_decode("nested object", '{"a":{"b":"c"}}', function(r)
  return r.a and r.a.b == "c"
end)

-- Edge cases
test_roundtrip("special chars", "tab\there and newline\nhere")
test_roundtrip("unicode", "\u{00e4}\u{00f6}\u{00fc}")
test_decode("unicode escape", '"\\u0048\\u0069"', function(r) return r == "Hi" end)

-- Large numbers
test_roundtrip("large number", 999999999)

-- Encode specific formats
test_encode("null value", nil, "null")
test_encode("boolean true", true, "true")
test_encode("boolean false", false, "false")
test_encode("number", 42, "42")
test_encode("simple array", {1, 2, 3}, "[1,2,3]")
-- Object key order depends on Lua table iteration (not deterministic)
local obj_result = json.encode({a=1, b="x"})
if obj_result:match('"a":1') and obj_result:match('"b":"x"') and obj_result:match('^{.*}$') then
  pass = pass + 1; print("  ✓ object keys check")
else
  fail = fail + 1; print("  ✗ object keys check: " .. tostring(obj_result))
end

print("")
print(string.format("JSON tests: %d pass, %d fail", pass, fail))

-- Check if total tests match
local total_tests = 26
if pass + fail ~= total_tests then
  print(string.format("WARNING: ran %d tests, expected %d", pass + fail, total_tests))
else
  print(string.format("Total: %d/%d passed", pass, total_tests))
end

-- Test tool execution (if execute_tool was loaded)
print("")
print("═══════════════════════════════════════")
print("Tool Execution Tests")
print("═══════════════════════════════════════")

local function test_tool(label, name, args, expected_check)
  local result = execute_tool(name, args)
  local ok = expected_check(result)
  if ok then
    pass = pass + 1; print("  ✓ " .. label)
  else
    fail = fail + 1
    print("  ✗ " .. label)
    print("    result: " .. tostring(result):sub(1, 200))
  end
end

test_tool("execute_lua simple", "execute_lua", '{"code":"return 2+2"}',
  function(r) return r:find("=> 4") ~= nil end)

test_tool("execute_lua string", "execute_lua", '{"code":"return \\\"hello\\\""}',
  function(r) return r:find("hello") ~= nil end)

test_tool("execute_lua table", "execute_lua", '{"code":"return {1,2,3}"}',
  function(r) return r:find("table") ~= nil or r:find("=>") ~= nil end)

test_tool("execute_lua compile error", "execute_lua", '{"code":"bad syntax !!!"}',
  function(r) return r:find("Compile error") ~= nil end)

test_tool("execute_lua runtime error", "execute_lua", '{"code":"error(\\\"boom\\\")"}',
  function(r) return r:find("Runtime error") ~= nil end)

test_tool("execute_lua stdout capture", "execute_lua", '{"code":"io.write(\\\"hello world\\\")"}',
  function(r) return r:find("hello world") ~= nil end)

test_tool("component_list no filter", "component_list", '{}',
  function(r) return type(r) == "string" and #r > 0 end)

test_tool("component_list filtered", "component_list", '{"filter":"internet"}',
  function(r) return r:find("internet") ~= nil end)

test_tool("component_list no match", "component_list", '{"filter":"xyzzy"}',
  function(r) return r:find("no components") ~= nil end)

test_tool("unknown tool", "unknown_tool", '{}',
  function(r) return r:find("Unknown tool") ~= nil end)

-- web_search tests (HN Algolia fallback, no tavily key configured)
test_tool("web_search hn", "web_search", '{"query":"gtnh"}',
  function(r) return r:find("Result 1 for gtnh") ~= nil and r:find("example.com/1") ~= nil end)
test_tool("web_search limit", "web_search", '{"query":"lua","limit":1}',
  function(r) return r:find("Result 1 for lua") ~= nil and not r:find("Result 2") end)
test_tool("web_search empty query", "web_search", '{"query":""}',
  function(r) return r:find("query is required") ~= nil end)

-- component_doc tests
test_tool("component_doc list methods", "component_doc", '{"address":"babe1234"}',
  function(r) return r:find("getInput") ~= nil and r:find("Type: redstone") ~= nil end)
test_tool("component_doc single method", "component_doc", '{"address":"babe1234","method":"setOutput"}',
  function(r) return r:find("setOutput") ~= nil end)
test_tool("component_doc unknown addr", "component_doc", '{"address":"zzzz"}',
  function(r) return r:find("unknown component") ~= nil end)

-- component_invoke tests
test_tool("component_invoke redstone", "component_invoke", '{"address":"babe1234","method":"getInput","args":[0]}',
  function(r) return r == "15" end)
test_tool("component_invoke gpu", "component_invoke", '{"address":"e1e2e3e4","method":"getResolution"}',
  function(r) return r == "80\n25" end)
test_tool("component_invoke unknown", "component_invoke", '{"address":"zzzz","method":"ping"}',
  function(r) return r:find("unknown component") ~= nil end)

-- Test write_file + read_file roundtrip
local fpath = "test_agent_temp.txt"
test_tool("write_file", "write_file", json.encode({path=fpath, content="test content 123"}),
  function(r) return r:find("Written") ~= nil end)

test_tool("read_file", "read_file", json.encode({path=fpath}),
  function(r) return r == "test content 123" end)

-- Cleanup
os.remove(fpath)

test_tool("read_file not found", "read_file", '{"path":"/nonexistent/file.txt"}',
  function(r) return r:find("not found") ~= nil end)

print("")
print("═══════════════════════════════════════")
print(string.format("FINAL: %d pass, %d fail out of %d tests", pass, fail, pass + fail))
print("═══════════════════════════════════════")

os.exit(fail > 0 and 1 or 0)
