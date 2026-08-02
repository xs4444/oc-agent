-- ══════════════════════════════════════════════════════
-- OC Agent Test Runner
-- Loads agent.lua with OC mock and runs unit tests
-- ══════════════════════════════════════════════════════

-- Lua 5.4 has no os.sleep; OC's OpenOS provides it. No-op fallback for tests.
if not os.sleep then os.sleep = function() end end

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

test_tool("json_query scalar", "json_query", '{"json":"{\\"name\\":\\"oc\\",\\"count\\":3}","path":"name"}',
  function(r) return r == "oc" end)

test_tool("json_query nested", "json_query", '{"json":"{\\"data\\":{\\"items\\":[{\\"title\\":\\"a\\"},{\\"title\\":\\"b\\"}]}}","path":"data.items.1.title"}',
  function(r) return r == "b" end)

test_tool("json_query object", "json_query", '{"json":"{\\"user\\":{\\"id\\":7,\\"name\\":\\"x\\"}}","path":"user"}',
  function(r) return r:find('"id":7') ~= nil and r:find('"name":"x"') ~= nil end)

test_tool("json_query invalid json", "json_query", '{"json":"not json","path":"a"}',
  function(r) return r:find("invalid JSON") ~= nil end)

test_tool("json_query missing path", "json_query", '{"json":"{\\"a\\":1}","path":"b.c"}',
  function(r) return r:find("not found") ~= nil end)

test_tool("json_query missing arg", "json_query", '{"path":"a"}',
  function(r) return r:find("must be a string") ~= nil end)

test_tool("calc basic", "calc", '{"expression":"2+3*4"}',
  function(r) return r == "14" end)

test_tool("calc parens", "calc", '{"expression":"(2+3)*4"}',
  function(r) return r == "20" end)

test_tool("calc power", "calc", '{"expression":"2^10"}',
  function(r) return r == "1024" end)

test_tool("calc funcs", "calc", '{"expression":"sqrt(16)+floor(3.7)"}',
  function(r) return r == "7" end)

test_tool("calc minmax", "calc", '{"expression":"min(3,7)+max(1,9)"}',
  function(r) return r == "12" end)

test_tool("calc invalid", "calc", '{"expression":"2+*"}',
  function(r) return r:find("invalid expression") ~= nil end)

test_tool("calc unknown func", "calc", '{"expression":"evil(1)"}',
  function(r) return r:find("invalid expression") ~= nil or r:find("unknown function") ~= nil end)

test_tool("text_ops upper", "text_ops", '{"op":"upper","text":"hello"}',
  function(r) return r == "HELLO" end)

test_tool("text_ops length", "text_ops", '{"op":"length","text":"hello"}',
  function(r) return r == "5" end)

test_tool("text_ops trim", "text_ops", '{"op":"trim","text":"  hi  "}',
  function(r) return r == "hi" end)

test_tool("text_ops find", "text_ops", '{"op":"find","text":"hello world","arg1":"world"}',
  function(r) return r:find("found at 7") ~= nil end)

test_tool("text_ops replace", "text_ops", '{"op":"replace","text":"a-b-c","arg1":"-","arg2":"+"}',
  function(r) return r == "a+b+c" end)

test_tool("text_ops slice", "text_ops", '{"op":"slice","text":"hello world","arg1":"7","arg2":"5"}',
  function(r) return r == "world" end)

test_tool("text_ops split", "text_ops", '{"op":"split","text":"a\\nb\\nc"}',
  function(r) return r:find("1%. a") ~= nil and r:find("2%. b") ~= nil and r:find("3%. c") ~= nil end)

test_tool("text_ops unknown op", "text_ops", '{"op":"bogus","text":"x"}',
  function(r) return r:find("unknown op") ~= nil end)

test_tool("execute_lua removed", "execute_lua", '{"code":"return 1"}',
  function(r) return r:find("removed") ~= nil end)

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

-- Multi-line file for line-slice tests
local mpath = "test_lines_temp.txt"
local ml = {}
for i = 1, 10 do ml[i] = "line " .. i end
test_tool("write multi-line", "write_file", json.encode({path=mpath, content=table.concat(ml, "\n")}),
  function(r) return r:find("Written") ~= nil end)

test_tool("read_file offset", "read_file", json.encode({path=mpath, offset=3}),
  function(r) return r:find("^3%. line 3") ~= nil and r:find("10%. line 10") ~= nil and r:find("line 2") == nil end)

test_tool("read_file offset+limit", "read_file", json.encode({path=mpath, offset=2, limit=3}),
  function(r) return r:find("2%. line 2") ~= nil and r:find("4%. line 4") ~= nil and r:find("line 5") == nil end)

test_tool("read_file tail", "read_file", json.encode({path=mpath, offset=-3}),
  function(r) return r:find("8%. line 8") ~= nil and r:find("10%. line 10") ~= nil and r:find("line 7") == nil end)

