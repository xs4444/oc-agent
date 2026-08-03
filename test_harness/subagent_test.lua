-- Subagent integration test for ocvm dual-instance networking.
-- Machine A (master): sends a task to Machine B via modem.
-- Machine B (subagent): runs `lua agent.lua -- --subagent`, listens on 9090.
-- Both share ocvm system port 56000 → same game network.
-- USAGE (on master A): lua subagent_test.lua <base> <subagent_modem_addr>
local base = ...
if base == nil then base = "/mnt/df4" end
local target = select(2, ...)
if not target or target == "" then
  print("usage: lua subagent_test.lua <base> <subagent_modem_addr>")
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
log("modem available: " .. tostring(modem ~= nil))
if not modem then
  local f = io.open(base .. "/subagent_test.txt", "w")
  f:write(table.concat(out, "\n"))
  f:close()
  print("DONE - no modem")
  os.exit(0)
end
local my_addr = type(modem.address) == "string" and modem.address or "?"
log("master modem addr: " .. my_addr)
log("target subagent addr: " .. target)

-- open reply port, send request, wait for reply
local reply_port = 9091
local listen_port = 9090
local ok_open = pcall(modem.open, reply_port)
log("reply port open: " .. tostring(ok_open))

local request = json.encode({
  v = 1,
  id = "test1",
  role = "delegate",
  task = "Reply with exactly: SUBAGENT_PONG and nothing else. Do not use tools.",
  context = ""
})
log("request bytes: " .. #request)
local sent_ok, sent_err = pcall(modem.send, target, listen_port, request)
log("send ok: " .. tostring(sent_ok) .. " err=" .. tostring(sent_err))

-- wait for reply via event.pull (yields; OC-safe)
local event = require("event")
local waited = 0
local reply = nil
while waited < 90 do
  local sig = {event.pull(1, "modem_message")}
  if sig[1] == "modem_message" then
    local port = sig[4]
    local payload = sig[6]
    if port == reply_port and type(payload) == "string" then
      reply = payload
      break
    end
  end
  waited = waited + 1
end
log("reply received: " .. tostring(reply ~= nil) .. " after " .. waited .. "s")
if reply then
  local okj, data = pcall(json.decode, reply)
  log("reply parse: " .. tostring(okj))
  if okj then
    log("reply.ok=" .. tostring(data.ok) .. " id=" .. tostring(data.id))
    log("reply.result=" .. tostring(data.result))
    log("reply.error=" .. tostring(data.error))
  end
end

local f = io.open(base .. "/subagent_test.txt", "w")
f:write(table.concat(out, "\n"))
f:close()
print("DONE - results in " .. base .. "/subagent_test.txt")
