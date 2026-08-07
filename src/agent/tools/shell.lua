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

-- ═══════════════════════════════════════════════════════════════
-- Unix-ism 护栏（工具层，替代 system prompt 大段指令——确定性拦截，
-- 不依赖模型遵守; 拒绝信息内含 OpenOS 等价做法，模型从错误中学习）。
-- 逐 | 管道分段检查（管道内的 head/grep 同样拦截）。
-- ═══════════════════════════════════════════════════════════════
local GUARDS = {
  {pat = "^%s*uname", hint = "uname: not available in OpenOS. Use read_file('/etc/os-release') for system info, or component_list/component_doc."},
  {pat = "^%s*head", hint = "head: not available in OpenOS. Use read_file with offset=1 and limit=N to read the first N lines."},
  {pat = "^%s*tail", hint = "tail: not available in OpenOS. Use read_file with offset=-N to read the last N lines."},
  {pat = "^%s*grep", hint = "grep: not available in OpenOS. Use list_directory to find files, read_file to read, text_ops to search."},
  {pat = "^%s*wc", hint = "wc: not available in OpenOS. Use read_file then text_ops op=length to count."},
  {pat = "^%s*curl", hint = "curl: not available in OpenOS. Use web_search for web info, or component_invoke on internet components for HTTP requests."},
  {pat = "^%s*wget", hint = "wget: not available in OpenOS. Use web_search for web info, or component_invoke on internet components for HTTP requests."},
}

-- 护栏: 返回 nil + 错误信息 = 拒绝; 返回 true = 放行。
-- 裸 lua/luac（无参数或仅行尾注释）= 交互式 REPL，永久阻塞等 stdin。
-- 注: `(组)?` 可选捕获组合在此环境不可靠，先剥离行尾注释再匹配。
local function guard_command(cmd)
  if type(cmd) ~= "string" then return nil, "command must be a string" end
  local stripped = cmd:gsub("%s*#.*$", "")
  if stripped:match("^%s*luac?%s*$") then
    return nil, "rejected by guard: bare 'lua' starts an interactive REPL that blocks forever waiting for stdin. Always pass a script or -e: e.g. 'lua script.lua' or 'lua -e \"print(1)\"'."
  end
  for seg in (cmd .. "|"):gmatch("(.-)|") do
    for _, g in ipairs(GUARDS) do
      if seg:match(g.pat) then
        return nil, "rejected by guard: " .. g.hint .. " (command: " .. cmd:sub(1, 120) .. ")"
      end
    end
  end
  return true
end

local function exec(name, args, deps)
  if name == "shell_execute" then
    local ok_guard, guard_err = guard_command(args.command)
    if not ok_guard then
      return guard_err
    end
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
