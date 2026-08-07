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
event = oc_mock.event

-- Intercept require() to return mocked OC modules
local orig_require = require
package.loaded["component"] = oc_mock.component
package.loaded["computer"] = oc_mock.computer
package.loaded["filesystem"] = oc_mock.filesystem
package.loaded["shell"] = oc_mock.shell
package.loaded["internet"] = oc_mock.internet
package.loaded["serialization"] = oc_mock.serialization
package.loaded["event"] = oc_mock.event

-- Prevent main() from auto-running
_TEST_MODE = true

-- Load the agent. Default = multi-file entry (src/agent/init.lua); pass a
-- path as arg[1] to test a specific file (e.g. the built single-file agent.lua).
local agent_path = arg and arg[1] or "../src/agent/init.lua"
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

-- 控制字符必须转义为 \u00XX（否则裸控制字符 = 非法 JSON → 服务端 HTTP 400）
do
  local ctrl = "a" .. string.char(1) .. "\27" .. string.char(0) .. "b"
  local enc = json.encode(ctrl)
  if enc == '"a\\u0001\\u001b\\u0000b"' then
    pass = pass + 1; print("  ✓ json control chars escaped")
  else
    fail = fail + 1; print("  ✗ json control chars escaped: " .. tostring(enc))
  end
  if enc:find("[%c]") == nil then
    pass = pass + 1; print("  ✓ json no raw control chars")
  else
    fail = fail + 1; print("  ✗ json no raw control chars: " .. tostring(enc))
  end
