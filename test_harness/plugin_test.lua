-- ═══════════════════════════════════════════════════════════════
-- Plugin / Modular-Split Phase 1 Tests
--
-- Verifies the tool-plugin mechanism:
--   1. a fake tool module is registered by scanning a directory and its
--      exec() is reachable through agent.execute.run()
--   2. a broken (syntax-error) module is skipped without crashing and
--      is NOT registered
--   3. execute_lua_code no longer exists in agent.lua, while the old
--      "execute_lua removed" guard message is preserved
--   4. unknown tools still return the "Unknown tool" message
-- ═══════════════════════════════════════════════════════════════

if not os.sleep then os.sleep = function() end end

-- allow requires of ../src/... (agent.tools / agent.execute)
package.path = "../src/?.lua;" .. package.path

local oc_mock = require("oc_mock")

component = oc_mock.component
computer = oc_mock.computer
filesystem = oc_mock.filesystem
shell = oc_mock.shell
internet = oc_mock.internet
serialization = oc_mock.serialization
event = oc_mock.event

package.loaded["component"] = oc_mock.component
package.loaded["computer"] = oc_mock.computer
package.loaded["filesystem"] = oc_mock.filesystem
package.loaded["shell"] = oc_mock.shell
package.loaded["internet"] = oc_mock.internet
package.loaded["serialization"] = oc_mock.serialization
package.loaded["event"] = oc_mock.event

_TEST_MODE = true

local pass, fail = 0, 0
local function test(label, cond, detail)
  if cond then
    pass = pass + 1
    print("  ✓ " .. label)
  else
    fail = fail + 1
    print("  ✗ " .. label)
    if detail then print("    " .. tostring(detail)) end
  end
end

-- Load the agent entry (Phase 3: multi-file mode = src/agent/init.lua).
-- This registers the 6 real tool modules through agent.tools and defines
-- the global json table.
local ok_load, load_err = pcall(dofile, "../src/agent/init.lua")
test("agent.lua loads", ok_load, tostring(load_err))
if not ok_load then os.exit(1) end

local tools = require("agent.tools")
local execute = require("agent.execute")

-- ══ 1. Fake tool module registered via directory scan ══
local tmp = "plugin_test_tmp"
os.execute("mkdir " .. tmp .. "\\agent\\tools 2>nul")

local hello_path = tmp .. "/agent/tools/hello.lua"
local hf = io.open(hello_path, "w")
hf:write([[
-- hello tool: written by plugin_test to verify plugin registration
return {
  tools = {
    {type = "function", ["function"] = {
      name = "hello",
      description = "Say hello",
      parameters = {type = "object", properties = {name = {type = "string"}}},
    }},
  },
  exec = function(name, args, deps)
    if name ~= "hello" then return nil end
    return "Hello, " .. tostring(args.name or "world") .. "!"
  end,
}
]])
hf:close()

-- make require("agent.tools.hello") resolve to the temp dir
package.path = tmp .. "/?.lua;" .. package.path

-- scan with an explicit name list (deterministic, independent of fs.list)
tools.scan_dir(tmp .. "/agent/tools", {"hello.lua"})

local hello_decl
for _, t in ipairs(tools.list()) do
  if t["function"].name == "hello" then hello_decl = t end
end
test("scan registers hello tool declaration", hello_decl ~= nil)

local hello_result = execute.run("hello", '{"name":"tester"}', {json = json})
test("execute.run dispatches to hello module", hello_result == "Hello, tester!",
  "got: " .. tostring(hello_result))

local hello_nil = execute.run("hello", "{}", {json = json})
test("hello default arg", hello_nil == "Hello, world!",
  "got: " .. tostring(hello_nil))

-- the scan also works through the real filesystem enumeration path
local listed_names = nil
local ok_scan2 = pcall(function()
  listed_names = {}
  local fs = require("filesystem")
  for entry in fs.list(tmp .. "/agent/tools") do
    listed_names[#listed_names + 1] = entry
  end
end)
test("fs.list enumeration works", ok_scan2 and type(listed_names) == "table"
  and #listed_names >= 1, "got: " .. tostring(listed_names and #listed_names))

-- ══ 2. Broken module is skipped, not registered ══
local bad_path = tmp .. "/agent/tools/hello_bad.lua"
local bf = io.open(bad_path, "w")
bf:write("return { this is not valid lua !!!\n")
bf:close()
package.loaded["agent.tools.hello_bad"] = nil

local ok_scan_bad = pcall(tools.scan_dir, tmp .. "/agent/tools", {"hello_bad.lua"})
test("bad module does not crash scan", ok_scan_bad)

local bad_present = false
for _, t in ipairs(tools.list()) do
  if t["function"].name == "hello_bad" then bad_present = true end
end
test("bad module is not registered", not bad_present)

-- hello module still registered after the bad one was skipped
local hello_still = false
for _, t in ipairs(tools.list()) do
  if t["function"].name == "hello" then hello_still = true end
end
test("good module survives bad scan", hello_still)

-- ══ 3. execute_lua_code removed from the entry script ══
local af = io.open("../src/agent/init.lua", "r")
local agent_src = af:read("*a")
af:close()
test("execute_lua_code absent from agent.lua", not agent_src:find("execute_lua_code"))

-- the removed-tool guard is preserved (run_tests compat)
local guard_res = execute.run("execute_lua", '{"code":"return 1"}', {json = json})
test("execute_lua still blocked with removed message",
  type(guard_res) == "string" and guard_res:find("removed") ~= nil,
  "got: " .. tostring(guard_res))

-- ══ 4. unknown tool message ══
local unk = execute.run("no_such_tool", "{}", {json = json})
test("unknown tool message", type(unk) == "string" and unk:find("Unknown tool") ~= nil,
  "got: " .. tostring(unk))

-- sloppy JSON that fails to decode still returns the parse-error message
-- (same behavior as the original execute_tool)
local parse_err = execute.run("calc", "{expression: '2+2'}", {json = json})
test("invalid JSON returns parse error",
  type(parse_err) == "string" and parse_err:find("Error parsing arguments") ~= nil,
  "got: " .. tostring(parse_err))

-- cleanup
os.remove(hello_path)
os.remove(bad_path)
os.execute("rmdir " .. tmp .. "\\agent\\tools 2>nul")
os.execute("rmdir " .. tmp .. "\\agent 2>nul")
os.execute("rmdir " .. tmp .. " 2>nul")

print("")
print(string.format("PLUGIN TESTS: %d pass, %d fail out of %d", pass, fail, pass + fail))
os.exit(fail > 0 and 1 or 0)
