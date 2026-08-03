-- Subagent session-reuse integration test (ocvm dual-instance).
-- Machine A sends TWO tasks with the SAME session id to Machine B:
--   task 1: "remember the secret word is OPENCORE"
--   task 2: "what was the secret word I told you?"
-- Task 2 must recall it → proves session history persisted + reloaded.
-- Usage: lua subagent_session_test.lua <base> <subagent_modem_addr>
local base = ...
if base == nil then base = "/mnt/df4" end
local target = select(2, ...)
if not target or target == "" then
  print("usage: lua subagent_session_test.lua <base> <subagent_modem_addr>")
  os.exit(1)
end
_TEST_MODE = true
local ok, err = pcall(dofile, base .. "/agent.lua")
if not ok then
  print("LOAD FAILED: " .. tostring(err))
  os.exit(1)
end

local out = {}
local function log(s) out[#out + 1] = tostring(s) end

local comp = require("component")
local modem = comp.modem
if not modem then
  log("no modem")
  local f = io.open(base .. "/subagent_session_test.txt", "w")
  f:write(table.concat(out, "\n"))
  f:close()
  os.exit(0)
end
local reply_port = 9091
local listen_port = 9090
pcall(modem.open, reply_port)
local event = require("event")

local function send_task(task_text, session_id)
  local request = json.encode({v = 1, id = tostring(os.clock and os.clock() or 0), role = "delegate", task = task_text, session = session_id or "", context = ""})
  local sent = pcall(modem.send, target, listen_port, request)
  log("send task(" .. tostring(session_id) .. ") ok=" .. tostring(sent))
  -- wait for reply (up to 120s each; subagent calls real LLM)
  local waited = 0
  while waited < 120 do
    local sig = {event.pull(1, "modem_message")}
    if sig[1] == "modem_message" and sig[4] == reply_port then
      local okj, data = pcall(json.decode, sig[6] or "")
      if okj and type(data) == "table" then
        return data
      end
    end
    waited = waited + 1
  end
  return {ok = false, error = "timeout"}
end

-- Round 1: no session (fresh)
local r1 = send_task("Reply with exactly: ROUND1_OK and nothing else.", "")
log("round1 ok=" .. tostring(r1.ok) .. " result=" .. tostring(r1.result) .. " err=" .. tostring(r1.error))

-- Round 2: session 's1', tell it a secret
local r2 = send_task("Remember this secret word: OPENCORE. Reply with exactly: REMEMBERED.", "s1")
log("round2 ok=" .. tostring(r2.ok) .. " result=" .. tostring(r2.result) .. " err=" .. tostring(r2.error))

-- Round 3: session 's1' again — must recall the secret (context preserved)
local r3 = send_task("What is the secret word I told you? Reply with exactly the secret word and nothing else.", "s1")
log("round3 ok=" .. tostring(r3.ok) .. " result=" .. tostring(r3.result) .. " err=" .. tostring(r3.error))
log("SESSION_RECALL=" .. tostring(r3.ok == true and r3.result and r3.result:find("OPENCORE") ~= nil))

-- Round 4: fresh session (no session) must NOT know the secret
local r4 = send_task("Do you know any secret word? Reply with exactly: NO_SECRET if you don't know one.", "")
log("round4 ok=" .. tostring(r4.ok) .. " result=" .. tostring(r4.result) .. " err=" .. tostring(r4.error))
log("SESSION_ISOLATION=" .. tostring(r4.ok == true and r4.result and r4.result:find("NO_SECRET") ~= nil))

local f = io.open(base .. "/subagent_session_test.txt", "w")
f:write(table.concat(out, "\n"))
f:close()
print("DONE - results in " .. base .. "/subagent_session_test.txt")
