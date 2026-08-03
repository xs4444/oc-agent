-- ═══════════════════════════════════════════════════════════════
-- agent.subagent — subagent protocol support (Phase 3 split).
--
-- Verbatim move of the old agent.lua:
--   Section 3's SUBAGENT_* constants + wait_modem_message
--   Section 8's session family (session_path / load_session_history /
--   append_session_history / rebuild_session_history)
--
-- The old code referenced the WRITABLE_BASE local and the session
-- module's trim_history directly; here those come from agent.config
-- (writable_base) and agent.session (trim_history).
-- ═══════════════════════════════════════════════════════════════

local json = require("agent.json")
local fs = require("filesystem")
local config_mod = require("agent.config")
local session_mod = require("agent.session")

-- Subagent protocol constants (used by the subagent_call tool)
local SUBAGENT_LISTEN_PORT = 9090  -- subagent's task intake port
local SUBAGENT_REPLY_PORT = 9091   -- master's reply port
local SUBAGENT_TIMEOUT = 240       -- seconds to wait for a subagent reply

-- Wait for a modem_message event (with timeout). Returns
-- (sender, port, arg1) or nil on timeout. Uses event.pull which yields.
local function wait_modem_message(timeout, reply_port)
  local event = require("event")
  local waited = 0
  local step = 0.5
  while timeout == nil or waited < timeout do
    local sig = {event.pull(step, "modem_message")}
    if sig[1] == "modem_message" then
      local sender = sig[3]
      local port = sig[4]
      -- sig[2] is receiver address, sig[3] sender, sig[4] port
      if reply_port == nil or port == reply_port then
        return sender, port, sig[6]
      end
    end
    waited = waited + step
  end
  return nil
end

-- Subagent sessions: each subagent keeps per-session append-only histories
-- on its own disk (<writable>/subagent_sessions/<session>/history.jsonl).
-- Reusing the same session id continues the conversation; omitting it
-- starts fresh.

local function session_path(session)
  local safe = tostring(session):gsub("[^%w_%-]", "_"):sub(1, 64)
  return config_mod.writable_base .. "/subagent_sessions/" .. safe .. "/history.jsonl"
end

-- Load session history (JSONL lines, same format as main history).
local function load_session_history(session)
  local p = session_path(session)
  local fs = require("filesystem")
  if not fs.exists(p) then return {} end
  local f = io.open(p, "r")
  if not f then return {} end
  local content = f:read("*a")
  f:close()
  local messages = {}
  for line in content:gmatch("[^\r\n]+") do
    local ok2, msg = pcall(json.decode, line)
    if ok2 and type(msg) == "table" and msg.role then
      messages[#messages + 1] = msg
    end
  end
  return session_mod.trim_history(messages)
end

-- Append one message to a session history.
local function append_session_history(session, msg)
  local p = session_path(session)
  local fs = require("filesystem")
  local dir = p:match("^(.*)/[^/]+$")
  if dir then pcall(fs.makeDirectory, dir) end
  local f = io.open(p, "a")
  if not f then return end
  f:write(json.encode(msg), "\n")
  f:close()
end

-- Rebuild a session history (after compaction/trim).
local function rebuild_session_history(session, messages)
  local p = session_path(session)
  local fs = require("filesystem")
  local dir = p:match("^(.*)/[^/]+$")
  if dir then pcall(fs.makeDirectory, dir) end
  local f = io.open(p, "w")
  if not f then return end
  for _, m in ipairs(messages) do
    f:write(json.encode(m), "\n")
  end
  f:close()
end

return {
  wait_modem_message = wait_modem_message,
  session_path = session_path,
  load_session_history = load_session_history,
  append_session_history = append_session_history,
  rebuild_session_history = rebuild_session_history,
  SUBAGENT_LISTEN_PORT = SUBAGENT_LISTEN_PORT,
  SUBAGENT_REPLY_PORT = SUBAGENT_REPLY_PORT,
  SUBAGENT_TIMEOUT = SUBAGENT_TIMEOUT,
}