end

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
local big_n = #big  -- 投影式就地修改，快照压缩前长度
local compacted = compact_history(big, {model = "m", api_key = ""})
test("compact_history succeeds", compacted ~= nil, "compacted=nil")
if compacted then
  test("compact adds summary prefix", compacted[1].role == "system"
    and tostring(compacted[1].content):find("对话摘要") ~= nil)
  test("compact keeps last messages", compacted[#compacted].content == "message number 30"
    and compacted[#compacted - 1].content == "message number 29")
  -- 投影式压缩（reasonix projection 精神）: 折叠段不删除——folded 标记，
  -- 头部插摘要。30 条小消息 → keep 8 → 折叠 22
  local folded_count = 0
  for _, m in ipairs(compacted) do
    if m.folded then folded_count = folded_count + 1 end
  end
  test("compact projects fold (no deletion)", #compacted == big_n + 1
    and folded_count == big_n - 8,
    "#=" .. tostring(#compacted) .. " folded=" .. tostring(folded_count))
  test("compact token floor keeps more small messages", #compacted >= 5, "#=" .. tostring(#compacted))
end

-- should_compact trigger thresholds（窗口比例 0.6 驱动 + 条数 48 兜底）
local sc_msgs = {}
for i = 1, 49 do
  sc_msgs[#sc_msgs + 1] = {role = "u", content = "x"}
end
test("should_compact true at count floor (49)", should_compact(sc_msgs, 128000))
test("should_compact false when short",
  not should_compact({{role="u", content="x"}}))
test("should_compact false when big bytes but few messages",
  not should_compact({{role="u", content=string.rep("a", 45000)}}))
-- 窗口比例: est(6×20000B ≈ 30000 tok) ≥ 40000×0.6=24000 → true
test("should_compact true at 60% window ratio",
  should_compact({
    {role="u", content=string.rep("a", 20000)},
    {role="u", content=string.rep("b", 20000)},
    {role="u", content=string.rep("c", 20000)},
    {role="u", content=string.rep("d", 20000)},
    {role="u", content=string.rep("e", 20000)},
    {role="u", content=string.rep("f", 20000)},
  }, 40000))
-- 窗口比例: est(10×1000B ≈ 2500 tok) < 128000×0.6=76800 → false
local sc_small = {}
for i = 1, 10 do
  sc_small[#sc_small + 1] = {role = "u", content = string.rep("z", 1000)}
end
test("should_compact false below 60% window ratio",
  not should_compact(sc_small, 128000))
-- 无 window 时仅条数兜底（20 条 < 48 → false）
test("should_compact no window falls back to count",
  not should_compact(sc_small, nil))

-- compact_history returns nil when nothing to compact
test("compact_history nil on tiny history", compact_history({{role="u", content="x"}}, {}) == nil)

-- system prompt no longer mentions execute_lua; mentions new tools
local sp = build_system_prompt()
test("system prompt has json_query", sp:find("json_query") ~= nil)
test("system prompt has calc", sp:find("calc") ~= nil)
test("system prompt has text_ops", sp:find("text_ops") ~= nil)
test("system prompt no execute_lua", sp:find("execute_lua") == nil)

-- TOOLS list: 显式期望清单，双向断言（无缺失、无多余）。
-- 新增工具时必须在此清单中登记，否则测试失败。
local EXPECTED_TOOLS = {
  "read_file", "write_file", "edit_file", "append_file", "list_directory",
  "json_query", "calc", "text_ops",
  "component_list", "component_doc", "component_invoke",
  "web_search", "shell_execute", "subagent_call", "ask_user",
  "compact_history",
}
local tools_have = {}
for _, t in ipairs(agent_test.TOOLS) do
  tools_have[t["function"].name] = true
end
local tools_missing, tools_extra = {}, {}
for _, name in ipairs(EXPECTED_TOOLS) do
  if not tools_have[name] then tools_missing[#tools_missing + 1] = name end
end
for name in pairs(tools_have) do
  local found = false
  for _, e in ipairs(EXPECTED_TOOLS) do if e == name then found = true break end end
  if not found then tools_extra[#tools_extra + 1] = name end
end
test("TOOLS 无缺失: " .. table.concat(EXPECTED_TOOLS, ","),
  #tools_missing == 0, "missing: " .. table.concat(tools_missing, ","))
test("TOOLS 无多余", #tools_extra == 0, "extra: " .. table.concat(tools_extra, ","))
test("TOOLS count = " .. #EXPECTED_TOOLS, #agent_test.TOOLS == #EXPECTED_TOOLS,
  "count=" .. tostring(#agent_test.TOOLS))

print("")
print("═══════════════════════════════════════")
print("Context Usage (/ctx) Tests")
print("═══════════════════════════════════════")

-- estimate_tokens: 英文 ~4 字符/token，中文更高
local et = agent_test.estimate_tokens
test("estimate_tokens ascii", et("hello world this is a test") == 6, tostring(et("hello world this is a test")))
test("estimate_tokens chinese > 0", et("你好，世界") > 0, tostring(et("你好，世界")))
test("estimate_tokens nil-safe", et(nil) == 0 and et("") == 0)

-- ctx_bar: 40 格 + ANSI 颜色（█/░ 为 3 字节 UTF-8）
local bar = agent_test.ctx_bar
local b1 = bar(0.1, 40)
local b2 = bar(0.7, 40)
local function bar_width(b) return #b:gsub("\27%[%d+m", "") / 3 end
test("ctx_bar width 40", bar_width(b1) == 40, "#=" .. tostring(bar_width(b1)))
test("ctx_bar green at 10%", b1:find("\27%[32m") ~= nil)
test("ctx_bar yellow at 70%", b2:find("\27%[33m") ~= nil)
test("ctx_bar red at 95%", agent_test.ctx_bar(0.95, 40):find("\27%[31m") ~= nil)

-- cmd_ctx: 假 usage + 构造消息，输出含 tokens 与百分比
do
  local captured = {}
  local orig_print = print
  print = function(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[i] = tostring(select(i, ...)) end
    captured[#captured + 1] = table.concat(parts, " ")
  end
  agent_test.cmd_ctx(
    {context_window = 128000, model = "test-model"},
    {{role = "system", content = "sys"}, {role = "user", content = "你好"}, {role = "tool", content = "result data"} , {role = "assistant", content = "ok"}},
    {prompt_tokens = 64000, completion_tokens = 100}
  )
  print = orig_print
  local out = table.concat(captured, "\n")
  test("cmd_ctx shows tokens", out:find("64,000") ~= nil, out:sub(1, 120))
  test("cmd_ctx shows percent", out:find("50%.0%%") ~= nil or out:find("50%") ~= nil, out:sub(1, 200))
  test("cmd_ctx shows composition", out:find("消息构成") ~= nil)
  test("cmd_ctx shows window", out:find("128,000") ~= nil)
end

-- show_ctx_line: 运行时自动显示（每次响应后一行 [ctx] ...）
do
  local captured = {}
  local orig_print = print
  print = function(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[i] = tostring(select(i, ...)) end
    captured[#captured + 1] = table.concat(parts, " ")
  end
  agent_test.show_ctx_line({prompt_tokens = 64000}, {context_window = 128000})
  print = orig_print
  local out = table.concat(captured, "\n")
  test("show_ctx_line has ctx marker", out:find("%[ctx%]") ~= nil, out)
  test("show_ctx_line has tokens+percent", out:find("64,000") ~= nil and out:find("50%.0%%") ~= nil, out)
  test("show_ctx_line has progress bar", out:find("█") ~= nil, out)
  test("show_ctx_line nil usage safe", not agent_test.show_ctx_line(nil, {}) or true)
end

-- collect_multiline: 多行输入收集（/ml 命令核心，模拟 io.read 输入队列）
do
  local orig_read = io.read
  local queue = {"line 1", "line 2", "line 3", "EOF"}
  io.read = function() return table.remove(queue, 1) end
  local text = agent_test.collect_multiline()
  io.read = orig_read
  test("collect_multiline joins lines", text == "line 1\nline 2\nline 3", tostring(text))
end

do
  local orig_read = io.read
  io.read = function() return nil end  -- Ctrl+D 取消
  local text2 = agent_test.collect_multiline()
  io.read = orig_read
  test("collect_multiline cancel on nil", text2 == nil)
end

do
  local orig_read = io.read
  io.read = function() return "EOF" end  -- 直接 EOF，空收集
  local text3 = agent_test.collect_multiline()
  io.read = orig_read
  test("collect_multiline empty on immediate EOF", text3 == nil)
end

print("")
print("═══════════════════════════════════════")
print("Context Budget / 400 Guard Tests")
print("═══════════════════════════════════════")

-- force_trim: 超限会话裁剪（防 400 死循环）
local big_content = string.rep("hello world this is a test ", 3000)  -- 每条 ~90KB
local msgs_big = {}
for i = 1, 20 do
  msgs_big[#msgs_big + 1] = {role = "user", content = big_content}
  msgs_big[#msgs_big + 1] = {role = "assistant", content = big_content}
end
local cfg_small = {context_window = 40000}
local est = agent_test.force_trim(msgs_big, cfg_small)
test("force_trim cuts to min 5 msgs (head + 4)", #msgs_big == 5, "#=" .. tostring(#msgs_big))
test("force_trim keeps head anchor", msgs_big[1].content == big_content)
test("force_trim keeps system+recent", msgs_big[#msgs_big].role == "assistant")
test("force_trim returns estimate", type(est) == "number" and est > 0)

-- ensure_context_budget: 小会话不触发压缩
local small = {{role = "user", content = "hi"}, {role = "assistant", content = "hello"}}
local m2, e2 = agent_test.ensure_context_budget(small, cfg_small, false)
test("ensure no-op on small session", #m2 == #small, "#=" .. tostring(#m2))

-- ensure 大会话: 投影式压缩（mock 下 compact 成功）——折叠段标记 + est 下降
local m3 = {}
for i = 1, 20 do
  m3[#m3 + 1] = {role = "user", content = big_content}
  m3[#m3 + 1] = {role = "assistant", content = big_content}
end
local m3_n = #m3  -- 投影式就地修改，快照压缩前长度
local m3_before = 0
for _, m in ipairs(m3) do
  m3_before = m3_before + agent_test.estimate_tokens(m.content or "")
end
local m3r, e3 = agent_test.ensure_context_budget(m3, cfg_small, false)
test("ensure projects fold on big session",
  m3r[1].role == "system" and tostring(m3r[1].content):find("对话摘要") ~= nil
  and e3 < m3_before and #m3r == m3_n + 1,
  "#=" .. tostring(#m3r) .. " est " .. tostring(e3) .. " from " .. tostring(m3_before))

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
print("Subagent Protocol Tests")
print("═══════════════════════════════════════")

-- modem loopback: send enqueues a modem_message event that pull() delivers
local modem = oc_mock.component.modem
local mock_event = oc_mock.event

-- test modem mock basics
test("modem open/isOpen", (function()
  modem.close()
  modem.open(9090)
  return modem.isOpen(9090)
end)())

-- wait_modem_message: send to self → should receive (sender, port, payload)
local wait_modem_message = agent_test.wait_modem_message
modem.open(9091)
modem.send("self", 9091, "hello-payload")
local sender, port, payload = wait_modem_message(1, 9091)
test("wait_modem_message receives", sender == modem.address() and port == 9091 and payload == "hello-payload",
  "sender=" .. tostring(sender) .. " port=" .. tostring(port) .. " payload=" .. tostring(payload))
modem.close(9091)

-- wait_modem_message timeout (no event queued)
local t0 = os.clock()
local r = wait_modem_message(0.2, 9999)
local elapsed = os.clock() - t0
test("wait_modem_message timeout", r == nil and elapsed < 2,
  "r=" .. tostring(r) .. " elapsed=" .. tostring(elapsed))

-- subagent_call end-to-end: loopback modem replies as the "subagent"
-- (request sent to LISTEN port; we enqueue a fake reply on REPLY port)
local subagent_call_tool = nil
for _, t in ipairs(agent_test.TOOLS) do
  if t["function"].name == "subagent_call" then subagent_call_tool = t end
end
test("subagent_call in TOOLS", subagent_call_tool ~= nil)

-- reply flow: request goes to LISTEN port (9090); reply expected on REPLY
-- port (9091). Mock is loopback-only (self), so a real peer reply can't be
-- simulated easily here — verify request send + timeout path locally; the
-- full master↔subagent round-trip is covered by the ocvm integration test.
modem.close()
modem.open(9090)
local req_json = execute_tool("subagent_call", json.encode({address = modem.address(), task = "count lines", timeout = 0.5}))
test("subagent_call sends and times out (no real peer)", req_json:find("timeout") ~= nil,
  "result=" .. tostring(req_json):sub(1, 120))

print("")
print("═══════════════════════════════════════")
print("Subagent Session Persistence Tests")
print("═══════════════════════════════════════")

-- session history: subagent keeps per-session JSONL histories (same format
-- as main history). Verify format + replay + path sanitization locally.
local session_file = "test_session_temp/history.jsonl"
os.execute("mkdir test_session_temp 2>nul")
os.remove(session_file)

local function sim_append(path, msg)
  local f = io.open(path, "a")
  f:write(json.encode(msg) .. "\n")
  f:close()
end
sim_append(session_file, {role = "user", content = "task one"})
sim_append(session_file, {role = "assistant", content = "answer one"})
sim_append(session_file, {role = "user", content = "task two (continued)"})

local sim_replay = {}
local f = io.open(session_file, "r")
for line in f:lines() do
  local ok2, msg = pcall(json.decode, line)
  if ok2 and type(msg) == "table" and msg.role then
    sim_replay[#sim_replay + 1] = msg
  end
end
f:close()
test("session replay: 3 messages", #sim_replay == 3)
test("session replay content",
  sim_replay[1].content == "task one" and sim_replay[3].content == "task two (continued)")

-- sanitization: session ids with special chars must be path-safe
local function sanitize(s)
  return tostring(s):gsub("[^%w_%-]", "_"):sub(1, 64)
end
local san_a = sanitize("my session/../evil")
local san_b = sanitize("abc-123")
local san_c = sanitize("正常中文")
test("session id sanitize",
  san_a == "my_session____evil" and san_b == "abc-123" and san_c == "____________",
  string.format("a=%q b=%q c=%q", san_a, san_b, san_c))

os.remove(session_file)
os.execute("rmdir test_session_temp 2>nul")

print("")
print("═══════════════════════════════════════")
print("Prompt Cache (Prefix Cache) Tests")
print("═══════════════════════════════════════")

-- build_system_prompt(): memoized + byte-stable（DeepSeek 前缀缓存锚点）
local sys_a = agent_test.build_system_prompt()
local sys_b = agent_test.build_system_prompt()
test("system prompt byte-stable across calls", sys_a == sys_b)
test("system prompt has no runtime data",
  type(sys_a) == "string" and not sys_a:find("Uptime:") and not sys_a:find("Free memory:")
  and not sys_a:find("Connected components:"))
test("system prompt keeps static content", sys_a:find("Current computer address:") ~= nil)

-- build_runtime_block(): 每次请求重新生成（uptime 变化 → 内容变化）
local rt_a, rt_b
do
  local real_uptime = computer.uptime
  computer.uptime = function() return 1000 end
  rt_a = agent_test.build_runtime_block()
  computer.uptime = function() return 2000 end
  rt_b = agent_test.build_runtime_block()
  computer.uptime = real_uptime
end
test("runtime block changes between calls", rt_a ~= rt_b)
test("runtime block carries dynamic fields",
  rt_a:find("Uptime: 1000") ~= nil and rt_a:find("Free memory:") ~= nil
  and rt_a:find("Connected components:") ~= nil, rt_a:sub(1, 200))

-- chat(): 尾部追加 runtime 消息 + system 保持静态（包装 internet.request 捕获请求体）
local rt_live = agent_test.build_runtime_block()
local captured = nil
local real_request = internet.request
internet.request = function(url, data, headers, method)
  captured = data
  return real_request(url, data, headers, method)
end
local chat_resp = agent_test.chat(
  {{role = "user", content = "hi"}},
  {api_key = "test", model = "mock", api_url = "https://example.test/chat/completions"})
internet.request = real_request
test("chat() mock round-trip", type(chat_resp) == "table" and chat_resp.content ~= nil,
  "resp=" .. tostring(chat_resp and chat_resp.content or chat_resp))
local ok_body, body = pcall(json.decode, captured or "")
test("chat() body decodes", ok_body and type(body) == "table")
if ok_body and type(body) == "table" then
  test("chat() first message = static system prompt",
    body.messages[1].role == "system" and body.messages[1].content == sys_a)
  local last = body.messages[#body.messages]
  test("chat() last message = runtime block",
    last and last.role == "user" and last.content == rt_live
    and last.content:find("runtime status") ~= nil,
    "last role=" .. tostring(last and last.role) .. " content="
      .. tostring(last and last.content):sub(1, 100))
  test("chat() conversation preserved before tail",
    body.messages[#body.messages - 1].role == "user"
    and body.messages[#body.messages - 1].content == "hi")
end

-- trim_history: 保留 messages[1] 头部锚点（缓存前缀跨裁剪存活）
local trim_history = agent_test.trim_history
local anchor_msgs = {}
for i = 1, 70 do
  anchor_msgs[#anchor_msgs + 1] = {role = "user", content = "msg " .. i}
end
local trimmed = trim_history(anchor_msgs)
test("trim_history keeps first message", trimmed[1].content == "msg 1",
  "first=" .. tostring(trimmed[1] and trimmed[1].content))
test("trim_history caps count", #trimmed <= 60, "#=" .. tostring(#trimmed))
local anchor2 = {}
for i = 1, 6 do
  anchor2[#anchor2 + 1] = {role = "user", content = string.rep("x", 40000) .. " m" .. i}
end
local trimmed2 = trim_history(anchor2)
test("trim_history byte cap keeps head + recent",
  trimmed2[1].content:find("m1") ~= nil and #trimmed2 == 4,
  "#=" .. tostring(#trimmed2))

-- /ctx + 运行时行: cache hit/miss 显示（usage 字段透传）
local function capture_print(fn)
  local out = {}
  local real_print = print
  print = function(s) out[#out + 1] = tostring(s) end
  local ok = pcall(fn)
  print = real_print
  return ok, table.concat(out)
end
local ctx_ok, ctx_text = capture_print(function()
  agent_test.cmd_ctx({context_window = 128000, model = "mock"},
    {{role = "user", content = "hi"}},
    {prompt_tokens = 1000, completion_tokens = 200,
     prompt_cache_hit_tokens = 800, prompt_cache_miss_tokens = 200})
end)
test("cmd_ctx renders cache hit line", ctx_ok and ctx_text:find("缓存") ~= nil,
  ctx_text)
local line_ok, line_text = capture_print(function()
  agent_test.show_ctx_line({prompt_tokens = 10000,
    prompt_cache_hit_tokens = 9000, prompt_cache_miss_tokens = 1000},
    {context_window = 128000})
end)
test("show_ctx_line shows cache %", line_ok and line_text:find("cache 90%%") ~= nil,
  line_text)

-- cache_stats: 兼容 DeepSeek 与 OpenAI 新格式（讯飞星辰 kimi 实测格式）
local cs = agent_test.cache_stats
local h, m = cs({prompt_tokens = 1000, prompt_cache_hit_tokens = 800, prompt_cache_miss_tokens = 200})
test("cache_stats deepseek format", h == 800 and m == 200, tostring(h) .. "/" .. tostring(m))
local h2, m2 = cs({prompt_tokens = 1000, prompt_tokens_details = {cached_tokens = 800}})
test("cache_stats openai details format", h2 == 800 and m2 == 200, tostring(h2) .. "/" .. tostring(m2))
test("cache_stats nil without cache fields", cs({prompt_tokens = 1000}) == nil)
test("cache_stats nil on zero hit", cs({prompt_tokens = 1000, prompt_tokens_details = {cached_tokens = 0}}) == nil)
local line2_ok, line2_text = capture_print(function()
  agent_test.show_ctx_line({prompt_tokens = 10000,
    prompt_tokens_details = {cached_tokens = 9000}},
    {context_window = 128000})
end)
test("show_ctx_line openai format cache %", line2_ok and line2_text:find("cache 90%%") ~= nil,
  line2_text)

-- ═══════════════════════════════════════════
-- KEEP 标记机制（opencode-acp keep-markers 移植）
-- ═══════════════════════════════════════════

-- summarize prompt 含 KEEP 指令
local keep_captured_prompt = nil
local function keep_mock_chat(msgs, cfg)
  if msgs and msgs[1] then keep_captured_prompt = msgs[1].content end
  return {content = keep_mock_summary}
end
agent_test.set_chat(keep_mock_chat)
local keep_msgs = {}
for i = 1, 12 do
  keep_msgs[#keep_msgs + 1] = {role = "user", content = "msg " .. i}
end
keep_msgs[2].content = "critical secret value: abc123"
agent_test.summarize_history(keep_msgs, {model = "m", api_key = ""})
test("summarize prompt instructs KEEP markers",
  keep_captured_prompt and keep_captured_prompt:find("[[KEEP", 1, true) ~= nil,
  tostring(keep_captured_prompt):sub(1, 200))

-- KEEP 展开: mock 摘要含 [[KEEP:2]] → 原文 abc123 内联
keep_mock_summary = "summary text with [[KEEP:2]] marker"
local keep_compacted = agent_test.compact_history(keep_msgs, {model = "m", api_key = ""})
agent_test.set_chat(agent_test.chat)
test("KEEP expands to original message", keep_compacted
  and keep_compacted[1].content:find("abc123") ~= nil,
  tostring(keep_compacted and keep_compacted[1].content or nil):sub(1, 300))
test("KEEP keeps summary text", keep_compacted
  and keep_compacted[1].content:find("summary text with") ~= nil)

-- KEEP 越界引用: 不崩溃、保留原标记
agent_test.set_chat(keep_mock_chat)
keep_mock_summary = "s [[KEEP:99]]"
local keep_oob = agent_test.compact_history(keep_msgs, {model = "m", api_key = ""})
agent_test.set_chat(agent_test.chat)
test("KEEP out-of-range marker survives", keep_oob
  and keep_oob[1].content:find("[[KEEP:99]]", 1, true) ~= nil,
  tostring(keep_oob and keep_oob[1].content or nil):sub(1, 200))

-- KEEP 截断: 长消息嵌入截断到 1000 字符
local keep_long_msgs = {
  {role = "user", content = string.rep("x", 3000) .. " tail-marker"},
  {role = "user", content = "short"},
  {role = "user", content = "s3"}, {role = "user", content = "s4"},
  {role = "user", content = "s5"}, {role = "user", content = "s6"},
  {role = "user", content = "s7"}, {role = "user", content = "s8"},
  {role = "user", content = "s9"}, {role = "user", content = "s10"},
  {role = "user", content = "s11"}, {role = "user", content = "s12"},
}
agent_test.set_chat(keep_mock_chat)
keep_mock_summary = "s [[KEEP:1]]"
local keep_long = agent_test.compact_history(keep_long_msgs, {model = "m", api_key = ""})
agent_test.set_chat(agent_test.chat)
test("KEEP truncates long embed", keep_long
  and keep_long[1].content:find("truncated") ~= nil
  and keep_long[1].content:find("tail-marker") == nil,
  tostring(keep_long and keep_long[1].content or nil):sub(1, 300))

print("")
print("═══════════════════════════════════════")
print("Model-Driven Compaction Tests")
print("═══════════════════════════════════════")

-- 策略（opencode-acp）: 无进程内自动压缩——60-80% 窗口估算不自动压缩
local e_msgs = {}
for i = 1, 10 do
  e_msgs[#e_msgs + 1] = {role = "user", content = string.rep("e", 10000)}
end
local e_after, e_est = agent_test.ensure_context_budget(e_msgs,
  {context_window = 40000, model = "m", api_key = ""})
test("ensure no auto-compact at 60-80% (model-driven)",
  #e_after == 10, "#=" .. tostring(#e_after) .. " est=" .. tostring(e_est))

-- compact_history 工具: 模型驱动压缩（KEEP 标记 + 投影式就地 + 持久化）
local tool_ctx = {}
for i = 1, 15 do
  tool_ctx[#tool_ctx + 1] = {role = "user", content = "tool ctx " .. i}
end
local rebuilt = nil
agent_test.set_chat(keep_mock_chat)
keep_mock_summary = "tool summary [[KEEP:1]]"
agent_test.set_context_getter(function() return tool_ctx end)
agent_test.set_rebuild_current(function(msgs) rebuilt = msgs end)
local compact_result = execute_tool("compact_history", json.encode({}))
agent_test.set_chat(agent_test.chat)
agent_test.set_context_getter(nil)
agent_test.set_rebuild_current(nil)
local tool_folded = 0
for _, m in ipairs(tool_ctx) do
  if m.folded then tool_folded = tool_folded + 1 end
end
test("compact tool projects fold in place",
  tool_ctx[1].content:find("tool summary", 1, true) ~= nil
  and #tool_ctx == 16 and tool_folded == 7,  -- 15 条 + 摘要；折叠 15-8=7
  "n=" .. tostring(#tool_ctx) .. " folded=" .. tostring(tool_folded)
  .. " result=" .. tostring(compact_result):sub(1, 120))
test("compact tool rebuilds history file", rebuilt ~= nil and #rebuilt == #tool_ctx)
test("compact tool returns report", type(compact_result) == "string"
  and compact_result:find("compacted", 1, true) ~= nil,
  tostring(compact_result):sub(1, 160))
-- 短历史: 拒绝压缩
local short_ctx = {{role = "user", content = "only one"}}
agent_test.set_context_getter(function() return short_ctx end)
local short_result = execute_tool("compact_history", json.encode({}))
agent_test.set_context_getter(nil)
test("compact tool rejects short history",
  type(short_result) == "string" and short_result:find("too short", 1, true) ~= nil,
  tostring(short_result):sub(1, 160))

-- 上下文占用注入尾部块（模型决策依据: 看见占用 → 决定压缩）
agent_test.set_runtime_extra(function()
  return "Context usage: 70% of model window (est. 1000/128000 tokens). If >=60% or the history is long, call compact_history."
end)
local rt_extra = agent_test.build_runtime_block()
agent_test.set_runtime_extra(nil)
test("runtime block carries context usage",
  rt_extra:find("Context usage: 70%", 1, true) ~= nil
  and rt_extra:find("compact_history", 1, true) ~= nil,
  rt_extra:sub(1, 300))

-- system prompt 含 compact 指令
test("system prompt instructs compact_history",
  sys_a:find("compact_history", 1, true) ~= nil)

-- 投影式压缩: chat 请求构造跳过 folded 折叠段（模型只见摘要+保留段）
local proj_msgs = {
  {role = "system", content = "[对话摘要] summary here"},
  {role = "user", content = "old folded msg", folded = true},
  {role = "user", content = "active msg"},
}
local proj_captured = nil
local real_req2 = internet.request
internet.request = function(url, data, headers, method)
  proj_captured = data
  return real_req2(url, data, headers, method)
end
local proj_resp = agent_test.chat(proj_msgs,
  {api_key = "test", model = "mock", api_url = "https://example.test/chat/completions"})
internet.request = real_req2
local ok_pb, proj_body = pcall(json.decode, proj_captured or "")
test("chat skips folded messages in request",
  ok_pb and type(proj_body) == "table" and #proj_body.messages == 4
  and proj_body.messages[3].content == "active msg"
  and proj_body.messages[4].content:find("runtime status", 1, true) ~= nil,
  "resp=" .. tostring(proj_resp and proj_resp.content or proj_resp))

-- 投影式压缩: trim 优先回收折叠段（已进摘要，删除无损），保留段保住
local trim_proj = {
  {role = "user", content = "head anchor"},
  {role = "system", content = "[对话摘要] s"},
  {role = "user", content = string.rep("x", 55000), folded = true},
  {role = "user", content = string.rep("y", 55000), folded = true},
  {role = "user", content = string.rep("z", 55000), folded = true},
  {role = "user", content = string.rep("w", 55000), folded = true},
  {role = "user", content = "recent 1"},
  {role = "user", content = "recent 2"},
}
local trim_proj_out = agent_test.trim_history(trim_proj)
test("trim reclaims folded segments first",
  trim_proj_out[1].content == "head anchor"
  and trim_proj_out[#trim_proj_out].content == "recent 2"
  and #trim_proj_out == 7,  -- 220K 超预算 → 删 1 条折叠（55000）→ 165K 内
  "#=" .. tostring(#trim_proj_out))

print("")
print("═══════════════════════════════════════")
print("Shell Guard Tests (Unix-ism 护栏)")
print("═══════════════════════════════════════")

-- 护栏在 exec 入口拦截（先于 shell 调用），mock 环境可测拒绝路径
local function try_shell(cmd)
  return execute_tool("shell_execute", json.encode({command = cmd}))
end
local g_res = try_shell("uname -a")
test("guard rejects uname", type(g_res) == "string"
  and g_res:find("rejected by guard", 1, true) ~= nil
  and g_res:find("read_file", 1, true) ~= nil, tostring(g_res):sub(1, 160))
test("guard rejects head", try_shell("head -3 file"):find("rejected by guard", 1, true) ~= nil)
test("guard rejects tail", try_shell("tail -5 log.txt"):find("rejected by guard", 1, true) ~= nil)
test("guard rejects grep", try_shell("grep -rn foo /mnt"):find("rejected by guard", 1, true) ~= nil)
test("guard rejects wc", try_shell("wc -l file.lua"):find("rejected by guard", 1, true) ~= nil)
test("guard rejects curl", try_shell("curl https://example.com"):find("rejected by guard", 1, true) ~= nil)
test("guard rejects wget", try_shell("wget http://x"):find("rejected by guard", 1, true) ~= nil)
-- 管道内的 head 同样拦截
test("guard rejects head in pipe",
  try_shell("cat file | head -2"):find("rejected by guard", 1, true) ~= nil)
-- 裸 lua REPL 拒绝（含提示）
local g_lua = try_shell("lua")
test("guard rejects bare lua REPL", type(g_lua) == "string"
  and g_lua:find("interactive REPL", 1, true) ~= nil, tostring(g_lua):sub(1, 200))
test("guard rejects bare luac REPL",
  try_shell("luac # comment"):find("rejected by guard", 1, true) ~= nil)
-- 带参数的 lua 放行（不触发护栏; mock 环境无真 shell，结果非拒绝即可）
local g_lua_e = try_shell('lua -e "print(1)"')
test("guard allows lua -e", type(g_lua_e) == "string"
  and g_lua_e:find("rejected by guard", 1, true) == nil
  and g_lua_e:find("interactive REPL", 1, true) == nil, tostring(g_lua_e):sub(1, 120))
-- 非 Unix 命令放行（echo 在 mock/真实环境都安全）
local g_echo = try_shell("echo hi")
test("guard allows normal commands", type(g_echo) == "string"
  and g_echo:find("rejected by guard", 1, true) == nil, tostring(g_echo):sub(1, 120))

print("")
print("═══════════════════════════════════════")
print("TUI Tests (agent.tui, oc-ai 参考)")
print("═══════════════════════════════════════")

local ok_tui, tui_mod = pcall(require, "agent.tui")
test("tui module loads", ok_tui and type(tui_mod) == "table", tostring(ok_tui))
if ok_tui and type(tui_mod) == "table" then
  test("tui init without gpu (degraded)", (function()
    local ok_i, err = pcall(tui_mod.init)
    return ok_i, err
  end)())
  -- print → history 追加（绘制静默失败，逻辑仍工作）
  tui_mod.init()
  local h0 = #tui_mod.history()
  tui_mod.print("hello tui")
  test("tui.print appends history", #tui_mod.history() == h0 + 1,
    "#=" .. tostring(#tui_mod.history()))
  -- 长文本换行（宽度 80）
  tui_mod.print(string.rep("word ", 30))
  test("tui.print wraps long text", #tui_mod.history() > h0 + 2,
    "#=" .. tostring(#tui_mod.history()))
  -- 中文（无 unicode mock 时按字节降级）
  tui_mod.print("中文测试消息中文测试消息中文测试消息中文测试消息中文测试消息中文测试消息中文测试消息")
  test("tui.print handles chinese", #tui_mod.history() > h0 + 3)
  -- 角色前缀
  tui_mod.printRole("user", "question?")
  tui_mod.printRole("error", "boom")
  local hist = tui_mod.history()
  test("tui.printRole prefixes",
    hist[#hist - 1].text:sub(1, 2) == "> "
    and hist[#hist].text:sub(1, 6) == "Error:",
    hist[#hist - 1].text:sub(1, 10) .. " | " .. hist[#hist].text:sub(1, 10))
  -- 工具调用显示截断
  tui_mod.printToolCall("shell_execute", '{"command":"' .. string.rep("x", 150) .. '"}')
  local hist2 = tui_mod.history()
  test("tui.printToolCall truncates args",
    hist2[#hist2].text:find("...", 1, true) ~= nil
    and #hist2[#hist2].text <= 105, "#=" .. tostring(#hist2[#hist2].text))
  -- 滚动不崩 + 状态设置
  local ok_scroll = pcall(tui_mod.scrollUp, 5)
  test("tui.scrollUp safe", ok_scroll)
  local ok_sd = pcall(tui_mod.setStatus, "Testing...")
  test("tui.setStatus safe", ok_sd)
  -- 补全候选注册（静态列表，不经 UI）
  local ok_comp = pcall(tui_mod.setCompletions, {"/help", "/ctx", "read_file"})
  test("tui.setCompletions safe", ok_comp)
  -- 多行粘贴钩子（ocvm 事件循环模拟不可靠，用 debug_set_buffer 验证渲染路径）
  local ok_set = pcall(tui_mod.debug_set_buffer, "line1\nline2\nline3")
  test("tui.debug_set_buffer safe", ok_set)
  local ok_multi = pcall(tui_mod.drawInput)
  test("tui.drawInput multiline safe", ok_multi)
  pcall(tui_mod.debug_set_buffer, "single")
  local ok_single2 = pcall(tui_mod.drawInput)
  test("tui.drawInput singleline safe", ok_single2)
  -- printHistory: 会话历史填充内容区（截断/跳过 folded/角色色/顺序）
  tui_mod.init()
  local ph_msgs = {
    {role = "system", content = "[对话摘要] 摘要内容"},
    {role = "user", content = "历史问题1"},
    {role = "user", content = "折叠消息", folded = true},
    {role = "assistant", content = string.rep("很长的回答", 50)},
    {role = "user", content = "最近问题"},
  }
  local ph0 = #tui_mod.history()
  pcall(tui_mod.printHistory, ph_msgs)
  local ph_hist = tui_mod.history()
  local ph_joined = ""
  for i = ph0 + 1, #ph_hist do ph_joined = ph_joined .. ph_hist[i].text end
  test("printHistory renders history",
    ph_joined:find("历史问题1", 1, true) ~= nil
    and ph_joined:find("最近问题", 1, true) ~= nil
    and ph_joined:find("对话摘要", 1, true) ~= nil,
    ph_joined:sub(1, 150))
  test("printHistory skips folded", ph_joined:find("折叠消息", 1, true) == nil,
    ph_joined:sub(1, 150))
  test("printHistory truncates long entries",
    #ph_hist[#ph_hist].text <= 205, "#=" .. tostring(#ph_hist[#ph_hist].text))
  -- 清理
  pcall(tui_mod.cleanup)
end

print("")
print("═══════════════════════════════════════")
print("Sessions & Scroll Command Tests")
print("═══════════════════════════════════════")

-- list_sessions: 扫描会话目录的 *.jsonl（/new 归档 .txt 不列入）
local sdir = "test_sessions_tmp"
os.execute("mkdir " .. sdir .. " 2>nul")
local s_a = io.open(sdir .. "/alpha.jsonl", "w")
s_a:write(json.encode({role = "user", content = "a1"}) .. "\n")
s_a:write(json.encode({role = "assistant", content = "a2"}) .. "\n")
s_a:close()
local s_b = io.open(sdir .. "/beta.jsonl", "w")
s_b:write(json.encode({role = "user", content = "b1"}) .. "\n")
s_b:close()
io.open(sdir .. "/archive.txt", "w"):write("ignored"):close()
local sess_list = agent_test.list_sessions(sdir)
test("list_sessions finds jsonl sessions", #sess_list == 2,
  "#=" .. tostring(#sess_list))
test("list_sessions counts messages",
  sess_list[1].name == "alpha" and sess_list[1].count == 2
  or sess_list[1].name == "beta" and sess_list[1].count == 1,
  sess_list[1].name .. "=" .. tostring(sess_list[1].count))

-- 切换核心机制: set_paths → load_history 加载新会话
local orig_path = agent_test.current_session_path()
agent_test.set_history_path(sdir .. "/beta.jsonl")
local beta_msgs = agent_test.load_history()
test("session switch loads new history",
  #beta_msgs == 1 and beta_msgs[1].content == "b1",
  "#=" .. tostring(#beta_msgs))
agent_test.set_history_path(orig_path)

-- handle_command: /sessions 输出 + /session 切换 + 翻页命令不崩
local cmd_cfg = {model = "m", api_key = ""}
local cmd_msgs = {{role = "user", content = "hello"}}
local exit1, c1, m1 = agent_test.handle_command("/sessions", cmd_cfg, cmd_msgs)
test("/sessions lists sessions", not exit1 and type(m1) == "table"
  and m1 == cmd_msgs, tostring(exit1))
local exit2, c2, m2 = agent_test.handle_command("/session", cmd_cfg, cmd_msgs)
test("/session usage without name", not exit2 and c2 == cmd_cfg and m2 == cmd_msgs)
local exit3, c3, m3 = agent_test.handle_command("/session default", cmd_cfg, cmd_msgs)
test("/session default resets path", not exit3 and c3 == cmd_cfg and type(m3) == "table",
  "m3=" .. tostring(type(m3)))
agent_test.set_history_path(orig_path)
local exit4 = agent_test.handle_command("/up", cmd_cfg, cmd_msgs)
test("/up without TUI prints hint", not exit4)
local exit5 = agent_test.handle_command("/pgdn", cmd_cfg, cmd_msgs)
test("/pgdn without TUI prints hint", not exit5)
local exit6 = agent_test.handle_command("/top", cmd_cfg, cmd_msgs)
test("/top without TUI prints hint", not exit6)
-- 清理
os.remove(sdir .. "/alpha.jsonl")
os.remove(sdir .. "/beta.jsonl")
os.remove(sdir .. "/archive.txt")
os.execute("rmdir " .. sdir .. " 2>nul")

print("")
print("═══════════════════════════════════════")
print(string.format("FINAL: %d pass, %d fail out of %d tests", pass, fail, pass + fail))
print("═══════════════════════════════════════")

os.exit(fail > 0 and 1 or 0)
