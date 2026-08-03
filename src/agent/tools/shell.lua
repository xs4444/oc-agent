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
    parameters={type="object", properties={command={type="string", description="Shell command to execute"}}, required={"command"}}
  }},
}

local function exec(name, args, deps)
  if name == "shell_execute" then
    local ok, result = pcall(function()
      local sh = require("shell")
      return sh.execute(args.command)
    end)
    return ok and tostring(result) or ("Error: " .. tostring(result))
  end

  return nil  -- not handled by this module
end

return {tools = tools, exec = exec}
