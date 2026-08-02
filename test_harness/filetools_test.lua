-- ocvm verification for file tool family: read_file line-slices,
-- edit_file, append_file, and append-only session log round-trip.
local base = ...
if base == nil then base = "/mnt/df4" end
_TEST_MODE = true
local ok, err = pcall(dofile, base .. "/agent.lua")
if not ok then
  print("LOAD FAILED: " .. tostring(err))
  os.exit(1)
end
local computer = require("computer")

local out = {}
local function log(s) out[#out + 1] = tostring(s) end

-- 1) read_file line slices
local p = "/tmp/filetools_test.txt"
local f = io.open(p, "w")
local lines = {}
for i = 1, 20 do lines[i] = "data line " .. i end
f:write(table.concat(lines, "\n"))
f:close()
log("whole: " .. (#execute_tool("read_file", '{"path":"' .. p .. '"}') > 0 and "ok" or "FAIL"))
log("offset 3: " .. execute_tool("read_file", '{"path":"' .. p .. '","offset":3}'))
log("offset+limit: " .. execute_tool("read_file", '{"path":"' .. p .. '","offset":10,"limit":2}'))
log("tail -3: " .. execute_tool("read_file", '{"path":"' .. p .. '","offset":-3}'))
log("beyond: " .. execute_tool("read_file", '{"path":"' .. p .. '","offset":100}'))

-- 2) edit_file
log("edit: " .. execute_tool("edit_file", '{"path":"' .. p .. '","old_string":"data line 1","new_string":"FIRST"}'))
log("edit multi no replace_all: " .. execute_tool("edit_file", '{"path":"' .. p .. '","old_string":"data line","new_string":"row"}'))
log("edit replace_all: " .. execute_tool("edit_file", '{"path":"' .. p .. '","old_string":"row","new_string":"rowdata","replace_all":true}'))
log("edit applied: " .. execute_tool("read_file", '{"path":"' .. p .. '","offset":1,"limit":1}'))
-- replace_all success path on a dedicated small file (previous steps above
-- intentionally fail uniqueness checks; this one must succeed)
local sp = "/tmp/edit_success.txt"
local sf = io.open(sp, "w")
sf:write("aa bb aa bb\n")
sf:close()
log("edit replace_all ok: " .. execute_tool("edit_file", '{"path":"' .. sp .. '","old_string":"aa","new_string":"XX","replace_all":true}'))
log("edit replace_all verify: " .. execute_tool("read_file", '{"path":"' .. sp .. '"}'))
log("edit unique ok: " .. execute_tool("edit_file", '{"path":"' .. sp .. '","old_string":"bb","new_string":"YY"}'))
log("edit unique verify: " .. execute_tool("read_file", '{"path":"' .. sp .. '"}'))
log("edit not found: " .. execute_tool("edit_file", '{"path":"' .. sp .. '","old_string":"zzz","new_string":"n"}'))

-- 3) append_file
log("append: " .. execute_tool("append_file", '{"path":"' .. p .. '","content":"\\nAPPENDED LINE"}'))
log("append read tail: " .. execute_tool("read_file", '{"path":"' .. p .. '","offset":-1}'))
log("append new file: " .. execute_tool("append_file", '{"path":"/tmp/append_new.txt","content":"hello world"}'))
log("append new read: " .. execute_tool("read_file", '{"path":"/tmp/append_new.txt"}'))

-- 4) append-only session log: write messages, reload, verify replay
log("")
log("== session log ==")
local hist = base .. "/test_history.log"
local append_history = agent_test.append_history
local load_history = agent_test.load_history
local rebuild_history = agent_test.rebuild_history
agent_test.set_history_path(hist)
append_history({role = "user", content = "hello agent"})
append_history({role = "assistant", content = "hi user"})
append_history({role = "tool", tool_call_id = "tc1", content = "some result"})
local replayed = load_history()
log("replayed count: " .. #replayed)
if #replayed == 3 then
  log("msg1: " .. replayed[1].role .. "=" .. tostring(replayed[1].content))
  log("msg2: " .. replayed[2].role .. "=" .. tostring(replayed[2].content))
  log("msg3: " .. replayed[3].role .. "=" .. tostring(replayed[3].tool_call_id))
end
-- rebuild after compaction-like event
rebuild_history({{role = "system", content = "[摘要] test"}, {role = "user", content = "q"}})
local r2 = load_history()
log("after rebuild: " .. #r2 .. " msgs, first=" .. r2[1].role .. ", last=" .. tostring(r2[#r2].content))
-- legacy migrate: write serialization whole-table format, load should convert
local ser = require("serialization")
local legacy = base .. "/test_legacy.log"
local lf = io.open(legacy, "w")
lf:write(ser.serialize({{role = "user", content = "old1"}, {role = "assistant", content = "old2"}}))
lf:close()
agent_test.set_history_path(legacy)
local r3 = load_history()
log("legacy migrate: " .. #r3 .. " msgs, " .. tostring(r3[1].content) .. "/" .. tostring(r3[2].content))
local mlf = io.open(legacy, "r")
local mc = mlf:read("*a")
mlf:close()
log("legacy now JSON lines: " .. tostring(mc:find('"role"') ~= nil))

local rf = io.open(base .. "/filetools_test.txt", "w")
rf:write(table.concat(out, "\n"))
rf:close()
print("DONE - results in " .. base .. "/filetools_test.txt")