test_tool("read_file tail beyond", "read_file", json.encode({path=mpath, offset=-100}),
  function(r) return r:find("1%. line 1") ~= nil end)

test_tool("read_file offset beyond eof", "read_file", json.encode({path=mpath, offset=100}),
  function(r) return r:find("no lines") ~= nil end)

test_tool("read_file whole still works", "read_file", json.encode({path=mpath}),
  function(r) return r == table.concat(ml, "\n") end)

-- edit_file tests
test_tool("edit_file replace", "edit_file", json.encode({path=fpath, old_string="test content", new_string="EDITED content"}),
  function(r) return r:find("Replaced 1") ~= nil end)
test_tool("edit_file applied", "read_file", json.encode({path=fpath}),
  function(r) return r == "EDITED content 123" end)
test_tool("edit_file not found", "edit_file", json.encode({path=fpath, old_string="zzz", new_string="x"}),
  function(r) return r:find("not found") ~= nil end)
test_tool("edit_file multi no replace_all", "edit_file", json.encode({path=mpath, old_string="line", new_string="row"}),
  function(r) return r:find("10 times") ~= nil end)
test_tool("edit_file replace_all", "edit_file", json.encode({path=mpath, old_string="line", new_string="row", replace_all=true}),
  function(r) return r:find("Replaced 10") ~= nil end)
test_tool("edit_file replace_all applied", "read_file", json.encode({path=mpath}),
  function(r) return r:find("row 1") ~= nil and r:find("row 10") ~= nil and r:find("line 1") == nil end)
test_tool("edit_file empty old", "edit_file", json.encode({path=fpath, old_string="", new_string="x"}),
  function(r) return r:find("non%-empty") ~= nil end)

-- append_file tests
test_tool("append_file", "append_file", json.encode({path=fpath, content=" +appended"}),
  function(r) return r:find("Appended") ~= nil end)
test_tool("append_file applied", "read_file", json.encode({path=fpath}),
  function(r) return r == "EDITED content 123 +appended" end)
test_tool("append_file creates new", "append_file", json.encode({path="test_new_append.txt", content="hello"}),
  function(r) return r:find("Appended") ~= nil end)
test_tool("append_file new file content", "read_file", json.encode({path="test_new_append.txt"}),
  function(r) return r == "hello" end)

-- Cleanup
os.remove(fpath)
os.remove(mpath)
os.remove("test_new_append.txt")

test_tool("read_file not found", "read_file", '{"path":"/nonexistent/file.txt"}',
  function(r) return r:find("not found") ~= nil end)

print("")
print("═══════════════════════════════════════")
print("Compaction / System Prompt Tests")
print("═══════════════════════════════════════")

-- Test hooks
local compact_history = agent_test.compact_history
local should_compact = agent_test.should_compact
local summarize_history = agent_test.summarize_history
local http_post = agent_test.http_post
local build_system_prompt = agent_test.build_system_prompt

local function test(label, cond, detail)
  if cond then
    pass = pass + 1; print("  ✓ " .. label)
  else
    fail = fail + 1
    print("  ✗ " .. label)
    if detail then print("    " .. tostring(detail)) end
  end
end

-- http_post with mock chat/completions endpoint
local code, resp, err = http_post("https://mock/chat/completions",
  {["Content-Type"] = "application/json"}, '{"messages":[]}')
test("http_post mock 200", code == 200 and type(resp) == "string" and not err,
  "code=" .. tostring(code) .. " err=" .. tostring(err))

-- summarize_history via mock
local msgs = {
  {role = "user", content = "how much memory?"},
  {role = "assistant", content = "2MB limit"},
  {role = "user", content = "any leak?"},
}
local summary = summarize_history(msgs, {model = "m", api_key = ""})
test("summarize_history returns summary", type(summary) == "string" and #summary > 10,
  "summary=" .. tostring(summary))

