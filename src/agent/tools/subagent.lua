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
    description="Delegate a task to another OpenComputers computer running agent.lua in --subagent mode, connected via the modem network. Provide the target computer's modem address (get it from subagent_discover — the broadcast discovery tool — or from the address the subagent printed at startup; NOTE: component_list only shows LOCAL components, remote modems are NOT listed there), a clear task description, and optionally a role (scout/researcher/planner/worker/reviewer/oracle/delegate/explorer), a session id to continue a previous conversation on that subagent (same id = context preserved; omit for a fresh session), and background context. The subagent runs the full agent loop (own memory, own tools) and returns its final answer. Timeout 240s. Use for heavy compute, large file processing, or parallel research. EXPLORER ROLE (v0.3.84): read-only reconnaissance — the subagent gets ONLY read-only tools, and its read_file/list_directory/search_files/glob are proxied over the modem to the MASTER computer, letting it read the master's hard drive (code/docs) over the LAN without any write access.",
    parameters={type="object", properties={address={type="string", description="Target modem address (use subagent_discover to find it; NOT from component_list — remote modems are invisible there)"}, task={type="string", description="Task description for the subagent"},     role={type="string", description="Optional role hint: scout, researcher, planner, worker, reviewer, oracle, delegate, explorer (explorer = read-only; file tools proxied to the master)"}, session={type="string", description="Optional session id: same id continues the previous conversation on that subagent; omit for fresh context"}, context={type="string", description="Optional background context to pass to the subagent"}, timeout={type="number", description="Optional reply timeout in seconds (default 240)"}}, required={"address", "task"}}
  }},
  {type="function", ["function"]={
    name="subagent_discover",
    description="Broadcast a discovery ping on the modem network to find online subagents (computers running agent.lua --subagent, listening on the task port). Each online subagent replies with its modem address and model. Returns a list of found subagents (address + model), or 'none found'. Call this BEFORE subagent_call to obtain the target address — remote modem addresses cannot be obtained from component_list (that only lists local components). Discovery window is 5 seconds.",
    -- 无参数工具: 不声明空 properties/required——OC json.lua 把空表 {}
    -- 编码为 []（数组），端点严格校验 properties=[] 直接 400（2026-08-11
    -- ocvm probe 实证: properties=[] → 400, 省略 → 200）。省略合法:
    -- OpenAI 规范 parameters.properties 为 optional。
    parameters={type="object"}
  }},
}

local function exec(name, args, deps)
  if name == "subagent_discover" then
    -- 广播发现（v0.3.78）: broadcast {v=1, op="discover"} 到任务端口，
    -- 收集 5 秒内各在线子代理的 discover_reply（含地址 + 模型）。
    -- 注意: 远端 modem 不在 component_list（OC 组件只列本机可见），
    -- 广播发现是唯一可靠寻址方式。
    local ok, result = pcall(function()
      local json = deps.json
      local wait_modem_message = deps.wait_modem_message
      local SUBAGENT_LISTEN_PORT = deps.subagent_listen_port
      local SUBAGENT_REPLY_PORT = deps.subagent_reply_port

      local comp = require("component")
      local modem = comp.modem
      if not modem then error("no modem (network card) component") end

      local m_ok = pcall(modem.open, SUBAGENT_REPLY_PORT)
      if not m_ok then error("cannot open reply port " .. SUBAGENT_REPLY_PORT) end

      local sent = pcall(modem.broadcast, SUBAGENT_LISTEN_PORT,
        json.encode({v = 1, op = "discover"}))
      if not sent then
        pcall(modem.close, SUBAGENT_REPLY_PORT)
        error("modem.broadcast failed")
      end

      -- 收集窗口 5s: 反复拉消息直到超时（wait_modem_message 单次超时
      -- 返回 nil；循环直到累计窗口耗尽）
      local deadline = os.clock() + 5
      local found = {}
      local seen = {}
      while true do
        local remain = deadline - os.clock()
        if remain <= 0 then break end
        local sender, port, payload = wait_modem_message(remain, SUBAGENT_REPLY_PORT)
        if not sender then break end
        local ok_json, reply = pcall(json.decode, payload or "")
        if ok_json and type(reply) == "table" and reply.op == "discover_reply"
            and reply.address and not seen[reply.address] then
          seen[reply.address] = true
          found[#found + 1] = {address = reply.address,
            model = reply.model or "?"}
        end
      end
      pcall(modem.close, SUBAGENT_REPLY_PORT)

      if #found == 0 then
        return "no subagents found (none running agent.lua --subagent on the network, or out of range)"
      end
      local lines = {}
      for _, f in ipairs(found) do
        lines[#lines + 1] = f.address .. "  (model: " .. tostring(f.model) .. ")"
      end
      return "found " .. #found .. " subagent(s):\n" .. table.concat(lines, "\n")
    end)
    return ok and result or ("Error: " .. tostring(result))

  elseif name == "subagent_call" then
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
