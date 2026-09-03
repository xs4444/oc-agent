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
keyboard = oc_mock.keyboard

-- Intercept require() to return mocked OC modules
local orig_require = require
package.loaded["component"] = oc_mock.component
package.loaded["computer"] = oc_mock.computer
package.loaded["filesystem"] = oc_mock.filesystem
package.loaded["shell"] = oc_mock.shell
package.loaded["internet"] = oc_mock.internet
package.loaded["serialization"] = oc_mock.serialization
package.loaded["event"] = oc_mock.event
package.loaded["keyboard"] = oc_mock.keyboard

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

-- v0.3.124: json_query / calc / text_ops 工具已删（模型自身能力），
-- 对应的 test_tool 块随之移除。

test_tool("execute_lua removed", "execute_lua", '{"code":"return 1"}',
  function(r) return r:find("removed") ~= nil end)

-- v0.3.124: component_list 工具已删（OpenOS 有 `components` 命令）

test_tool("unknown tool", "unknown_tool", '{}',
  function(r) return r:find("Unknown tool") ~= nil end)

-- web_search tests (HN Algolia fallback, no tavily key configured)
test_tool("web_search hn", "web_search", '{"query":"gtnh"}',
  function(r) return r:find("Result 1 for gtnh") ~= nil and r:find("example.com/1") ~= nil end)
test_tool("web_search limit", "web_search", '{"query":"lua","limit":1}',
  function(r) return r:find("Result 1 for lua") ~= nil and not r:find("Result 2") end)
test_tool("web_search empty query", "web_search", '{"query":""}',
  function(r) return r:find("query is required") ~= nil end)

-- v0.3.124: component_doc / component_invoke 工具已删（用 lua -e 调组件）

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