-- compact_history: many messages → summary + last KEEP verbatim
local big = {}
for i = 1, 30 do
  big[#big + 1] = {role = "user", content = "message number " .. i}
end
local compacted = compact_history(big, {model = "m", api_key = ""})
test("compact_history succeeds", compacted ~= nil, "compacted=nil")
if compacted then
  test("compact adds summary prefix", compacted[1].role == "system"
    and tostring(compacted[1].content):find("对话摘要") ~= nil)
  test("compact keeps last messages", compacted[#compacted].content == "message number 30"
    and compacted[#compacted - 1].content == "message number 29")
  test("compact shrinks count", #compacted <= 6)
end

-- should_compact trigger thresholds
test("should_compact true when many messages",
  should_compact({{role="u",content="x"},{role="u",content="y"},{role="u",content="z"},
    {role="u",content="w"},{role="u",content="v"},{role="u",content="q"},
    {role="u",content="a"},{role="u",content="b"},{role="u",content="c"},
    {role="u",content="d"},{role="u",content="e"},{role="u",content="f"},
    {role="u",content="g"},{role="u",content="h"},{role="u",content="i"},{role="u",content="j"},
    {role="u",content="k"},{role="u",content="l"}}))
test("should_compact false when short",
  not should_compact({{role="u", content="x"}}))
test("should_compact false when big bytes but few messages",
  not should_compact({{role="u", content=string.rep("a", 45000)}}))

-- compact_history returns nil when nothing to compact
test("compact_history nil on tiny history", compact_history({{role="u", content="x"}}, {}) == nil)

-- system prompt no longer mentions execute_lua; mentions new tools
local sp = build_system_prompt()
test("system prompt has json_query", sp:find("json_query") ~= nil)
test("system prompt has calc", sp:find("calc") ~= nil)
test("system prompt has text_ops", sp:find("text_ops") ~= nil)
test("system prompt no execute_lua", sp:find("execute_lua") == nil)

-- TOOLS list: execute_lua removed, new tools present
local tools_have = {}
for _, t in ipairs(agent_test.TOOLS) do
  tools_have[t["function"].name] = true
end
test("TOOLS has json_query", tools_have["json_query"] == true)
test("TOOLS has calc", tools_have["calc"] == true)
test("TOOLS has text_ops", tools_have["text_ops"] == true)
test("TOOLS no execute_lua", tools_have["execute_lua"] ~= true)
test("TOOLS has edit_file", tools_have["edit_file"] == true)
test("TOOLS has append_file", tools_have["append_file"] == true)
test("TOOLS count is 13", #agent_test.TOOLS == 13,
  "count=" .. tostring(#agent_test.TOOLS))

print("")
print("═══════════════════════════════════════")
print("Append-only Session Log Tests")
print("═══════════════════════════════════════")

-- Session log: append single messages, replay via load_history, legacy migrate
local hist_path = "test_history_temp.txt"
local append_history = agent_test.append_history
local load_history = agent_test.load_history
local rebuild_history = agent_test.rebuild_history

-- Redirect history storage to a local file for real round-trip testing
os.remove(hist_path)
agent_test.set_history_path(hist_path)

-- append-only: three messages appended one at a time
append_history({role = "user", content = "hello"})
append_history({role = "assistant", content = "hi there"})
append_history({role = "tool", tool_call_id = "x", content = "result"})

local replayed = load_history()
test("replay: 3 messages", #replayed == 3, "#=" .. tostring(#replayed))
if #replayed == 3 then
  test("replay msg1", replayed[1].role == "user" and replayed[1].content == "hello")
  test("replay msg2", replayed[2].role == "assistant" and replayed[2].content == "hi there")
  test("replay msg3", replayed[3].role == "tool" and replayed[3].tool_call_id == "x")
end

-- rebuild (compaction path): full rewrite shrinks the log
rebuild_history({{role = "system", content = "[摘要] s"}, {role = "user", content = "q"}})
local r2 = load_history()
test("rebuild: 2 messages", #r2 == 2)
test("rebuild content", r2[1].role == "system" and r2[2].content == "q")

-- legacy format migration: serialize() whole-table file → JSON lines
local ser = require("serialization")
local legacy = "test_legacy_temp.txt"
local lf = io.open(legacy, "w")
lf:write(ser.serialize({{role = "user", content = "old1"}, {role = "user", content = "old2"}}))
lf:close()
agent_test.set_history_path(legacy)
local r3 = load_history()
test("legacy migrate: 2 messages", #r3 == 2 and r3[1].content == "old1" and r3[2].content == "old2")
local migrated = io.open(legacy, "r")
local migrated_content = migrated:read("*a")
migrated:close()
test("legacy migrated to JSON lines", migrated_content:find('"role"') ~= nil and migrated_content:find("%[") == nil)
os.remove(legacy)

-- corrupt line tolerance
local corrupt = "test_corrupt_temp.txt"
local cf = io.open(corrupt, "w")
cf:write('{"role":"user","content":"ok"}\nTHIS IS NOT JSON\n{"role":"assistant","content":"also ok"}\n')
cf:close()
agent_test.set_history_path(corrupt)
local r4 = load_history()
test("corrupt line skipped", #r4 == 2 and r4[1].content == "ok" and r4[2].content == "also ok",
  "#=" .. tostring(#r4))
os.remove(corrupt)

-- empty file → empty history
local emptyf = "test_empty_temp.txt"
local ef = io.open(emptyf, "w"); ef:close()
agent_test.set_history_path(emptyf)
test("empty file → empty history", #load_history() == 0)
os.remove(emptyf)

os.remove(hist_path)

print("")
print("═══════════════════════════════════════")
print(string.format("FINAL: %d pass, %d fail out of %d tests", pass, fail, pass + fail))
print("═══════════════════════════════════════")

os.exit(fail > 0 and 1 or 0)
