-- ═══════════════════════════════════════════════════════════════
-- agent.tools.subagent — subagent_call (modem network delegation).
--
-- Module contract: exports {tools = {...}, exec = function(name, args,
-- deps)}. exec returns nil for tool names it does not handle. deps is
-- injected per call by agent.execute (from agent.lua's locals):
--   json, wait_modem_message, subagent_listen_port,
--   subagent_reply_port, subagent_timeout.
-- ═══════════════════════════════════════════════════════════════

local tools = {
  {type="function", ["function"]={
    name="subagent_call",
    description="Delegate a task to another OpenComputers computer running agent.lua in --subagent mode, connected via the modem network. Provide the target computer's modem address (get it from component_list filter='modem'), a clear task description, and optionally a role (scout/researcher/planner/worker/reviewer/oracle/delegate), a session id to continue a previous conversation on that subagent (same id = context preserved; omit for a fresh session), and background context. The subagent runs the full agent loop (own memory, own tools) and returns its final answer. Timeout 240s. Use for heavy compute, large file processing, or parallel research.",
    parameters={type="object", properties={address={type="string", description="Target modem address (component_list filter='modem')"}, task={type="string", description="Task description for the subagent"}, role={type="string", description="Optional role hint: scout, researcher, planner, worker, reviewer, oracle, delegate"}, session={type="string", description="Optional session id: same id continues the previous conversation on that subagent; omit for fresh context"}, context={type="string", description="Optional background context to pass to the subagent"}, timeout={type="number", description="Optional reply timeout in seconds (default 240)"}}, required={"address", "task"}}
  }},
}

local function exec(name, args, deps)
  if name == "subagent_call" then
    local ok, result = pcall(function()
      local json = deps.json
      local wait_modem_message = deps.wait_modem_message
      local SUBAGENT_LISTEN_PORT = deps.subagent_listen_port
      local SUBAGENT_REPLY_PORT = deps.subagent_reply_port
      local SUBAGENT_TIMEOUT = deps.subagent_timeout

      local comp = require("component")
      local modem = comp.modem
      if not modem then error("no modem (network card) component") end
      local addr = args.address
      if not addr or addr == "" then error("address is required") end
      -- allow abbreviated address: resolve to full modem address
      if #addr < 32 then
        local full
        for a, t in comp.list("modem") do
          if a:sub(1, #addr) == addr then
            full = a
            break
          end
        end
        if not full then error("no modem component matches address: " .. addr) end
        addr = full
      end

      local request_tbl = {
        v = 1,
        id = string.format("%x", (os.clock and math.floor(os.clock() * 1e6)) or math.random(1, 1e9)),
        role = args.role or "delegate",
        task = args.task or "",
        session = args.session or "",
        context = args.context or ""
      }
      local request = json.encode(request_tbl)
      -- Cap request to fit the 8192-byte modem packet limit
      if #request > 7800 then
        request = json.encode({v = 1, id = request_tbl.id, role = request_tbl.role,
          task = request_tbl.task:sub(1, 7000), context = request_tbl.context:sub(1, 500)})
      end

      -- listen for reply first, then send (avoids race: reply port must be open)
      local m_ok = pcall(modem.open, SUBAGENT_REPLY_PORT)
      if not m_ok then error("cannot open reply port " .. SUBAGENT_REPLY_PORT) end

      local sent = pcall(modem.send, addr, SUBAGENT_LISTEN_PORT, request)
      if not sent then error("modem.send failed (target reachable?)") end

      local timeout = tonumber(args.timeout) or SUBAGENT_TIMEOUT
      local sender, port, payload = wait_modem_message(timeout, SUBAGENT_REPLY_PORT)
      pcall(modem.close, SUBAGENT_REPLY_PORT)
      if not sender then
        return "subagent timeout after " .. timeout .. "s (no reply from " .. addr .. ")"
      end
      local ok_json, reply = pcall(json.decode, payload or "")
      if not ok_json or type(reply) ~= "table" then
        return "subagent reply decode failed: " .. tostring(payload):sub(1, 200)
      end
      if reply.ok then
        return tostring(reply.result or "")
      end
      return "subagent error: " .. tostring(reply.error or "unknown")
    end)
    return ok and result or ("Error: " .. tostring(result))
  end

  return nil  -- not handled by this module
end

return {tools = tools, exec = exec}
