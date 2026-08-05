-- ═══════════════════════════════════════════════════════════════
-- agent.tools.shell — shell_execute.
--
-- Module contract: exports {tools = {...}, exec = function(name, args,
-- deps)}. exec returns nil for tool names it does not handle. deps is
-- injected per call by agent.execute (unused here).
-- ═══════════════════════════════════════════════════════════════

local tools = {
  {type="function", ["function"]={
    name="shell_execute",
    description="Run an OpenOS shell command",
    parameters={type="object", properties={
      command={type="string", description="Shell command to execute"},
      timeout={type="number", description="Timeout in seconds (default 60). Long-running or infinite-loop commands are killed when they exceed this."}
    }, required={"command"}}
  }},
}

local function exec(name, args, deps)
  if name == "shell_execute" then
    local timeout = tonumber(args.timeout) or 60
    local ok, result = pcall(function()
      local thread_ok, thread = pcall(require, "thread")
      if not thread_ok then
        -- no thread library (mock/legacy): direct execution with popen capture
        local handle = io.popen(args.command .. " 2>&1")
        if not handle then return "Error: failed to execute command" end
        local output = handle:read("*a")
        handle:close()
        return output ~= "" and output or "(no output)"
      end
      local sh = require("shell")
      local done = false
      local out = nil
      local t = thread.create(function()
        local okc, res = pcall(function()
          -- Capture stdout+stderr via io.popen instead of shell.execute
          -- (shell.execute returns only exit status, not output)
          local handle = io.popen(args.command .. " 2>&1")
          if not handle then return "Error: failed to execute command" end
          local output = handle:read("*a")
          handle:close()
          return output ~= "" and output or "(no output)"
        end)
        out = okc and res or ("Error: " .. tostring(res))
        done = true
      end)
      local wok, werr = thread.waitForAll({t}, timeout)
      if not wok then
        pcall(t.kill, t)
        return "shell_execute timeout after " .. timeout .. "s (command killed): " .. tostring(args.command)
      end
      return out or "(no output)"
    end)
    return ok and result or ("Error: " .. tostring(result))
  end

  return nil  -- not handled by this module
end

return {tools = tools, exec = exec}
