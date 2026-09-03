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
-- 逐 | 管道分段检查。
-- v0.3.124: head/grep/wget 护栏已删——真机 OpenOS 1.8.9 实证这三个
-- 命令存在（59 命令集，grep 为 Wobbo 移植版支持 -r/-n/-i 等）；
-- 旧护栏基于错误的"OpenOS 无这些命令"假设，反而拦住可用命令。
-- ═══════════════════════════════════════════════════════════════
local GUARDS = {
  {pat = "^%s*uname", hint = "uname: not available in OpenOS. Use the `components` command for hardware, or read_file for system files."},
  {pat = "^%s*tail", hint = "tail: not available in OpenOS. Use read_file with offset=-N to read the last N lines."},
  {pat = "^%s*wc", hint = "wc: not available in OpenOS. Count lines with `lua -e` (io.lines loop) or estimate via read_file offset/limit."},
  {pat = "^%s*curl", hint = "curl: not available in OpenOS. OpenOS has `wget <url> [-O file]` for HTTP; or use web_search for web info."},
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

    -- 执行前内存护栏（真机第四次 OOM 根因，gist 59379f，free=35KB）:
    -- OpenOS 所有进程共享同一块内存（2MB 内存条）——shell_execute 启动的
    -- 子进程（探针脚本 require 模块 + HTTP 请求响应缓冲）运行期间的峰值
    -- 内存主进程无法复查（enforce_memory 只在 chat() 前检查，覆盖不到
    -- 工具执行中）。且 v0.3.50 重启后新进程 uptime 255s 即崩：子进程
    -- require 双份模块 + 大响应体 → 与主进程驻留叠加超 2MB。
    -- 护栏: 执行前测 freeMemory，低于 mem_exec_min_free（默认 500KB，
    -- 略高于 mem_pressure 的 400KB——先拒重活再裁历史）拒绝执行，
    -- 提示先压缩历史；普通轻命令（ls/version 等）不受影响。
    local ok_c, computer = pcall(require, "computer")
    if ok_c and computer and computer.freeMemory then
      local ok_f, free = pcall(computer.freeMemory)
      if ok_f and type(free) == "number" then
        local cfg = (deps and deps.load_config and deps.load_config()) or {}
        local min_free = tonumber(cfg.mem_exec_min_free) or 500000
        if free < min_free then
          return "Error: 空闲内存 " .. free .. "B < " .. min_free .. "B（shell 执行护栏）。OpenOS 所有进程共享 2MB 内存，子进程运行期峰值无法复查，此时执行重命令（探针脚本/HTTP 请求/大输出）会 OOM 崩进程。请先调用 compact_history 压缩历史释放内存，或改用 read_file/search_files 等轻量工具，或用 write_file 把脚本写成文件后分小段处理。"
        end
      end
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
