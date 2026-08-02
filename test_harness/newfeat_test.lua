-- ocvm verification for new features: json_query/calc/text_ops tools,
-- compaction, and retry-enabled http_post (via chat with mock-free real API)
-- NOTE: OpenOS lua has no `arg` global; use varargs.
local base = ...
if base == nil then base = "/mnt/df4" end
_TEST_MODE = true
local ok, err = pcall(dofile, base .. "/agent.lua")
if not ok then
  print("LOAD FAILED: " .. tostring(err))
  os.exit(1)
end
local computer = require("computer")
local compact_history = agent_test.compact_history
local should_compact = agent_test.should_compact
local chat = agent_test.chat
if not _TEST_MODE then
  print("agent.lua must be loaded with _TEST_MODE = true")
  os.exit(1)
end

local out = {}
local function log(s) out[#out + 1] = tostring(s) end

-- 1) json_query
log("json_query scalar: " .. execute_tool("json_query", '{"json":"{\\"name\\":\\"oc\\",\\"count\\":3}","path":"name"}'))
log("json_query array: " .. execute_tool("json_query", '{"json":"{\\"hits\\":[{\\"t\\":\\"a\\"},{\\"t\\":\\"b\\"}]}","path":"hits.1.t"}'))
log("json_query obj:   " .. execute_tool("json_query", '{"json":"{\\"d\\":{\\"x\\":[1,2,3]}}","path":"d.x"}'))
log("json_query bad:   " .. execute_tool("json_query", '{"json":"nope","path":"a"}'))
log("json_query miss:  " .. execute_tool("json_query", '{"json":"{\\"a\\":1}","path":"z.q"}'))

-- 2) calc
log("calc 2+3*4:       " .. execute_tool("calc", '{"expression":"2+3*4"}'))
log("calc (2+3)*4:     " .. execute_tool("calc", '{"expression":"(2+3)*4"}'))
log("calc 2^10:        " .. execute_tool("calc", '{"expression":"2^10"}'))
log("calc sqrt+floor:  " .. execute_tool("calc", '{"expression":"sqrt(16)+floor(3.7)"}'))
log("calc min/max:     " .. execute_tool("calc", '{"expression":"min(3,7)+max(1,9)"}'))
log("calc 1e3:         " .. execute_tool("calc", '{"expression":"1e3+1"}'))
log("calc bad:         " .. execute_tool("calc", '{"expression":"2+*"}'))

-- 3) text_ops
log("text upper:       " .. execute_tool("text_ops", '{"op":"upper","text":"hi"}'))
log("text replace:     " .. execute_tool("text_ops", '{"op":"replace","text":"a-b-c","arg1":"-","arg2":"+"}'))
log("text split:       " .. execute_tool("text_ops", '{"op":"split","text":"x\\ny\\nz"}'))
log("text slice:       " .. execute_tool("text_ops", '{"op":"slice","text":"hello world","arg1":"7","arg2":"5"}'))
log("text find:        " .. execute_tool("text_ops", '{"op":"find","text":"hello","arg1":"lo"}'))
log("text bad op:      " .. execute_tool("text_ops", '{"op":"nope","text":"x"}'))

-- 4) execute_lua removed
log("execute_lua gone: " .. execute_tool("execute_lua", '{"code":"return 1"}'))

-- 5) compaction with REAL API (deepseek free) if key/url provided
local key = select(2, ...) or ""
local model = select(3, ...) or "deepseek-v4-flash-free"
local url = select(4, ...) or "https://opencode.ai/zen/v1/chat/completions"
local config = {api_key = key, model = model, api_url = url}

log("")
log("== compaction ==")
local big = {}
for i = 1, 24 do
  big[#big + 1] = {role = "user", content = "fake conversation message number " .. i .. " about memory limits and components"}
end
local t0 = computer.uptime()
local compacted = compact_history(big, config)
if compacted then
  log("compact OK: " .. #compacted .. " msgs (was 24), first role=" .. compacted[1].role)
  log("summary: " .. tostring(compacted[1].content):sub(1, 200))
  log("last kept: " .. tostring(compacted[#compacted].content):sub(1, 60))
else
  log("compact FAILED (nil) after " .. string.format("%.1f", computer.uptime() - t0) .. "s")
end

-- 6) should_compact triggers
log("should_compact(18 msgs): " .. tostring(should_compact(big)))
log("should_compact(3 msgs):  " .. tostring(should_compact({{role="u",content="a"},{role="u",content="b"},{role="u",content="c"}})))

-- 7) chat end-to-end through retry-enabled http_post
log("")
log("== chat e2e ==")
local resp = chat({{role = "user", content = "Reply with exactly: PONG_OK"}}, config)
if resp.error then
  log("chat error: " .. resp.error)
else
  log("chat reply: " .. tostring(resp.content))
  log("finish: " .. tostring(resp.finish_reason))
end

local f = io.open(base .. "/newfeat_test.txt", "w")
f:write(table.concat(out, "\n"))
f:close()
print("DONE - results in " .. base .. "/newfeat_test.txt")