-- ── HTTP 挂起修复: 响应读超时 + 重试预算可配 ──
-- 真机"第二轮始终 Thinking..."根因: 荒野大师 internet 迭代器连接建立后
-- 流不结束 → 响应迭代无限等（预算检查在 once 返回后才执行，形同虚设）。
do
  local http_mod = require("agent.http")
  -- 构造 handle 工厂: 返回固定 code 的响应（一次迭代后结束）
  local function make_code_handle(code, body)
    local started = false
    local h = {}
    setmetatable(h, {
      __call = function()
        if started then return nil end
        started = true
        return body or "server response"
      end,
      __index = { response = function() return code end },
    })
    return h
  end
  local real_request = internet.request

  -- 1) response read timeout: 永不结束的迭代器 → deadline 触发（不无限等）
  -- 注意: 迭代器吐空串（0 字节）——挂起语义是"连接建立后流不结束但不来
  -- 数据"。若吐非空块，测试环境 os.sleep 是 no-op（run_tests.lua:7），
  -- 纯 CPU 循环 ~1M 次/秒，131072 字节上限会在 0.5s deadline 前先触发
  -- "too large"，测不到 timeout 路径（真机 os.sleep(0.02) 实际挂起，
  -- 120s deadline 恒先于字节上限触发——挂起语义对应空串）。
  local hang_handle = {}
  setmetatable(hang_handle, {
    __call = function() return "" end,  -- 流永不结束但不产生字节
    __index = { response = function() return 200 end },
  })
  internet.request = function() return hang_handle end
  http_mod.set_response_timeout(0.5)
  http_mod.set_budget(1)  -- 预算也缩短，超时错误经重试路径快速返回
  local t0 = os.clock()
  local h_code, h_resp, h_err = http_post("https://mock/hang", {}, "{}")
  local h_elapsed = os.clock() - t0
  test("http read timeout returns error", type(h_err) == "string"
    and h_err:find("read timeout", 1, true) ~= nil, tostring(h_err))
  test("http read timeout returns fast (<2s)", h_elapsed < 2,
    string.format("%.2fs", h_elapsed))

  -- 2) retry budget configurable: set_budget(1) + 持续 500 → ~1s 返回（非 60s）
  internet.request = function() return make_code_handle(500) end
  http_mod.set_budget(1)
  local t1 = os.clock()
  local b_code, b_resp, b_err = http_post("https://mock/500", {}, "{}")
  local b_elapsed = os.clock() - t1
  internet.request = real_request
  test("retry budget configurable (~1s not 60s)", b_elapsed < 10,
    string.format("%.2fs code=%s", b_elapsed, tostring(b_code)))

  -- 3) budget reset per chat call: chat() 每次请求前用 config.retry_budget 覆盖
  http_mod.set_budget(60)  -- 先设回大值（_TEST_MODE 默认），确认 chat 覆盖
  internet.request = function() return make_code_handle(500) end
  local t2 = os.clock()
  local c_res = agent_test.chat({{role = "user", content = "hi"}},
    {api_key = "test", model = "mock", api_url = "https://example.test/chat/completions",
     retry_budget = 1})
  local c_elapsed = os.clock() - t2
  internet.request = real_request
  test("budget reset per chat call (config overrides)",
    type(c_res) == "table" and c_res.error
    and c_res.error:find("HTTP 500", 1, true) ~= nil and c_elapsed < 10,
    "err=" .. tostring(c_res and c_res.error)
      .. string.format(" %.2fs", c_elapsed))

  -- ── v0.3.118 重试透出 + 端点报错行为 ──
  -- 4) on_retry 回调: 持续 500 + 短预算 → 每轮退避前触发, attempt 从 1 起,
  --    code=500, wait>0（状态栏"重试第 N 次"数据源）
  internet.request = function() return make_code_handle(500) end
  http_mod.set_budget(1)
  local retry_log = {}
  local ok_r4 = pcall(http_post, "https://mock/500", {}, "{}",
    function(attempt, code, err, wait)
      retry_log[#retry_log + 1] = {attempt = attempt, code = code, wait = wait}
    end)
  internet.request = real_request
  http_mod.set_budget(60)
  test("on_retry callback fires on 5xx", ok_r4 and #retry_log > 0,
    "n=" .. tostring(#retry_log))
  test("on_retry attempt starts at 1 with code 500",
    retry_log[1] and retry_log[1].attempt == 1 and retry_log[1].code == 500,
    "first=" .. tostring(retry_log[1] and (retry_log[1].attempt .. "/" .. tostring(retry_log[1].code))))
  test("on_retry wait > 0", retry_log[1] and retry_log[1].wait and retry_log[1].wait > 0,
    "wait=" .. tostring(retry_log[1] and retry_log[1].wait))
  test("on_retry attempts increase", #retry_log >= 2
    and retry_log[2].attempt == 2,
    "n=" .. tostring(#retry_log) .. " a2=" .. tostring(retry_log[2] and retry_log[2].attempt))

  -- 5) 4xx 永久失败不重试: 400 非瞬态 → 立即返回 code, 无 err, 回调 0 次
  internet.request = function() return make_code_handle(400) end
  local retry_log2 = {}
  local f_code, f_resp, f_err = http_post("https://mock/400", {}, "{}",
    function() retry_log2[#retry_log2 + 1] = true end)
  internet.request = real_request
  test("http 400 no retry (immediate, callback 0x)", f_code == 400
    and f_err == nil and #retry_log2 == 0,
    "code=" .. tostring(f_code) .. " err=" .. tostring(f_err)
      .. " retries=" .. tostring(#retry_log2))

  -- 6) 网络错误路径预算耗尽: err 附"重试 N 次后预算耗尽"（状态栏/摘要
  --    能看出非静默挂起; HTTP 码路径不动 resp, 不破坏调用方解析）
  local hang_handle2 = {}
  setmetatable(hang_handle2, {
    __call = function() return "" end,
    __index = { response = function() return 200 end },
  })
  internet.request = function() return hang_handle2 end
  http_mod.set_response_timeout(0.1)
  http_mod.set_budget(1)
  local e_code, e_resp, e_err = http_post("https://mock/hang2", {}, "{}",
    function() end)
  internet.request = real_request
  http_mod.set_response_timeout(120)
  http_mod.set_budget(60)
  test("network-error budget exhaustion mentions retry count",
    type(e_err) == "string" and e_err:find("重试", 1, true) ~= nil
    and e_err:find("read timeout", 1, true) ~= nil,
    "err=" .. tostring(e_err))

  -- 7) chat() 层: 4xx 返回 error（不重试不挂起, init.lua 错误分支可见）
  internet.request = function() return make_code_handle(400, '{"error":"bad request"}') end
  local g_res = agent_test.chat({{role = "user", content = "hi"}},
    {api_key = "test", model = "mock", api_url = "https://example.test/chat/completions"})
  internet.request = real_request
  test("chat 400 returns error without retry",
    type(g_res) == "table" and g_res.error and g_res.error:find("HTTP 400", 1, true) ~= nil,
    "err=" .. tostring(g_res and g_res.error))

  -- ── 响应体累积上限（结构性内存护栏）──
  -- OOM 无法预测（单次响应峰值不可知）→ 正确解法 = 结构性上限: 所有已知
  -- 分配源设硬上限。http_post_once 的 chunks 累积此前无上限——max_tokens
  -- 8192 的 reasoning 响应 JSON 可能 100KB+，decode 峰值 2-3x 单次就爆
  -- （真机 2MB 内存）。超限返回明确 error（不静默截断——截断的 JSON
  -- 解析失败，明确 error 让 chat() 走错误路径）。
  -- 4) response body limit: 永不结束迭代器持续吐 1KB 块 → 超限即明确 error
  local big_handle = {}
  setmetatable(big_handle, {
    __call = function() return string.rep("x", 1024) end,  -- 每块 1KB，流永不结束
    __index = { response = function() return 200 end },
  })
  internet.request = function() return big_handle end
  http_mod.set_response_body_limit(4096)  -- 4KB 上限 → 第 5 块（>4KB）超限
  http_mod.set_budget(1)  -- 超限错误经重试路径快速返回（预算封顶）
  local t3 = os.clock()
  local l_code, l_resp, l_err = http_post("https://mock/big", {}, "{}")
  local l_elapsed = os.clock() - t3
  internet.request = real_request
  test("response body limit returns error", type(l_err) == "string"
    and l_err:find("response too large", 1, true) ~= nil, tostring(l_err))
  test("response body limit returns fast (<2s)", l_elapsed < 2,
    string.format("%.2fs", l_elapsed))

  -- 5) body limit respects config: chat() 每次请求前用 config.response_body_limit 覆盖
  http_mod.set_response_body_limit(131072)  -- 先设回大值，确认 chat 覆盖
  internet.request = function() return big_handle end
  local t4 = os.clock()
  local d_res = agent_test.chat({{role = "user", content = "hi"}},
    {api_key = "test", model = "mock", api_url = "https://example.test/chat/completions",
     retry_budget = 1, response_body_limit = 4096})
  local d_elapsed = os.clock() - t4
  internet.request = real_request
  test("body limit respects config (chat override)",
    type(d_res) == "table" and d_res.error
    and d_res.error:find("response too large", 1, true) ~= nil
    and d_elapsed < 2,
    "err=" .. tostring(d_res and d_res.error)
      .. string.format(" %.2fs", d_elapsed))

  -- 恢复默认（_TEST_MODE: budget 60 / response timeout 120 / body limit 128KB）
  http_mod.set_budget(60)
  http_mod.set_response_timeout(120)
  http_mod.set_response_body_limit(131072)
end

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
  -- 传统自动压缩（opencode 模式）: 折叠段**物理删除**——摘要承载旧消息
  -- 内容（KEEP/REF 静态展开），折叠段留在内存表纯占内存。30 条小消息
  -- → keep 8 → 折叠 22 条删除，表 = 摘要 + 8 条 = 9 条。
  local folded_count = 0
  for _, m in ipairs(compacted) do
    if m.folded then folded_count = folded_count + 1 end
  end
  test("compact deletes folded segments (memory release)", #compacted == 9
    and folded_count == 0,
    "#=" .. tostring(#compacted) .. " folded=" .. tostring(folded_count))
  test("compact token floor keeps more small messages", #compacted >= 5, "#=" .. tostring(#compacted))
end

-- 折叠段物理回收（内存释放）: 折叠后表条数/字节显著减少——折叠段删除，
-- 不再驻留内存（v0.3.47 前投影式折叠只标记不删除，93.6KB JSONL → 表
-- ~300KB 驻留是第二次 OOM 根因）
do
  local rel = {}
  for i = 1, 20 do
    rel[#rel + 1] = {role = "user", content = string.rep("r", 5000) .. i}
  end
  local rel_n = #rel
  local rel_bytes_before = 0
  for _, m in ipairs(rel) do rel_bytes_before = rel_bytes_before + #(m.content or "") end
  local rel_compacted = compact_history(rel, {model = "m", api_key = ""})
  local rel_bytes_after = 0
  local rel_folded = 0
  for _, m in ipairs(rel_compacted) do
    rel_bytes_after = rel_bytes_after + #(m.content or "")
    if m.folded then rel_folded = rel_folded + 1 end
  end
  test("compact releases memory (folded segments deleted)",
    rel_compacted ~= nil and #rel_compacted < rel_n
    and rel_bytes_after < rel_bytes_before / 2 and rel_folded == 0,
    "#=" .. tostring(rel_compacted and #rel_compacted or 0) .. "/" .. tostring(rel_n)
      .. " bytes " .. tostring(rel_bytes_after) .. "/" .. tostring(rel_bytes_before)
      .. " folded=" .. tostring(rel_folded))
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

-- v0.3.124: system prompt 不再列 json_query/calc/text_ops/component_*（已删），
-- 改为引导用 OpenOS 真实命令（components/grep/lua -e）。
local sp = build_system_prompt()
test("system prompt has search_files", sp:find("search_files") ~= nil)
test("system prompt mentions components cmd", sp:find("components") ~= nil)
test("system prompt no json_query", sp:find("json_query") == nil)
test("system prompt no text_ops", sp:find("text_ops") == nil)
test("system prompt no component_invoke", sp:find("component_invoke") == nil)
test("system prompt no execute_lua", sp:find("execute_lua") == nil)

-- TOOLS list: 显式期望清单，双向断言（无缺失、无多余）。
-- 新增工具时必须在此清单中登记，否则测试失败。
-- v0.3.124: 从 19 精简到 11（删 list_directory/glob/json_query/calc/
-- text_ops/component_list/component_doc/component_invoke）。
local EXPECTED_TOOLS = {
  "read_file", "write_file", "edit_file", "append_file", "search_files",
  "web_search", "shell_execute", "subagent_call", "subagent_discover", "ask_user",
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

-- ensure 大会话: 自动压缩（mock 下 compact 成功）——折叠段物理删除 + est 下降
local m3 = {}
for i = 1, 20 do
  m3[#m3 + 1] = {role = "user", content = big_content}
  m3[#m3 + 1] = {role = "assistant", content = big_content}
end
local m3_before = 0
for _, m in ipairs(m3) do
  m3_before = m3_before + agent_test.estimate_tokens(m.content or "")
end
local m3r, e3 = agent_test.ensure_context_budget(m3,
  {context_window = cfg_small.context_window, byte_budget = 99999999}, false)
-- 20 条 × 81KB: est 超 80% 窗口 → 压缩；keep 4（est 已 ≥1500 不增长）
-- → 折叠 16 条物理删除，表 = 摘要 + 4 = 5 条（不再是投影式的 m3_n+1）
test("ensure compacts big session (folded deleted)",
  m3r[1].role == "system" and tostring(m3r[1].content):find("对话摘要") ~= nil
  and e3 < m3_before and #m3r == 5,
  "#=" .. tostring(#m3r) .. " est " .. tostring(e3) .. " from " .. tostring(m3_before))

-- ensure 字节硬预算: token 未超但字节超 150KB → 裁剪早期消息（P0 修复:
-- 真机 55K tokens≈190KB 文本 encode 峰值超 OC 1.4MB 内存 → json.lua:70
-- table.concat OOM 崩溃；字节预算是独立于 token 估算的硬约束）
local m4 = {}
for i = 1, 10 do
  m4[#m4 + 1] = {role = "user", content = string.rep("x", 30000)}
end
local m4_n = #m4  -- 快照：ensure_context_budget 就地裁剪
local m4_bytes = 0
for _, m in ipairs(m4) do m4_bytes = m4_bytes + #(m.content or "") end
local m4r = agent_test.ensure_context_budget(m4,
  {context_window = 128000, byte_budget = 150000}, false)
local m4r_bytes = 0
for _, m in ipairs(m4r) do m4r_bytes = m4r_bytes + #(m.content or "") end
test("ensure byte budget trims oversized",
  m4r_bytes <= 150000 and #m4r < m4_n,
  "bytes " .. tostring(m4r_bytes) .. " from " .. tostring(m4_bytes)
    .. " msgs " .. tostring(#m4r) .. "/" .. tostring(m4_n))
test("ensure byte budget keeps head anchor", m4r[1] == m4[1],
  "head changed")

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
print("File Service (explorer proxy) Tests")
print("═══════════════════════════════════════")

-- 文件服务协议（v0.3.84）: explorer 子代理把 read_file 等经 modem 代理到
-- 主代理执行。serve 端（主代理）非阻塞轮询处理; proxy 端（子代理）发送
-- 请求等回复。此处验证两端协议（loopback 分步模拟，不真并发）。
do
local sub_mod = require("agent.subagent")
modem.open(sub_mod.FILE_PORT)
local tmp_fsrv = io.open("test_fsrv_tmp.txt", "w")
tmp_fsrv:write("FILE_SERVICE_TEST_CONTENT_12345")
tmp_fsrv:close()
-- 与 init.lua FILE_EXEC 同语义的包装（execute_tool 字符串结果 → ok,result）
local fsrv_exec = function(name, args)
  local ok2, res = pcall(execute_tool, name, json.encode(args))
  if not ok2 then return false, tostring(res) end
  if type(res) == "string" and res:sub(1, 6) == "Error:" then return false, res end
  return true, res
end
-- 清空事件队列
while true do
  local sig = {mock_event.pull(0)}
  if not sig[1] then break end
end
-- serve 端: handle_file_message 处理（TUI 推模式真实路径）→ 回传（入队
-- 回复）。注意: 不能预先入队请求（会先被 pull 拉到）也不能用
-- serve_file_requests 轮询——loopback 下回复事件会被它再当请求处理
-- （真实双机无此问题: 回复发给子代理地址，不会回到主代理端口）。
sub_mod.handle_file_message(fsrv_exec, modem.address(), sub_mod.FILE_PORT,
  json.encode({v = 1, op = "read_file", path = "test_fsrv_tmp.txt"}))
local sig = {mock_event.pull(0.5)}
local okd, reply = pcall(json.decode, sig[6])
test("file service: read_file proxied + replied",
  okd and reply and reply.ok and reply.content:find("FILE_SERVICE_TEST_CONTENT", 1, true) ~= nil,
  "reply=" .. tostring(sig[6]))
-- 安全边界: 写工具必须被拒
sub_mod.handle_file_message(fsrv_exec, modem.address(), sub_mod.FILE_PORT,
  json.encode({v = 1, op = "write_file", path = "x", content = "evil"}))
local sig2 = {mock_event.pull(0.5)}
local okd2, reply2 = pcall(json.decode, sig2[6])
test("file service: write op rejected",
  okd2 and reply2 and not reply2.ok and tostring(reply2.error):find("not allowed", 1, true) ~= nil,
  "reply=" .. tostring(sig2[6]))
-- proxy 端编码: file_proxy 发送的请求格式（mock send 捕获; wait 注入超时）
local sent = nil
local orig_send = modem.send
modem.send = function(addr, port, payload) sent = payload; return true end
local res_proxy = sub_mod.file_proxy("read_file", {path = "test_fsrv_tmp.txt"},
  {json = json, wait_modem_message = function() return nil end}, modem.address())
modem.send = orig_send
local okd3, preq = pcall(json.decode, sent)
test("file proxy: request format",
  okd3 and preq and preq.v == 1 and preq.op == "read_file" and preq.path == "test_fsrv_tmp.txt",
  "sent=" .. tostring(sent))
test("file proxy: timeout path",
  type(res_proxy) == "string" and res_proxy:find("no reply", 1, true) ~= nil,
  "res=" .. tostring(res_proxy))
os.remove("test_fsrv_tmp.txt")
modem.close(sub_mod.FILE_PORT)

print("")
print("═══════════════════════════════════════")
print("Interrupt (Ctrl+C) Tests")
print("═══════════════════════════════════════")

-- 中断支持（v0.3.86）: 可中断 os.sleep 补丁——非 Ready（chat/工具）
-- 期间 Ctrl+C 的 interrupted 事件被补丁捕获设标志; 阻塞点轮询检测。
-- 单测: 安装补丁 → 入队 interrupted → 调 os.sleep(2) → 应立即返回
-- （<2s）且 interrupt.poll() 为 true; 再验证 consume 清除。
do
  local int_mod = require("agent.interrupt")
  int_mod.install()
  -- 入队 interrupted 事件（模拟用户 Ctrl+C）
  table.insert(oc_mock._event_queue, {"interrupted"})
  local t0 = os.clock()
  os.sleep(2)
  local dt = os.clock() - t0
  test("interrupt: os.sleep returns early on Ctrl+C", dt < 1.5 and int_mod.poll(),
    "dt=" .. string.format("%.2f", dt) .. " poll=" .. tostring(int_mod.poll()))
  -- consume 清除标志
  local was = int_mod.consume()
  test("interrupt: consume returns and clears", was == true and not int_mod.poll(),
    "was=" .. tostring(was) .. " poll_after=" .. tostring(int_mod.poll()))
  -- 无事件时 os.sleep 正常等待
  local t1 = os.clock()
  os.sleep(0.05)
  test("interrupt: os.sleep normal (no event)", os.clock() - t1 >= 0.04 and not int_mod.poll(),
    "dt=" .. string.format("%.2f", os.clock() - t1))
  int_mod.clear()
end

print("")
print("═══════════════════════════════════════")
print("OpenOS Patch Layer Tests")
print("═══════════════════════════════════════")

-- OpenOS 运行时补丁层（v0.3.99, agent.patch）: 统一修补 OpenOS 缺陷。
-- 单测覆盖: P2 now() 墙钟（uptime 优先——os.clock CPU 时间残留修复）、
-- P3 pull_any 多事件匹配（OpenOS 多参=位置匹配的收敛包装）、
-- P1 install() 幂等（thread 可用时包装 internet.request，替换动作
-- 本身安全——不触发请求调用）。
do
  local patch_mod = require("agent.patch")
  -- P2: now() 可用且为数字（oc_mock computer.uptime 随时间前进）
  local ok_n, n = pcall(patch_mod.now)
  test("patch: now() returns number (uptime-based wall clock)",
    ok_n and type(n) == "number", "now=" .. tostring(ok_n and n))
  -- P3: pull_any 多事件名匹配（入队 modem_message → 应返回它;
  -- 入队 interrupted → 也应匹配）
  table.insert(oc_mock._event_queue, {"modem_message", "addr1", "addr2", 1234, 0, "payload"})
  local ev, a1, a2 = patch_mod.pull_any(2, {"interrupted", "modem_message"})
  test("patch: pull_any matches second event name",
    ev == "modem_message" and a1 == "addr1" and a2 == "addr2",
    "ev=" .. tostring(ev) .. " a1=" .. tostring(a1) .. " a2=" .. tostring(a2))
  table.insert(oc_mock._event_queue, {"interrupted"})
  local ev2 = patch_mod.pull_any(2, {"interrupted", "modem_message"})
  test("patch: pull_any matches first event name", ev2 == "interrupted",
    "ev=" .. tostring(ev2))
  -- 不匹配事件被消费（pull 即消费语义）: 入队 key_down + 入队 interrupted，
  -- pull_any(events=interrupted) 应跳过 key_down 拿到 interrupted
  table.insert(oc_mock._event_queue, {"key_down", 0, 1, 2})
  table.insert(oc_mock._event_queue, {"interrupted"})
  local ev3 = patch_mod.pull_any(2, {"interrupted"})
  test("patch: pull_any skips non-matching events", ev3 == "interrupted",
    "ev=" .. tostring(ev3))
  -- P1: install() 幂等（mock 下 thread 可用——包装动作安全，不触发请求）
  local ok_i1, r1 = pcall(patch_mod.install)
  local ok_i2, r2 = pcall(patch_mod.install)
  local ok_int2, int2 = pcall(require, "agent.interrupt")
  test("patch: install() idempotent + interrupt installed",
    ok_i1 and ok_i2 and ok_int2 and int2.installed == true,
    "i1=" .. tostring(ok_i1) .. " i2=" .. tostring(ok_i2)
    .. " interrupt=" .. tostring(ok_int2 and int2.installed))
  -- P1 常量在位
  test("patch: CONNECT_TIMEOUT constant", type(patch_mod.CONNECT_TIMEOUT) == "number",
    "ct=" .. tostring(patch_mod.CONNECT_TIMEOUT))
end

-- wait_modem_message on_other 转发（v0.3.85 死锁修复）: 主代理
-- subagent_call 等待回复期间，非回复端口的文件请求经 on_other 回调
-- 处理，不丢弃——否则 explorer 子代理等文件回复 60s / 主代理等任务
-- 回复 240s 互相等待死锁。
do
  local forwarded = 0
  local handled_req = nil
  local wm = sub_mod.wait_modem_message
  local reply_open = modem.open(9097)
  -- 入队一个"非回复端口"文件请求（模拟 explorer 子代理）
  table.insert(oc_mock._event_queue, {"modem_message", modem.address(), modem.address(), 9092, 0,
    json.encode({v = 1, op = "search_files", pattern = "zzz"})})
  -- 入队"回复端口"消息（模拟子代理任务完成）
  table.insert(oc_mock._event_queue, {"modem_message", modem.address(), modem.address(), 9097, 0,
    "REPLY_DONE"})
  local wm_s, wm_p, wm_payload = wm(5, 9097, function(sig)
    forwarded = forwarded + 1
    -- 文件请求: 用 fsrv_exec 处理（与主代理 FILE_EXEC 同语义）
    handled_req = sub_mod.handle_file_message(fsrv_exec, sig[3], sig[4], sig[6])
  end)
  test("wait_modem_message on_other: file request forwarded",
    forwarded == 1 and handled_req == true,
    "forwarded=" .. tostring(forwarded) .. " handled=" .. tostring(handled_req))
  test("wait_modem_message on_other: reply still received",
    wm_p == 9097 and wm_payload == "REPLY_DONE",
    "port=" .. tostring(wm_p) .. " payload=" .. tostring(wm_payload))
  modem.close(9097)
end
end

print("")
print("═══════════════════════════════════════")
print("Subagent Session Persistence Tests")
print("═══════════════════════════════════════")

-- session history: subagent keeps per-session JSONL histories (same format
-- as main history). Verify format + replay + path sanitization locally.
-- 跨平台 shell（2026-09-03 项目迁移 Linux 主机；原为 Windows-only cmd 语法）
local IS_WIN = package.config:sub(1, 1) == "\\"
local function sh_mkdir(d) os.execute(IS_WIN and ("mkdir " .. d .. " 2>nul")
  or ("mkdir -p " .. d .. " 2>/dev/null")) end
local function sh_rmdir(d) os.execute(IS_WIN and ("rmdir " .. d .. " 2>nul")
  or ("rmdir " .. d .. " 2>/dev/null")) end

local session_file = "test_session_temp/history.jsonl"
sh_mkdir("test_session_temp")
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
sh_rmdir("test_session_temp")

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
test("trim_history caps count", #trimmed <= 120, "#=" .. tostring(#trimmed))
local anchor2 = {}
for i = 1, 6 do
  anchor2[#anchor2 + 1] = {role = "user", content = string.rep("x", 40000) .. " m" .. i}
end
local trimmed2 = trim_history(anchor2)
test("trim_history byte cap keeps head + recent",
  trimmed2[1].content:find("m1") ~= nil and #trimmed2 == 6,
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
-- 防御: provider usage 字段可能为字符串/嵌套非表（真机曾致 statusData 回调
-- 抛错 → TUI 状态栏绘制中断，只剩 status 文本）
local h3, m3 = cs({prompt_tokens = "1000", prompt_cache_hit_tokens = "800", prompt_cache_miss_tokens = "200"})
test("cache_stats string fields safe", h3 == 800 and m3 == 200, tostring(h3) .. "/" .. tostring(m3))
test("cache_stats non-table details safe", cs({prompt_tokens = 1000, prompt_tokens_details = true}) == nil)
test("cache_stats weird details safe", cs({prompt_tokens = 1000, prompt_tokens_details = "x"}) == nil)
-- 非整除命中率: 400/446×100=89.686 → cache_stats 返回 400, 46（不四舍五入丢失）
-- （真机 bug 根因: statusData 回调曾用 %d 格式化非整数 → 抛错 → pcall 吞掉
--  → 状态栏只剩 "Ready"；show_ctx_line 用 %.0f 无此问题）
local h5, m5 = cs({prompt_tokens = 446, prompt_tokens_details = {cached_tokens = 400}})
test("cache_stats non-integer ratio", h5 == 400 and m5 == 46, tostring(h5) .. "/" .. tostring(m5))
local line3_ok, line3_text = capture_print(function()
  agent_test.show_ctx_line({prompt_tokens = 446, prompt_tokens_details = {cached_tokens = 400}},
    {context_window = 128000})
end)
test("show_ctx_line non-integer cache %", line3_ok and line3_text:find("cache 90%%") ~= nil,
  line3_text)
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

-- 任务4: REF 双标记（opencode-acp keep-markers）——[[REF:N|desc]] 展开为
-- "[消息 N] desc" 引用指针（不嵌原文）。注意: compact_history 就地变异
-- 传入表（折叠段物理删除），每个用例用全新消息列表——投影式时代的
-- "复用已折叠表"在此语义下 parts 已空（折叠段不存在），测不到展开。
local function fresh_keep_msgs()
  local t = {}
  for i = 1, 12 do
    t[#t + 1] = {role = "user", content = "msg " .. i}
  end
  t[2].content = "critical secret value: abc123"
  return t
end
agent_test.set_chat(keep_mock_chat)
keep_mock_summary = "summary [[REF:2|关键事实]] [[REF:1|次要]]"
local ref_compacted = agent_test.compact_history(fresh_keep_msgs(), {model = "m", api_key = ""})
agent_test.set_chat(agent_test.chat)
test("REF expands to pointer [消息 N] desc", ref_compacted
  and ref_compacted[1].content:find("[消息 2] 关键事实", 1, true) ~= nil
  and ref_compacted[1].content:find("[消息 1] 次要", 1, true) ~= nil,
  tostring(ref_compacted and ref_compacted[1].content or nil):sub(1, 300))
test("REF does not embed original text", ref_compacted
  and ref_compacted[1].content:find("critical secret value", 1, true) == nil,
  tostring(ref_compacted and ref_compacted[1].content or nil):sub(1, 300))

-- REF 越界引用: 保留原标记 + 不崩溃
agent_test.set_chat(keep_mock_chat)
keep_mock_summary = "s [[REF:99|越界描述]]"
local ref_oob = agent_test.compact_history(fresh_keep_msgs(), {model = "m", api_key = ""})
agent_test.set_chat(agent_test.chat)
test("REF out-of-range marker survives", ref_oob
  and ref_oob[1].content:find("[[REF:99|越界描述]]", 1, true) ~= nil,
  tostring(ref_oob and ref_oob[1].content or nil):sub(1, 200))

-- KEEP 展开在折叠段物理删除后仍然完整: expand_keep_markers 在 compact
-- 时**静态**展开（摘要 content 已含原文），折叠段随后删除不影响展开
-- 结果——KEEP 测试（展开/越界/截断）在此语义下必须保持全绿。
do
  local keep2_msgs = {}
  for i = 1, 12 do
    keep2_msgs[#keep2_msgs + 1] = {role = "user", content = "km " .. i}
  end
  keep2_msgs[2].content = "verbatim secret: xyz789"
  agent_test.set_chat(keep_mock_chat)
  keep_mock_summary = "s [[KEEP:2]]"
  local keep2 = agent_test.compact_history(keep2_msgs, {model = "m", api_key = ""})
  agent_test.set_chat(agent_test.chat)
  local keep2_folded = 0
  for _, m in ipairs(keep2) do if m.folded then keep2_folded = keep2_folded + 1 end end
  test("KEEP expansion survives fold deletion",
    keep2 and keep2[1].content:find("xyz789") ~= nil and keep2_folded == 0,
    "found=" .. tostring(keep2 and keep2[1].content:find("xyz789") ~= nil)
      .. " folded=" .. tostring(keep2_folded))
end

-- 任务4/5: 摘要指令含 REF 说明 + 七节骨架（reasonix compact 借鉴）
local section_captured = nil
local function section_mock_chat(msgs, cfg)
  if msgs and msgs[1] then section_captured = msgs[1].content end
  return {content = "ok"}
end
agent_test.set_chat(section_mock_chat)
agent_test.summarize_history(keep_msgs, {model = "m", api_key = ""})
agent_test.set_chat(agent_test.chat)
test("summary prompt instructs REF markers",
  section_captured and section_captured:find("[[REF", 1, true) ~= nil,
  tostring(section_captured):sub(1, 300))
test("summary prompt has structured sections (Standing facts)",
  section_captured and section_captured:find("Standing facts", 1, true) ~= nil
  and section_captured:find("Pending", 1, true) ~= nil
  and section_captured:find("Decisions", 1, true) ~= nil,
  tostring(section_captured):sub(1, 300))

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

-- compact_history 工具: 模型主动压缩（KEEP 标记 + 物理删除就地 + 持久化）
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
-- 15 条 + 摘要 → 折叠 7 条物理删除，表 = 摘要 + 8 = 9 条（不再是投影式
-- 的 16 条）；KEEP:1 已静态展开进摘要（"tool ctx 1" 原文）
test("compact tool deletes folded segments in place",
  tool_ctx[1].content:find("tool summary", 1, true) ~= nil
  and tool_ctx[1].content:find("tool ctx 1", 1, true) ~= nil
  and #tool_ctx == 9 and tool_folded == 0,
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

-- ── 摘要请求专用路径（瘦身 + 专用 max_tokens + 空摘要重试）──
-- v0.3.48+ 摘要请求走 chat() opts: skip_system/skip_runtime/skip_tools +
-- max_tokens=summary_max_tokens（默认 16384）——opencode 裸摘要请求同款
-- （tools 省略、无主 system prompt、无 runtime 尾块），reasonix 防递归。
do
  -- 测试1: 截获 chat HTTP 请求体 → 断言瘦身（无 tools/主 system/runtime）
  -- + 默认摘要预算 16384 + 摘要指令仍在
  local function make_summary_handle(body)
    local started = false
    local h = {}
    setmetatable(h, {
      __call = function()
        if started then return nil end
        started = true
        return body
      end,
      __index = { response = function() return 200 end },
    })
    return h
  end
  local slim_body = nil
  local slim_saved_req = internet.request
  internet.request = function(url, data, headers, method)
    if url:match("chat/completions") then
      slim_body = data
      return make_summary_handle('{"choices":[{"message":{"role":"assistant","content":"SLIM SUM"}}]}')
    end
    return slim_saved_req(url, data, headers, method)
  end
  local slim_msgs = {}
  for i = 1, 12 do
    slim_msgs[#slim_msgs + 1] = {role = "user", content = "slim " .. i}
  end
  local slim_compacted = agent_test.compact_history(slim_msgs, {model = "m", api_key = ""})
  internet.request = slim_saved_req
  test("summary request slim (no tools/system/runtime)",
    slim_compacted ~= nil and slim_body ~= nil
    and slim_body:find('"tools"', 1, true) == nil
    and slim_body:find("AI assistant running inside OpenComputers", 1, true) == nil
    and slim_body:find("[runtime status", 1, true) == nil
    and slim_body:find("Summarize this conversation", 1, true) ~= nil
    and slim_body:find('"max_tokens":16384', 1, true) ~= nil,
    "body=" .. tostring(slim_body and slim_body:sub(1, 300)))

  -- 测试2: config.summary_max_tokens 覆盖 → 摘要请求 max_tokens=2048
  local max_body = nil
  internet.request = function(url, data, headers, method)
    if url:match("chat/completions") then
      max_body = data
      return make_summary_handle('{"choices":[{"message":{"role":"assistant","content":"M"}}]}')
    end
    return slim_saved_req(url, data, headers, method)
  end
  local max_msgs = {}
  for i = 1, 12 do
    max_msgs[#max_msgs + 1] = {role = "user", content = "mx " .. i}
  end
  agent_test.compact_history(max_msgs, {model = "m", api_key = "", summary_max_tokens = 2048})
  internet.request = slim_saved_req
  test("summary max_tokens config (summary_max_tokens)",
    max_body ~= nil and max_body:find('"max_tokens":2048', 1, true) ~= nil,
    "body=" .. tostring(max_body and max_body:sub(1, 300)))
end

-- 空摘要兜底: thinking 模型 reasoning 挤占输出预算 → content 空 →
-- 注入"直接输出摘要"提示重试一次；仍空 → compact_history 返回 nil
-- （调用方走 trim 兜底，不阻断压缩流程）
do
  local retry_msgs = {}
  for i = 1, 12 do
    retry_msgs[#retry_msgs + 1] = {role = "user", content = "retry " .. i}
  end
  -- 测试3: 第一次空（仅 reasoning）→ 第二次给摘要 → compact 成功
  local attempts = 0
  local function empty_then_ok(msgs, cfg, opts)
    attempts = attempts + 1
    if attempts == 1 then
      return {content = nil, reasoning_content = "thinking...", finish_reason = "stop"}
    end
    return {content = "retried summary text"}
  end
  agent_test.set_chat(empty_then_ok)
  local retried = agent_test.compact_history(retry_msgs, {model = "m", api_key = ""})
  agent_test.set_chat(agent_test.chat)
  test("summary empty content retries once",
    attempts == 2 and retried ~= nil
    and retried[1].content:find("retried summary text", 1, true) ~= nil,
    "attempts=" .. tostring(attempts)
      .. " compacted=" .. tostring(retried and retried[1] and retried[1].content):sub(1, 120))

  -- 测试4: 两次都空 → compact_history 返回 nil（trim 兜底路径）
  local attempts2 = 0
  local function always_empty(msgs, cfg, opts)
    attempts2 = attempts2 + 1
    return {content = nil, reasoning_content = "thinking...", finish_reason = "stop"}
  end
  agent_test.set_chat(always_empty)
  local nil_compacted = agent_test.compact_history(retry_msgs, {model = "m", api_key = ""})
  agent_test.set_chat(agent_test.chat)
  test("summary empty twice falls back to nil (trim path)",
    attempts2 == 2 and nil_compacted == nil,
    "attempts=" .. tostring(attempts2)
      .. " compacted=" .. tostring(nil_compacted ~= nil))
end

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
  {role = "user", content = string.rep("x", 90000), folded = true},
  {role = "user", content = string.rep("y", 90000), folded = true},
  {role = "user", content = string.rep("z", 90000), folded = true},
  {role = "user", content = string.rep("w", 90000), folded = true},
  {role = "user", content = "recent 1"},
  {role = "user", content = "recent 2"},
}
local trim_proj_out = agent_test.trim_history(trim_proj)
test("trim reclaims folded segments first",
  trim_proj_out[1].content == "head anchor"
  and trim_proj_out[#trim_proj_out].content == "recent 2"
  and #trim_proj_out == 7,  -- 360K 超 300K 预算 → 删 1 条折叠（90000）→ 270K 内
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
-- v0.3.124: head/grep/wget 是 OpenOS 1.8.9 真实命令（真机 59 命令集实证），
-- 护栏不再拦截 → 断言"放行"（结果非 rejected by guard）。
local function guard_allows(cmd)
  local r = try_shell(cmd)
  return type(r) == "string" and r:find("rejected by guard", 1, true) == nil
end
test("guard allows head (OpenOS has it)", guard_allows("head -3 file"))
test("guard rejects tail", try_shell("tail -5 log.txt"):find("rejected by guard", 1, true) ~= nil)
test("guard allows grep (OpenOS Wobbo port)", guard_allows("grep -rn foo /mnt"))
test("guard rejects wc", try_shell("wc -l file.lua"):find("rejected by guard", 1, true) ~= nil)
test("guard rejects curl", try_shell("curl https://example.com"):find("rejected by guard", 1, true) ~= nil)
test("guard allows wget (OpenOS has it)", guard_allows("wget http://x"))
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
  -- 键盘浏览模式（v0.3.109 P1-1）: 有历史 → 进入（browseMode=true）; 无历史 → 提示不进入
  local ok_browse1 = pcall(tui_mod.enterBrowse)
  test("tui.enterBrowse with history safe", ok_browse1)
  tui_mod.init()  -- 清空历史（init 重置 state）
  local ok_browse2 = pcall(tui_mod.enterBrowse)
  test("tui.enterBrowse empty history safe", ok_browse2)
  -- 搜索（v0.3.109 P1-3）: 命中 → 跳转+高亮; 未命中 → 清 search 状态
  tui_mod.init()
  tui_mod.print("alpha beta gamma")
  tui_mod.print("delta beta epsilon")
  local ok_s1 = pcall(tui_mod.search, "beta")
  test("tui.search finds match", ok_s1)
  local ok_s2 = pcall(tui_mod.search, "nonexistent_token_xyz")
  test("tui.search no match safe", ok_s2)
  local ok_s3 = pcall(tui_mod.searchNext, 1)
  test("tui.searchNext safe", ok_s3)
  local ok_s4 = pcall(tui_mod.searchNext, -1)
  test("tui.searchNext backward safe", ok_s4)
  local ok_s5 = pcall(tui_mod.search, "")
  test("tui.search empty pattern safe", ok_s5)
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
  -- printHistory: 会话历史填充内容区（完整显示/跳过 folded/角色色/顺序）
  tui_mod.init()
  -- 真实语料: 仓库 README.md 全文（真实存在，避免假长字符串）
  local real_text = ""
  do
    local rf = io.open("../README.md", "r")
    if rf then
      real_text = rf:read("*a") or ""
      rf:close()
    end
  end
  local ph_msgs = {
    {role = "system", content = "[对话摘要] 摘要内容"},
    {role = "user", content = "历史问题1"},
    {role = "user", content = "折叠消息", folded = true},
    {role = "assistant", content = real_text},
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
  -- 完整显示: assistant 长文本（真实 README 语料）不被截断
  -- wrapText 折行会归一化连续空白（缩进/多空格→单空格），但绝不丢
  -- 非空白字符 → 去空白规范化后应与原文一致（字节数会因空白归一化变小，
  -- 不能直接比长度）
  local ph0b = #tui_mod.history()
  pcall(tui_mod.printHistory, {{role = "assistant", content = real_text}})
  local phb_joined = ""
  for i = ph0b + 1, #tui_mod.history() do
    phb_joined = phb_joined .. tui_mod.history()[i].text
  end
  local norm = function(s) return tostring(s):gsub("%s+", "") end
  local full_kept = norm(phb_joined) == norm(real_text)
  test("printHistory keeps full content", full_kept,
    "real=" .. tostring(#real_text) .. " shown=" .. tostring(#phb_joined))
  -- 中文完整显示: README 含中文，无乱码/无截断残留
  local ok_cjk_clean = ph_joined:find("%z") == nil and ph_joined:find("�") == nil
  test("printHistory cjk full display clean", ok_cjk_clean, ph_joined:sub(-20))
  -- 清理
  pcall(tui_mod.cleanup)
end

print("")
print("═══════════════════════════════════════")
print("Content Selection (v0.3.100) Tests")
print("═══════════════════════════════════════")

-- 内容区选中（v0.3.100）: touch/drag 内容区 → 选中矩形 → 反色高亮 →
-- Ctrl+C / drop 复制 → gpu.get 读回 → state.clipboard + onCopy 回调
-- （写 selected.txt，/debug gist 附带）。mock gpu 无缓冲（get 返回 0），
-- 验证安全路径 + onCopy 注入 + 空选区 nil。
do
  local ok_tui2, tui_mod2 = pcall(require, "agent.tui")
  -- 1. onCopy 注入: config.onCopy → tui.onCopy
  local captured = nil
  local copy_fn = function(text) captured = text end
  pcall(tui_mod2.init, {onCopy = copy_fn})
  test("csel: onCopy injected from config", tui_mod2.onCopy == copy_fn,
    "onCopy=" .. tostring(tui_mod2.onCopy == copy_fn))
  -- 2. 无选中时 copyContentSelection 安全返回 nil（不崩）
  local ok_ccs, ccs_res = pcall(tui_mod2.copyContentSelection)
  test("csel: copy without selection returns nil safely",
    ok_ccs and ccs_res == nil,
    "ok=" .. tostring(ok_ccs) .. " res=" .. tostring(ccs_res))
  -- 3. 清除无选中安全
  local ok_clr = pcall(tui_mod2.clearContentSelection)
  test("csel: clear without selection safe", ok_clr)
  -- 4. mock gpu 无缓冲: 强制设 csel 后 copy → readContentSelection 全空
  --    → nil（安全路径，不崩）。通过 init 后直接操作（内部 state 不可
  --    直接访问——用 readInput 事件模拟不可行，验证对外 API 安全即可）
  pcall(tui_mod2.cleanup)
end

print("")
print("═══════════════════════════════════════")
print("TUI Mouse Render Regression (v0.3.110) Tests")
print("═══════════════════════════════════════")

-- 模拟鼠标渲染回归（真机 bug ① drawRow nil 崩溃 ② 字体全黑 ③ 搜索
-- 高亮 usub bug）: 独立文件 tui_mouse_render_test.lua 以 dofile 接入。
-- 文件内部使用自己的 PASS/FAIL 计数，返回 pass, fail 由本运行器累加。
do
  _IN_RUN_TESTS = true
  local ok_mr, p_mr, f_mr = pcall(dofile, "tui_mouse_render_test.lua")
  _IN_RUN_TESTS = nil
  if ok_mr and type(p_mr) == "number" then
    test("tui mouse render test file runs", true)
    pass = pass + p_mr
    fail = fail + f_mr
  else
    test("tui mouse render test file runs", false, tostring(p_mr))
  end
end

-- v0.3.112 输入框多行 + 滚轮防闪烁回归（任务 A/B）: 独立文件
-- tui_input_scroll_test.lua 以 dofile 接入（同鼠标渲染测试模式）。
do
  _IN_RUN_TESTS = true
  local ok_is, p_is, f_is = pcall(dofile, "tui_input_scroll_test.lua")
  _IN_RUN_TESTS = nil
  if ok_is and type(p_is) == "number" then
    test("tui input scroll test file runs", true)
    pass = pass + p_is
    fail = fail + f_is
  else
    test("tui input scroll test file runs", false, tostring(p_is))
  end
end

print("")
print("═══════════════════════════════════════")
print("Tool Loop Guards (chat 层借鉴) Tests")
print("═══════════════════════════════════════")

-- 脚本化 chat 响应: 按序返回 mock LLM 响应（tool_calls / reasoning-only /
-- 空回答 / length 截断）。用法: 设置 next_llm 表，然后 process_exchange。
local next_llm = nil
local llm_idx = 0
local orig_request = internet.request
internet.request = function(url, data, headers, method)
  if next_llm and type(next_llm[llm_idx + 1]) == "table" then
    llm_idx = llm_idx + 1
    local body = json.encode(next_llm[llm_idx])
    local started = false
    local handle = {}
    setmetatable(handle, {
      __call = function()
        if started then return nil end
        started = true
        return body
      end,
      __index = { response = function() return 200 end },
    })
    return handle
  end
  return orig_request(url, data, headers, method)
end
local function llm_tool_calls(calls, finish)
  return {choices = {{message = {role = "assistant", content = nil, tool_calls = calls},
    finish_reason = finish or "stop"}}}
end
local function llm_content(content, reasoning, finish)
  local msg = {role = "assistant", content = content}
  if reasoning then msg.reasoning_content = reasoning end
  return {choices = {{message = msg, finish_reason = finish or "stop"}}}
end

-- ── 内存压力物理裁剪（fix-5 根因修复: 真机两次 OOM）──
-- free 内存低谷（< mem_compact_threshold 默认 400KB）时 process_exchange
-- 开头**物理裁剪**历史（trim_to_bytes 到 mem_trim_bytes 默认 60KB，释放
-- 内存）——v0.3.45 的投影式折叠（folded 不删除）只缩小请求体不释放内存，
-- 93.6KB JSONL 解析后表 ~300KB 驻留，free 低谷 encode 仍爆（第二次 OOM）。
-- 语义分层: 窗口超限（ensure_context_budget 80% / 模型 compact_history）
-- → 折叠（保缓存）；内存紧张（mem_pressure）→ 物理裁剪（保命）。
do
  -- 测试1: 内存低谷 → 物理裁剪（#减少 + 字节 ≤ 阈值 + 锚点/最近保留）
  -- mock 序列模拟真实环境（v0.3.56+）: 前两次调用（enforce_memory 采样
  -- + mem_pressure 检查）返回低谷 100KB → 触发裁剪；裁剪后
  -- collectgarbage 强制 GC 归还 Lua 堆，freeMemory 回升（第三次起
  -- 返回 2MB）——chat() 的 encode 前估算检查（est*3 > free*0.85）
  -- 在真实回升后通过。恒定 100KB 的旧 mock 制造了"裁剪后仍低谷"
  -- 的虚假场景，会误伤 encode 防护（gist 852193 第 8 次 OOM 加固）。
  local saved_free = computer.freeMemory
  local free_calls = 0
  computer.freeMemory = function()
    free_calls = free_calls + 1
    if free_calls <= 2 then return 100000 end  -- 低谷（触发裁剪）
    return 2000000                            -- GC 后回升
  end
  local mp_msgs = {}
  for i = 1, 60 do
    mp_msgs[#mp_msgs + 1] = {role = "user", content = string.rep("m", 10000) .. i}
  end
  local mp_first = mp_msgs[1]
  next_llm = {
    llm_content("最终回答", nil, "stop"),  -- 物理裁剪不调 summarize，主循环单轮
  }
  llm_idx = 0
  local mp_res = agent_test.process_exchange(mp_msgs,
    {model = "m", api_key = "", api_url = "https://example.test/chat/completions",
     context_window = 128000, mem_trim_bytes = 60000,
     mem_prefold_bytes = 999999999}, "new question", false)  -- 关自动折叠，隔离 mem_pressure 路径
  computer.freeMemory = saved_free
  next_llm = nil
  local mp_bytes = 0
  for _, m in ipairs(mp_msgs) do mp_bytes = mp_bytes + #(m.content or "") end
  test("mem pressure: trims physically on low memory",
    #mp_msgs < 10 and mp_bytes <= 60000,
    "#=" .. tostring(#mp_msgs) .. " bytes=" .. tostring(mp_bytes))
  test("mem pressure: anchor message kept",
    mp_msgs[1] == mp_first, "anchor replaced")
  test("mem pressure: keeps recent user message",
    mp_msgs[#mp_msgs - 1] and mp_msgs[#mp_msgs - 1].content == "new question",
    tostring(mp_msgs[#mp_msgs - 1] and mp_msgs[#mp_msgs - 1].content))
  test("mem pressure: exchange completes after trim",
    mp_res and mp_res.text == "最终回答",
    tostring(mp_res and (mp_res.text or mp_res.error)))

  -- 测试2: 内存充足 → 不裁剪（messages 原样 + 末尾 user 追加）
  local saved_free2 = computer.freeMemory
  computer.freeMemory = function() return 2000000 end  -- 2MB > 400KB 阈值
  local mp2 = {}
  for i = 1, 10 do
    mp2[#mp2 + 1] = {role = "user", content = "old message " .. i}
  end
  next_llm = {
    llm_content("正常回答", nil, "stop"),
  }
  llm_idx = 0
  local mp2_res = agent_test.process_exchange(mp2,
    {model = "m", api_key = "", api_url = "https://example.test/chat/completions",
     context_window = 128000}, "new question", false)
  computer.freeMemory = saved_free2
  next_llm = nil
  local mp2_folded = false
  for _, m in ipairs(mp2) do if m.folded then mp2_folded = true break end end
  test("mem pressure: no trim when memory ok",
    #mp2 == 12 and not mp2_folded and mp2[1].role == "user",
    "#=" .. tostring(#mp2) .. " folded=" .. tostring(mp2_folded))
  test("mem pressure: ok-memory exchange completes",
    mp2_res and mp2_res.text == "正常回答",
    tostring(mp2_res and (mp2_res.text or mp2_res.error)))
end

-- 测试3: computer 缺失/异常环境安全（不崩、不裁剪——OC 兼容）
do
  local saved_comp = package.loaded["computer"]
  local saved_comp_global = _G.computer
  package.loaded["computer"] = nil
  _G.computer = nil
  local ok_mp, mp_val = pcall(agent_test.mem_pressure, {})
  package.loaded["computer"] = saved_comp
  _G.computer = saved_comp_global
  test("mem pressure: safe without computer (returns false)",
    ok_mp and mp_val == false,
    "ok=" .. tostring(ok_mp) .. " val=" .. tostring(mp_val))

  -- freeMemory 缺失 / 抛错 / 非数字 → 一律 false（不阻塞任何环境）
  local saved_free3 = computer.freeMemory
  computer.freeMemory = nil
  test("mem pressure: false when freeMemory missing",
    agent_test.mem_pressure({}) == false)
  computer.freeMemory = function() error("boom") end
  test("mem pressure: false when freeMemory throws",
    agent_test.mem_pressure({}) == false)
  computer.freeMemory = function() return "abc" end
  test("mem pressure: false when freeMemory non-number",
    agent_test.mem_pressure({}) == false)
  computer.freeMemory = saved_free3
end

-- 测试4: load_history 内存上限（93.6KB JSONL 全量加载 → 表 ~300KB 根因）
-- 解析期条数上限（保留最近 120 条）+ 字节上限（mem_load_budget 默认
-- 100KB）——JSONL 文件 append-only 完整保留，只限内存表。
do
  local lh_path = "test_load_budget.txt"
  local lf = io.open(lh_path, "w")
  for i = 1, 150 do
    lf:write(json.encode({role = "user", content = string.rep("L", 2000) .. i}), "\n")
  end
  lf:close()
  local saved_path = agent_test.current_session_path()
  agent_test.set_history_path(lh_path)
  local lh = agent_test.load_history()
  agent_test.set_history_path(saved_path)
  os.remove(lh_path)
  local lh_bytes = 0
  for _, m in ipairs(lh) do lh_bytes = lh_bytes + #(m.content or "") end
  test("load history bounded (≤120, bytes ≤200KB)",
    #lh <= 120 and lh_bytes <= 200000,
    "#=" .. tostring(#lh) .. " bytes=" .. tostring(lh_bytes))
  test("load history keeps recent",
    lh[#lh] and lh[#lh].content == string.rep("L", 2000) .. "150",
    tostring(lh[#lh] and lh[#lh].content and lh[#lh].content:sub(-10)))
  test("load history keeps head anchor",
    lh[1] and type(lh[1].content) == "string",
    tostring(lh[1] and lh[1].content and lh[1].content:sub(1, 20)))
end

-- ── 传统自动压缩（opencode 模式，字节阈值驱动）──
-- 表字节 > mem_prefold_bytes（默认 100KB）→ process_exchange 请求前
-- 系统自动折叠（compact_history），不等模型调 compact_history 工具
-- （模型需 ≥60% 窗口才自觉，OC 内存下永远到不了——真机 24K tokens
-- 只占窗口 19%）。折叠段物理回收后表字节真实下降；mem_pressure 内存
-- 阈值兜底仍在其后（本组测试内存充足不触发）。mock 需 2 个 LLM 响应:
-- 第一个被 summarize 消耗，第二个是主循环。
do
  -- 测试1: 40 条 × 3KB ≈ 120KB > 100KB → 自动折叠 + 摘要消息出现
  local ab_msgs = {}
  for i = 1, 40 do
    ab_msgs[#ab_msgs + 1] = {role = "user", content = string.rep("a", 3000) .. i}
  end
  next_llm = {
    llm_content("自动压缩摘要", nil, "stop"),  -- summarize 消耗
    llm_content("最终回答", nil, "stop"),      -- 主循环
  }
  llm_idx = 0
  local ab_res = agent_test.process_exchange(ab_msgs,
    {model = "m", api_key = "", api_url = "https://example.test/chat/completions",
     context_window = 128000}, "new question", false)
  next_llm = nil
  local ab_has_summary = ab_msgs[1] and ab_msgs[1].role == "system"
    and tostring(ab_msgs[1].content):find("对话摘要") ~= nil
  test("auto compact triggers by bytes (fold on >100KB)",
    ab_has_summary and #ab_msgs <= 9 and ab_res and ab_res.text == "最终回答",
    "summary=" .. tostring(ab_has_summary) .. " #=" .. tostring(#ab_msgs)
      .. " res=" .. tostring(ab_res and (ab_res.text or ab_res.error)))

  -- 测试2: mem_prefold_bytes=50000 → 25×2.5KB≈62.5KB 即触发（默认 100KB
  -- 下不触发）——config 可配验证
  local ac_msgs = {}
  for i = 1, 25 do
    ac_msgs[#ac_msgs + 1] = {role = "user", content = string.rep("c", 2500) .. i}
  end
  next_llm = {
    llm_content("自动压缩摘要", nil, "stop"),
    llm_content("回答", nil, "stop"),
  }
  llm_idx = 0
  local ac_res = agent_test.process_exchange(ac_msgs,
    {model = "m", api_key = "", api_url = "https://example.test/chat/completions",
     context_window = 128000, mem_prefold_bytes = 50000}, "q", false)
  next_llm = nil
  local ac_has_summary = ac_msgs[1] and ac_msgs[1].role == "system"
    and tostring(ac_msgs[1].content):find("对话摘要") ~= nil
  test("auto compact respects config (mem_prefold_bytes)",
    ac_has_summary and ac_res and ac_res.text == "回答",
    "summary=" .. tostring(ac_has_summary)
      .. " res=" .. tostring(ac_res and (ac_res.text or ac_res.error)))
end

-- 任务1: 工具轮次上限——超过 max_tool_steps 后注入提示，再做一次请求
do
  next_llm = {
    llm_tool_calls({{id = "call_1", type = "function",
      ["function"] = {name = "read_file", arguments = '{"expression":"1+1"}'}}}),
    llm_tool_calls({{id = "call_2", type = "function",
      ["function"] = {name = "read_file", arguments = '{"expression":"2+2"}'}}}),
    llm_tool_calls({{id = "call_3", type = "function",
      ["function"] = {name = "read_file", arguments = '{"expression":"3+3"}'}}}),
    llm_content("最终答案"),
  }
  llm_idx = 0
  local cap_msgs = {}
  local cap_res = agent_test.process_exchange(cap_msgs,
    {model = "m", api_key = "", api_url = "https://example.test/chat/completions",
     context_window = 128000, max_tool_steps = 2}, "测试", false)
  local cap_joined = ""
  for _, m in ipairs(cap_msgs) do
    if m.content and type(m.content) == "string" then cap_joined = cap_joined .. m.content end
  end
  test("tool cap: final answer returned", cap_res and cap_res.text == "最终答案",
    tostring(cap_res and cap_res.text))
  test("tool cap: notice message injected", cap_joined:find("已达到工具调用轮次上限", 1, true) ~= nil,
    cap_joined:sub(1, 300))
  test("tool cap: 2 tool rounds executed before notice",
    (function()
      local tools = 0
      for _, m in ipairs(cap_msgs) do if m.role == "tool" then tools = tools + 1 end end
      return tools == 2, "tools=" .. tostring(tools)
    end)())
  next_llm = nil
end

-- 静默停滞 nudge（v0.3.122 重设计）: 默认 12 轮零文本工具轮注入一次进度
-- 提醒（旧默认 5 轮催收尾，真机实证会拦腰打断正当长工具链）;
-- 文案改为"汇报进展后可继续"; 有可见输出 → 重新武装（每段静默链提醒一次）。
do
  -- 测试1: 默认阈值——12 轮静默触发一次，13 轮收尾
  local st_resp = {}
  for i = 1, 12 do
    st_resp[i] = llm_tool_calls({{id = "call_" .. i, type = "function",
      ["function"] = {name = "read_file", arguments = '{"expression":"' .. i .. '+1"}'}}})
  end
  st_resp[13] = llm_content("最终答案")
  next_llm = st_resp
  llm_idx = 0
  local st_msgs = {}
  local st_res = agent_test.process_exchange(st_msgs,
    {model = "m", api_key = "", api_url = "https://example.test/chat/completions",
     context_window = 128000}, "测试", false)
  local nudges = 0
  for _, m in ipairs(st_msgs) do
    if m.role == "user" and type(m.content) == "string"
        and m.content:find("没有任何可见输出", 1, true) then
      nudges = nudges + 1
    end
  end
  test("stall nudge: 12 silent tool rounds trigger once (default)",
    st_res and st_res.text == "最终答案" and nudges == 1,
    "nudges=" .. tostring(nudges) .. " res=" .. tostring(st_res and st_res.text))
  next_llm = nil
end

do
  -- 测试2: config 覆盖阈值 + 叙述轮重置并重新武装——rounds=2 时
  -- 静默2轮→nudge#1，叙述1轮（重置+再武装），静默2轮→nudge#2
  -- （参数逐轮变化，避免误触 doom-loop 护栏）
  local with_tool = function(i)
    return {choices = {{message = {role = "assistant", content = nil,
      tool_calls = {{id = "call_" .. i, type = "function",
        ["function"] = {name = "read_file", arguments = '{"expression":"' .. i .. '+1"}'}}}},
      finish_reason = "stop"}}}
  end
  local narrated = function(i, text)
    return {choices = {{message = {role = "assistant", content = text,
      tool_calls = {{id = "call_" .. i, type = "function",
        ["function"] = {name = "read_file", arguments = '{"expression":"' .. i .. '+1"}'}}}},
      finish_reason = "stop"}}}
  end
  next_llm = {
    with_tool(1),                 -- r1 静默 count=1
    with_tool(2),                 -- r2 count=2 → nudge#1（工具仍执行）
    narrated(3, "进展汇报"),       -- r3 有文本 → 重置 + 重新武装
    with_tool(4),                 -- r4 count=1
    with_tool(5),                 -- r5 count=2 → nudge#2（再武装生效）
    llm_content("最终答案"),       -- 收尾
  }
  llm_idx = 0
  local st2_msgs = {}
  local st2_res = agent_test.process_exchange(st2_msgs,
    {model = "m", api_key = "", api_url = "https://example.test/chat/completions",
     context_window = 128000, stall_nudge_rounds = 2}, "测试", false)
  local nudges2 = 0
  for _, m in ipairs(st2_msgs) do
    if m.role == "user" and type(m.content) == "string"
        and m.content:find("没有任何可见输出", 1, true) then
      nudges2 = nudges2 + 1
    end
  end
  test("stall nudge: config override + re-arm after narration",
    st2_res and st2_res.text and st2_res.text:find("最终答案", 1, true) ~= nil
      and nudges2 == 2,
    "nudges=" .. tostring(nudges2) .. " res=" .. tostring(st2_res and st2_res.text))
  next_llm = nil
end

do
  -- 测试3: 每轮都带文本的工具链永不触发（叙述即不算静默停滞）
  local narrated2 = function(i, text)
    return {choices = {{message = {role = "assistant", content = text,
      tool_calls = {{id = "call_" .. i, type = "function",
        ["function"] = {name = "read_file", arguments = '{"expression":"' .. i .. '+1"}'}}}},
      finish_reason = "stop"}}}
  end
  next_llm = {
    narrated2(1, "第1步"),
    narrated2(2, "第2步"),
    llm_content("最终答案"),
  }
  llm_idx = 0
  local st3_msgs = {}
  local st3_res = agent_test.process_exchange(st3_msgs,
    {model = "m", api_key = "", api_url = "https://example.test/chat/completions",
     context_window = 128000, stall_nudge_rounds = 2}, "测试", false)
  local nudges3 = 0
  for _, m in ipairs(st3_msgs) do
    if m.role == "user" and type(m.content) == "string"
        and m.content:find("没有任何可见输出", 1, true) then
      nudges3 = nudges3 + 1
    end
  end
  test("stall nudge: narrated tool rounds never trigger",
    st3_res and st3_res.text and st3_res.text:find("最终答案", 1, true) ~= nil
      and nudges3 == 0,
    "nudges=" .. tostring(nudges3) .. " res=" .. tostring(st3_res and st3_res.text))
  next_llm = nil
end

-- 任务1 触顶收尾: 触顶后的最后请求仍返回 tool_calls → 丢弃只取 content
do
  next_llm = {
    llm_tool_calls({{id = "call_1", type = "function",
      ["function"] = {name = "read_file", arguments = '{"expression":"1+1"}'}}}),
    llm_tool_calls({{id = "call_2", type = "function",
      ["function"] = {name = "read_file", arguments = '{"expression":"2+2"}'}}}),
    llm_tool_calls({{id = "call_3", type = "function",
      ["function"] = {name = "read_file", arguments = '{"expression":"3+3"}'}}}),
    llm_tool_calls({{id = "call_4", type = "function",
      ["function"] = {name = "read_file", arguments = '{"expression":"4+4"}'}}}),
  }
  llm_idx = 0
  local cap_msgs2 = {}
  local cap_res2 = agent_test.process_exchange(cap_msgs2,
    {model = "m", api_key = "", api_url = "https://example.test/chat/completions",
     context_window = 128000, max_tool_steps = 2}, "测试", false)
  local cap_tools2 = 0
  for _, m in ipairs(cap_msgs2) do if m.role == "tool" then cap_tools2 = cap_tools2 + 1 end end
  test("tool cap: final tool_calls dropped, only 2 tools run", cap_tools2 == 2,
    "tools=" .. tostring(cap_tools2))
  test("tool cap: no final text → error", cap_res2 and cap_res2.error and
    cap_res2.error:find("轮次上限", 1, true) ~= nil,
    tostring(cap_res2 and cap_res2.error))
  next_llm = nil
end

-- ── 重复调用检测（doom-loop 护栏，opencode 借鉴）──
-- 测试1: 连续 5 轮同一工具调用（同 name 同 args）→ 第 4 轮出现 loop 错误、
-- 本轮工具不执行（前 3 轮已执行）；第 5 轮含 content → 丢弃 tool_calls 收尾
do
  next_llm = {
    llm_tool_calls({{id = "call_1", type = "function",
      ["function"] = {name = "read_file", arguments = '{"expression":"1+1"}'}}}),
    llm_tool_calls({{id = "call_2", type = "function",
      ["function"] = {name = "read_file", arguments = '{"expression":"1+1"}'}}}),
    llm_tool_calls({{id = "call_3", type = "function",
      ["function"] = {name = "read_file", arguments = '{"expression":"1+1"}'}}}),
    llm_tool_calls({{id = "call_4", type = "function",
      ["function"] = {name = "read_file", arguments = '{"expression":"1+1"}'}}}),
    -- 第 5 轮: 仍返回同一调用 + 附带 content（模拟模型被提示后给出回答）
    {choices = {{message = {role = "assistant", content = "收尾回答",
      tool_calls = {{id = "call_5", type = "function",
        ["function"] = {name = "read_file", arguments = '{"expression":"1+1"}'}}}},
      finish_reason = "stop"}}},
  }
  llm_idx = 0
  local lp_msgs = {}
  local lp_res = agent_test.process_exchange(lp_msgs,
    {model = "m", api_key = "", api_url = "https://example.test/chat/completions",
     context_window = 128000}, "测试", false)
  next_llm = nil
  local loop_errs = 0
  local calc_runs = 0
  for _, m in ipairs(lp_msgs) do
    if m.role == "tool" and tostring(m.content):find("repeated tool call detected", 1, true) ~= nil then
      loop_errs = loop_errs + 1
    elseif m.role == "tool" then
      calc_runs = calc_runs + 1
    end
  end
  test("loop detect: loop error message injected", loop_errs == 1,
    "loop_errs=" .. tostring(loop_errs))
  test("loop detect: tool executed only in first 3 rounds", calc_runs == 3,
    "calc_runs=" .. tostring(calc_runs))
  test("loop detect: final content ends the exchange", lp_res and not lp_res.error
    and lp_res.text == "收尾回答", tostring(lp_res and (lp_res.text or lp_res.error)))
end

-- 测试2: 重复检测只提示一次（loop 错误消息仅出现 1 次，不重复轰炸）
do
  next_llm = {
    llm_tool_calls({{id = "call_1", type = "function",
      ["function"] = {name = "read_file", arguments = '{"expression":"2+2"}'}}}),
    llm_tool_calls({{id = "call_2", type = "function",
      ["function"] = {name = "read_file", arguments = '{"expression":"2+2"}'}}}),
    llm_tool_calls({{id = "call_3", type = "function",
      ["function"] = {name = "read_file", arguments = '{"expression":"2+2"}'}}}),
    llm_tool_calls({{id = "call_4", type = "function",
      ["function"] = {name = "read_file", arguments = '{"expression":"2+2"}'}}}),
    llm_tool_calls({{id = "call_5", type = "function",
      ["function"] = {name = "read_file", arguments = '{"expression":"2+2"}'}}}),
    llm_content("完成了", nil, "stop"),
  }
  llm_idx = 0
  local sw_msgs = {}
  local sw_res = agent_test.process_exchange(sw_msgs,
    {model = "m", api_key = "", api_url = "https://example.test/chat/completions",
     context_window = 128000}, "测试", false)
  next_llm = nil
  local sw_errs = 0
  for _, m in ipairs(sw_msgs) do
    if m.role == "tool" and tostring(m.content):find("repeated tool call detected", 1, true) ~= nil then
      sw_errs = sw_errs + 1
    end
  end
  test("loop detect: warned exactly once (no repeat spam)", sw_errs == 1,
    "sw_errs=" .. tostring(sw_errs))
  test("loop detect: 5th identical call hard-stops (content 空 → error)",
    sw_res and sw_res.error and sw_res.error:find("重复调用", 1, true) ~= nil,
    tostring(sw_res and (sw_res.error or sw_res.text)))
  next_llm = nil
end

-- 测试3: 正常探索（12 轮不同工具调用）不触发轮次上限（默认 40）也不误判循环
do
  local explore = {}
  -- v0.3.124: 换成 3 个仍存在的只读工具（不同 name+args 以规避循环检测）
  local names = {"read_file", "search_files", "read_file"}
  local args = {
    '{"path":"/a"}',
    '{"pattern":"x"}',
    '{"path":"/b"}',
  }
  for i = 1, 12 do
    explore[#explore + 1] = llm_tool_calls({{id = "call_" .. i, type = "function",
      ["function"] = {name = names[((i - 1) % 3) + 1],
        arguments = args[((i - 1) % 3) + 1]}}})
  end
  explore[#explore + 1] = llm_content("探索完成", nil, "stop")
  next_llm = explore
  llm_idx = 0
  local ex_msgs = {}
  local ex_res = agent_test.process_exchange(ex_msgs,
    {model = "m", api_key = "", api_url = "https://example.test/chat/completions",
     context_window = 128000}, "测试", false)
  next_llm = nil
  local ex_joined = ""
  local ex_tools = 0
  local ex_loop = 0
  for _, m in ipairs(ex_msgs) do
    if m.content and type(m.content) == "string" then ex_joined = ex_joined .. m.content end
    if m.role == "tool" then ex_tools = ex_tools + 1 end
    if m.role == "tool" and tostring(m.content):find("repeated tool call detected", 1, true) then
      ex_loop = ex_loop + 1
    end
  end
  test("exploration: 12 distinct tool calls all execute", ex_tools == 12,
    "ex_tools=" .. tostring(ex_tools))
  test("exploration: no cap notice (default 40 not reached)", ex_joined:find("轮次上限", 1, true) == nil,
    ex_joined:sub(1, 200))
  test("exploration: no false loop detection", ex_loop == 0,
    "ex_loop=" .. tostring(ex_loop))
  test("exploration: final answer returned", ex_res and ex_res.text == "探索完成",
    tostring(ex_res and ex_res.text))
end

-- 任务2 情形 A: reasoning-only 轮（content 空 + reasoning 非空 + finish=stop）
-- → 无可见回答时注入重试消息一次（与情形 B 共用 retried_empty 网），
-- 重试后仍空才返回 placeholder（修复：此前直接接受导致真机对话静默停止）
do
  -- A1: 首次 reasoning-only → 重试 → 第二次给出可见回答 → 正常返回
  next_llm = {
    llm_content(nil, "让我想想这个问题的解法", "stop"),
    llm_content("这是重试后的真正回答", nil, "stop"),
  }
  llm_idx = 0
  local ro_msgs = {}
  local ro_res = agent_test.process_exchange(ro_msgs,
    {model = "m", api_key = "", api_url = "https://example.test/chat/completions",
     context_window = 128000}, "测试", false)
  local ro_joined = ""
  for _, m in ipairs(ro_msgs) do
    if m.content and type(m.content) == "string" then ro_joined = ro_joined .. m.content end
  end
  test("reasoning-only: retry message injected", ro_joined:find("只产出了思考内容", 1, true) ~= nil,
    ro_joined:sub(1, 200))
  test("reasoning-only: final answer after retry", ro_res and ro_res.text == "这是重试后的真正回答",
    tostring(ro_res and (ro_res.error or ro_res.text)))

  -- A2: 两次 reasoning-only（重试后仍空）→ 返回 placeholder
  next_llm = {
    llm_content(nil, "思考一", "stop"),
    llm_content(nil, "思考二", "stop"),
  }
  llm_idx = 0
  local ro2_msgs = {}
  local ro2_res = agent_test.process_exchange(ro2_msgs,
    {model = "m", api_key = "", api_url = "https://example.test/chat/completions",
     context_window = 128000}, "测试", false)
  test("reasoning-only: placeholder after retry exhausted", ro2_res and ro2_res.content and
    ro2_res.content:find("仅产出思考", 1, true) ~= nil,
    tostring(ro2_res and (ro2_res.content or ro2_res.text)))
  next_llm = nil
end

-- TUI 内容区清理 reasoning: REPL 模式（UI_INPUT=nil）必须保留打印
-- （防过度修复——TUI 跳过路径靠真机验证，本地 UI_INPUT 为模块级 local 不可注入）
do
  next_llm = {
    llm_content("可见回答", "思考内容XYZ防过度修复", "stop"),
  }
  llm_idx = 0
  local ok_cap, cap_text = capture_print(function()
    local msgs_rs = {}
    agent_test.process_exchange(msgs_rs,
      {model = "m", api_key = "", api_url = "https://example.test/chat/completions",
       context_window = 128000}, "测试", false)
  end)
  test("repl mode keeps reasoning print", ok_cap and
    cap_text:find("思考内容XYZ防过度修复", 1, true) ~= nil,
    cap_text:sub(1, 200))
  next_llm = nil
end

-- 任务2 情形 B: 纯空回答 → 注入重试消息一次，第二次正常返回
do
  next_llm = {
    llm_content(nil, nil, "stop"),   -- 空回答
    llm_content("这是真正的答案", nil, "stop"),
  }
  llm_idx = 0
  local er_msgs = {}
  local er_res = agent_test.process_exchange(er_msgs,
    {model = "m", api_key = "", api_url = "https://example.test/chat/completions",
     context_window = 128000}, "测试", false)
  local er_joined = ""
  for _, m in ipairs(er_msgs) do
    if m.content and type(m.content) == "string" then er_joined = er_joined .. m.content end
  end
  test("empty reply: retry message injected once", er_joined:find("你的回复内容为空", 1, true) ~= nil,
    er_joined:sub(1, 200))
  test("empty reply: final answer after retry", er_res and er_res.text == "这是真正的答案",
    tostring(er_res and er_res.text))
  next_llm = nil
end

-- 任务3: finish_reason=length 截断 → 不执行残缺工具调用，注入错误结果让模型修正
do
  next_llm = {
    llm_tool_calls({{id = "call_1", type = "function",
      ["function"] = {name = "read_file", arguments = '{"expression":"1'}}}, "length"),
    llm_content("修正后的最终回答", nil, "stop"),
  }
  llm_idx = 0
  local tl_msgs = {}
  local tl_res = agent_test.process_exchange(tl_msgs,
    {model = "m", api_key = "", api_url = "https://example.test/chat/completions",
     context_window = 128000}, "测试", false)
  local tl_joined = ""
  local tl_calc_ran = false
  for _, m in ipairs(tl_msgs) do
    if m.content and type(m.content) == "string" then tl_joined = tl_joined .. m.content end
    if m.role == "tool" and tostring(m.content):find("truncated", 1, true) ~= nil then
      tl_calc_ran = true
    end
  end
  test("length-truncated: tool NOT executed, truncated error injected", tl_calc_ran,
    tl_joined:sub(1, 300))
  test("length-truncated: model corrects and answers", tl_res and tl_res.text == "修正后的最终回答",
    tostring(tl_res and tl_res.text))
  next_llm = nil
end

-- ── 截断机制（exp-1 审计修复）: head+tail 双保 + UTF-8 安全 ──
-- 任务1: 超长工具结果 >3000 字节（含中文）→ head(1500)+tail(1500) 都保留、
-- UTF-8 边界不被劈裂（head 之后/原串的下一字节不是续字节，tail 首字节不是
-- 续字节）、标记含 truncated/bytes + 续读提示
do
  -- 大文件: 前半 ASCII + 中间大量中文 + 结尾哨兵，总长 >3000 <20000
  local big_path = "test_trunc_big.txt"
  local head_sentinel = "HEAD_START_MARKER_"
  local tail_sentinel = "_TAIL_END_MARKER"
  local body = string.rep("ab", 200) .. string.rep("中", 900) .. string.rep("cd", 200)
  local big_content = head_sentinel .. body .. tail_sentinel
  local fw = io.open(big_path, "w")
  fw:write(big_content)
  fw:close()
  local is_cont = function(b) return b and b >= 0x80 and b <= 0xBF end

  -- 用 mock LLM 驱动 read_file（走 process_exchange 的 3000 字节截断路径）
  next_llm = {
    llm_tool_calls({{id = "call_1", type = "function",
      ["function"] = {name = "read_file", arguments = json.encode({path = big_path})}}}),
    llm_content("读完了", nil, "stop"),
  }
  llm_idx = 0
  local trunc_msgs = {}
  local trunc_res = agent_test.process_exchange(trunc_msgs,
    {model = "m", api_key = "", api_url = "https://example.test/chat/completions",
     context_window = 128000}, "测试", false)
  next_llm = nil

  local tool_content = nil
  for _, m in ipairs(trunc_msgs) do
    if m.role == "tool" and tostring(m.content):find("truncated", 1, true) ~= nil then
      tool_content = m.content
    end
  end
  local got_marker = tool_content ~= nil
  local head_ok = got_marker and tool_content:find(head_sentinel, 1, true) ~= nil
  local tail_ok = got_marker and tool_content:find(tail_sentinel, 1, true) ~= nil
  -- UTF-8 安全: head 是原串前缀，其"后一字节"在原串中不是续字节（即切点恰好
  -- 落在字符边界上——head 可以以完整多字节字符的末字节结尾，那正是续字节，
  -- 所以判据看的是切点之后而不是 head 末字节）；tail 首字节不能是续字节。
  local utf8_ok = false
  if got_marker then
    local marker_idx = tool_content:find("\n...\n[truncated ", 1, true)
    local head_part = marker_idx and tool_content:sub(1, marker_idx - 1) or ""
    local after = marker_idx and tool_content:find("\n...\n", marker_idx + 1, true) or nil
    local tail_part = after and tool_content:sub(after + 4) or ""
    -- head 后一字节在原串中:
    local next_byte = big_content:byte(#head_part + 1)
    -- tail 首字节（若 tail_part 非空）
    local tb = tail_part:byte(1)
    utf8_ok = not is_cont(next_byte) and (tb == nil or not is_cont(tb))
  end
  os.remove(big_path)
  test("truncate: head+tail both kept", head_ok and tail_ok,
    tostring(tool_content and tool_content:sub(1, 120) or "nil"))
  test("truncate: marker has bytes + truncated", got_marker
    and tool_content:find("truncated", 1, true) ~= nil
    and tool_content:find("bytes", 1, true) ~= nil,
    tostring(tool_content and tool_content:sub(1, 200) or "nil"))
  test("truncate: UTF-8 boundaries not split", utf8_ok,
    tostring(got_marker and tool_content:sub(1, 60) or "no marker"))
  test("truncate: file tools get continuation hint with path",
    got_marker and tool_content:find("use read_file with offset/limit", 1, true) ~= nil
    and tool_content:find(big_path, 1, true) ~= nil,
    tostring(tool_content and tool_content:sub(1, 300) or "nil"))
  test("truncate: exchange still returns final answer", trunc_res
    and trunc_res.text == "读完了", tostring(trunc_res and trunc_res.text))
end

-- 任务2: read_file 默认读超限（>400 行）→ 尾注续读指引；offset 续读可拿后续
do
  local rl_path = "test_readcap.txt"
  local rl = {}
  for i = 1, 450 do rl[i] = "caprow " .. i end
  local fw = io.open(rl_path, "w")
  fw:write(table.concat(rl, "\n"))
  fw:close()
  local rl_res = execute_tool("read_file", json.encode({path = rl_path}))
  local rl_cont = execute_tool("read_file",
    json.encode({path = rl_path, offset = 401, limit = 10}))
  os.remove(rl_path)
  test("read_file cap: note tells offset continuation",
    type(rl_res) == "string" and rl_res:find("truncated: showing first 400 lines", 1, true) ~= nil
    and rl_res:find("use read_file with offset=401", 1, true) ~= nil,
    tostring(rl_res and rl_res:sub(-120)))
  test("read_file cap: offset=401 continues reading",
    type(rl_cont) == "string" and rl_cont:find("401. caprow 401", 1, true) ~= nil
    and rl_cont:find("410. caprow 410", 1, true) ~= nil,
    tostring(rl_cont and rl_cont:sub(1, 120)))
end

-- 任务3: search_files 超长行（>200 字节含中文）→ [line truncated 标记 + 无乱码
do
  local sf_path = "test_search_long.txt"
  local long_line = string.rep("x", 80) .. string.rep("中", 60) .. string.rep("y", 100)
  local fw = io.open(sf_path, "w")
  fw:write("needle " .. long_line .. "\n")
  fw:write("other line\n")
  fw:close()
  local sf_res = execute_tool("search_files",
    json.encode({pattern = "needle", path = sf_path, max_line_length = 200}))
  os.remove(sf_path)
  test("search_files: long line gets truncation marker",
    type(sf_res) == "string" and sf_res:find("[line truncated at 200]", 1, true) ~= nil,
    tostring(sf_res and sf_res:sub(1, 300)))
  test("search_files: marker line keeps head content, no torn UTF-8",
    type(sf_res) == "string" and sf_res:find("needle ", 1, true) ~= nil
    and sf_res:find(string.rep("x", 60), 1, true) ~= nil
    and not sf_res:find("\239\191\189"),
    tostring(sf_res and sf_res:sub(1, 300)))
end

internet.request = orig_request

print("")
print("═══════════════════════════════════════")
print("Sessions & Scroll Command Tests")
print("═══════════════════════════════════════")

do  -- 包裹成块: 主 chunk 局部变量贴 200 上限时 VM 寄存器错乱（boolean 当函数调）
  -- list_sessions: 扫描会话目录的 *.jsonl（/new 归档 .txt 不列入）
  local sdir = "test_sessions_tmp"
  sh_mkdir(sdir)
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
  local exit7 = agent_test.handle_command("/browse", cmd_cfg, cmd_msgs)
  test("/browse without TUI prints hint", not exit7)
  local exit8 = agent_test.handle_command("/search hello", cmd_cfg, cmd_msgs)
  test("/search without TUI prints hint", not exit8)
  local exit9 = agent_test.handle_command("/snext", cmd_cfg, cmd_msgs)
  test("/snext without TUI prints hint", not exit9)
  -- 清理
  os.remove(sdir .. "/alpha.jsonl")
  os.remove(sdir .. "/beta.jsonl")
  os.remove(sdir .. "/archive.txt")
  os.execute("rmdir " .. sdir .. " 2>nul")
end

-- ═══════════════════════════════════════════
-- /resume: 恢复历史消息（pi session-picker / reasonix --resume 语义）
--   ① 按名恢复命名会话（消息加载 + 持久化路径切换）
--   ② 序号越界 / 未知名 → 报错且不动当前会话
--   ③ 序号恢复（default 夹具在列与否动态探测；须在 ④ 前跑——
--      ④ 产生的 agent_history_100.jsonl 会插到 alpha 前面）
--   ④ /new 归档 .txt → 迁移为同名 .jsonl 并恢复，.txt 保留
--   ⑤ 归档二次恢复 → 续写既有 jsonl（保留恢复后新增的消息）
-- 注意: 主 chunk 局部变量贴近 200 上限——本节用 IIFE 包裹（零新增
-- main chunk 局部变量），块内一律复用局部名。
-- ═══════════════════════════════════════════
(function()
  local rdir = "test_resume_tmp"
  local saved_sdir = agent_test.get_sessions_dir()
  local saved_path = agent_test.current_session_path()
  local rcfg, rmsgs, mm = {model = "m", api_key = ""}, {{role = "user", content = "current"}}, nil
  agent_test.set_sessions_dir(rdir)
  os.execute("mkdir " .. rdir .. " 2>nul")

  local f_a = io.open(rdir .. "/alpha.jsonl", "w")
  f_a:write(json.encode({role = "user", content = "alpha question"}) .. "\n")
  f_a:write(json.encode({role = "assistant", content = "alpha answer"}) .. "\n")
  f_a:close()
  local f_arch = io.open(rdir .. "/agent_history_100.txt", "w")
  f_arch:write(serialization.serialize({
    {role = "user", content = "archived question"},
    {role = "assistant", content = "archived answer"},
  }))
  f_arch:close()

  -- ① 按名恢复命名会话
  mm = select(3, agent_test.handle_command("/resume alpha", rcfg, rmsgs))
  test("/resume <name> loads named session",
    type(mm) == "table" and #mm == 2 and mm[1].content == "alpha question"
    and agent_test.current_session_path() == rdir .. "/alpha.jsonl",
    tostring(agent_test.current_session_path()) .. " #=" .. tostring(mm and #mm))

  -- ② 序号越界 → 不动当前会话
  mm = select(3, agent_test.handle_command("/resume 99", rcfg, rmsgs))
  test("/resume <n> out of range keeps session",
    mm == rmsgs and agent_test.current_session_path() == rdir .. "/alpha.jsonl",
    tostring(agent_test.current_session_path()))

  -- ③ 序号恢复: default 条目在列与否取决于 HISTORY_PATH 夹具 → 动态探测
  do
    local listed = false
    local f = io.open("./agent_history.txt", "r")
    if f then
      for line in f:lines() do
        local ok_j, m = pcall(json.decode, line)
        if ok_j and type(m) == "table" and m.role then listed = true break end
      end
      f:close()
    end
    mm = select(3, agent_test.handle_command("/resume " .. (listed and 2 or 1), rcfg, rmsgs))
    test("/resume <n> loads by index",
      type(mm) == "table" and #mm == 2 and mm[1].content == "alpha question",
      "#=" .. tostring(mm and #mm))
  end

  -- ④ 归档恢复: .txt → .jsonl 迁移
  mm = select(3, agent_test.handle_command("/resume agent_history_100", rcfg, rmsgs))
  do
    local jlines = 0
    local jf = io.open(rdir .. "/agent_history_100.jsonl", "r")
    if jf then
      for line in jf:lines() do
        local ok_j, m = pcall(json.decode, line)
        if ok_j and type(m) == "table" and m.role then jlines = jlines + 1 end
      end
      jf:close()
    end
    test("/resume archive migrates to jsonl",
      type(mm) == "table" and #mm == 2 and mm[1].content == "archived question"
      and jlines == 2 and agent_test.current_session_path() == rdir .. "/agent_history_100.jsonl",
      "#=" .. tostring(mm and #mm) .. " jlines=" .. tostring(jlines)
      .. " path=" .. tostring(agent_test.current_session_path()))
    test("/resume archive keeps .txt", io.open(rdir .. "/agent_history_100.txt", "r") ~= nil,
      "txt missing")
  end

  -- ⑤ 二次恢复归档 → 续写 jsonl（不覆盖恢复后新增消息）
  agent_test.append_history({role = "user", content = "post-resume followup"})
  mm = select(3, agent_test.handle_command("/resume agent_history_100", rcfg, rmsgs))
  test("/resume archive twice continues jsonl",
    type(mm) == "table" and #mm == 3 and mm[3].content == "post-resume followup",
    "#=" .. tostring(mm and #mm))

  -- 未知名报错
  mm = select(3, agent_test.handle_command("/resume ghost", rcfg, rmsgs))
  test("/resume unknown name keeps session", mm == rmsgs, tostring(mm == rmsgs))

  -- 清理
  agent_test.set_sessions_dir(saved_sdir)
  agent_test.set_history_path(saved_path)
  os.remove(rdir .. "/alpha.jsonl")
  os.remove(rdir .. "/agent_history_100.txt")
  os.remove(rdir .. "/agent_history_100.jsonl")
  os.execute("rmdir " .. rdir .. " 2>nul")
end)()

-- ═══════════════════════════════════════════
-- debug 报告: 无全局/模块 computer 时不崩
-- （真机 OpenOS 无全局 computer——此前 :59 直接 pcall(computer.uptime)
--  参数求值崩溃；oc_mock 注入了全局 computer 掩盖了该 bug）
-- ═══════════════════════════════════════════
do
  local dbg_ok, dbg_mod = pcall(require, "agent.debug")
  if dbg_ok and type(dbg_mod) == "table" then
    local saved_date = os.date
    local saved_comp_global = _G.computer
    local saved_comp_loaded = package.loaded["computer"]
    -- 伪造 RTC 缺失（os.date 返回 epoch 1970）→ 触发 uptime 回退分支；
    -- 同时移除全局与模块 computer → 真机场景
    os.date = function() return "1970-01-01 00:00:00" end
    _G.computer = nil
    package.loaded["computer"] = nil
    local ok_collect, report = pcall(dbg_mod.collect, {model = "m"}, {})
    os.date = saved_date
    _G.computer = saved_comp_global
    package.loaded["computer"] = saved_comp_loaded
    test("debug.collect survives missing computer", ok_collect,
      tostring(report))
    if ok_collect then
      test("debug.collect uptime fallback placeholder", tostring(report):find("uptime %?") ~= nil,
        tostring(report):match("Generated: [^\n]*"))
    end
  else
    test("debug.collect survives missing computer", true, "agent.debug unavailable, skipped")
  end
end

print("")
print("═══════════════════════════════════════")
print(string.format("FINAL: %d pass, %d fail out of %d tests", pass, fail, pass + fail))
print("═══════════════════════════════════════")

os.exit(fail > 0 and 1 or 0)
