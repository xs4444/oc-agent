-- ═══════════════════════════════════════════════════════════════
-- agent.chat — LLM client (Phase 3 split).
--
-- Verbatim move of the old agent.lua Section 5: safe_call,
-- build_system_prompt, build_headers and chat.
--
-- The old Section 3 captured the tool list once (local TOOLS =
-- require("agent.tools").list()); here tools_mod.list() is fetched on
-- every call so a tool module registered mid-run shows up without a
-- restart (same declarations, identical wire behavior).
--
-- Dependencies: agent.json (encode/decode), agent.http (post),
-- agent.tools (live tool list for the tools[] field).
-- ═══════════════════════════════════════════════════════════════

local http_post = require("agent.http").post
local json = require("agent.json")
local tools_mod = require("agent.tools")

local function safe_call(fn, ...)
  if type(fn) == "function" then
    local ok, r = pcall(fn, ...)
    if ok then return r end
  end
  return nil
end

local function build_system_prompt()
  local computer = require("computer")
  local component = require("component")

  local comp_list = {}
  for addr, typ in component.list() do
    comp_list[#comp_list + 1] = addr:sub(1, 8) .. "... = " .. typ
  end

  local address = safe_call(computer.address) or "unknown"
  local uptime = safe_call(computer.uptime) or 0
  local free_mem = safe_call(computer.freeMemory) or 0
  -- 离线文档探测: /mnt/<x>/doc/version.txt 存在即视为已安装（挂载短名每次
  -- 重启会变，不能硬编码路径；仅几个 fs 调用，开销可忽略）
  local doc_path
  do
    local ok_fs, fs = pcall(require, "filesystem")
    if ok_fs and fs.list then
      local ok_ls, iter = pcall(fs.list, "/mnt")
      if ok_ls and type(iter) == "function" then
        for item in iter do
          local full = "/mnt/" .. tostring(item) .. "/doc"
          if fs.exists(full .. "/version.txt") then
            doc_path = full
            break
          end
        end
      end
    end
  end
  -- Working directory (agent 所在的工作区): OpenOS shell cwd, 或 AGENT_DIR
  local cwd
  do
    local ok_sh, sh = pcall(require, "shell")
    if ok_sh and type(sh.getWorkingDirectory) == "function" then
      local ok_cwd, c = pcall(sh.getWorkingDirectory)
      if ok_cwd then cwd = c end
    end
    if not cwd or cwd == "" then
      cwd = (type(AGENT_DIR) == "string" and AGENT_DIR ~= "") and AGENT_DIR or "/"
    end
  end

  return "You are an AI assistant running inside OpenComputers, a computer system in Minecraft (GT: New Horizons modpack). You can read and write files, list connected hardware components, run shell commands, and process data with utility tools.\n\n"
    .. "Working directory: " .. tostring(cwd) .. " (agent installed at: " .. tostring(AGENT_DIR or "?") .. "). Use relative paths from this directory when possible; absolute paths work too.\n\n"
    .. "IMPORTANT: The shell is OpenOS (based on Lua 5.3), NOT Linux. Shell commands use OpenOS syntax. Do NOT use Unix-isms like 'uname', 'head -2', 'tail -5', 'grep -rn', 'wc -l' — they will fail. Use these OpenOS equivalents instead:\n"
    .. "- System info: read /etc/os-release, or component_list + component_doc (no 'uname')\n"
    .. "- Read first N lines of a file: use read_file with offset=1 and limit=N (no 'head -N')\n"
    .. "- Read last N lines: use read_file with offset=-N (no 'tail -N')\n"
    .. "- Grep/search in files: use list_directory to find files, read_file to read, text_ops to search (no 'grep')\n"
    .. "- Count file lines: read_file then text_ops op=length (no 'wc -l')\n"
    .. "- List directory: list_directory tool (no 'ls' in shell; though 'ls' works in OpenOS, the tool is more reliable)\n\n"
    .. "CRITICAL: Never run 'lua' or any command without arguments that starts an interactive/REPL session — it will block forever waiting for stdin input. Always pass a script: 'lua script.lua' or 'lua -e \"expression\"'.\n\n"
    .. "Available tools:\n"
    .. "- read_file: Read file contents (whole file, or a line slice with offset/limit; negative offset = tail; sliced reads show line numbers)\n"
    .. "- write_file: Write content to a file (new files or full rewrites)\n"
    .. "- edit_file: Replace an exact string in a file (must be unique; replace_all for multiple). Read first, keep files under 20KB\n"
    .. "- append_file: Append content to a file — use for logs and growing files, memory cost is constant regardless of file size\n"
    .. "- list_directory: List files in a directory\n"
    .. "- json_query: Extract a value from a JSON string using a dot path (e.g. 'hits.0.title'). Use to parse component_invoke, web_search or file contents.\n"
    .. "- calc: Evaluate a safe arithmetic expression (sqrt, abs, floor, ceil, min, max, + - * / % ^)\n"
    .. "- text_ops: String manipulation: find, replace, split, slice, upper, lower, trim, length\n"
    .. "- component_list: List connected OpenComputers components\n"
    .. "- component_doc: Get documentation for a component's methods (list methods or read one method's doc)\n"
    .. "- component_invoke: Call a method on a component (after checking component_doc)\n"
    .. "- web_search: Search the web for information (titles, URLs, snippets). Uses Tavily if configured, Hacker News otherwise.\n"
    .. "- subagent_call: Delegate heavy work to another computer on your modem network running agent.lua --subagent. Pass its modem address + task (+ role). It uses its own memory/disk.\n"
    .. "Subagent session reuse: pass the same `session` id to a subagent to continue its previous conversation (context preserved on its disk); omit `session` for a fresh session. Reuse the session of a subagent when a new task continues prior work; use a fresh session for unrelated work. A subagent may reply 'busy' if it is still processing a previous task in that session — retry later.\n\n"
    .. "- shell_execute: Run an OpenOS shell command\n"
    .. "- ask_user: Ask the user a question and wait for their answer (shown on the terminal with numbered options). Use when you need to clarify requirements, get a decision, or offer choices before proceeding — e.g. which option to take, which file to modify, or confirmation for a destructive action.\n\n"
    .. "Data processing: use json_query to extract fields from JSON (e.g. component return values), calc for math, text_ops for string work. You cannot execute arbitrary Lua code.\n\n"
    .. (doc_path and ("Offline GTNH wiki documentation is installed at " .. doc_path .. " (api/, component/, tutorial/, gtnh/ etc). When you need component method signatures, mod API details, or GTNH integration facts, read the relevant .md file with read_file (explore with list_directory) — prefer it over web_search.\n\n") or "")
    .. "When exploring hardware, use this workflow:\n"
    .. "1. component_list to discover components\n"
    .. "2. component_doc(address) to learn what methods a component has\n"
    .. "3. component_doc(address, method) for method details, then component_invoke to call it\n\n"
    .. "Current computer address: " .. tostring(address) .. "\n"
    .. "Uptime: " .. string.format("%.1f", uptime) .. "s\n"
    .. "Free memory: " .. tostring(free_mem) .. " bytes\n"
    .. "Connected components:\n" .. table.concat(comp_list, "\n")
end

local function build_headers(config)
  local headers = {
    ["Content-Type"] = "application/json",
  }
  -- Only send auth when a real key is configured. Some free endpoints
  -- (e.g. OpenCode Zen free models) reject invalid bearer tokens with 401
  -- but accept requests without an Authorization header.
  if config.api_key and config.api_key ~= "" and config.api_key ~= "free" then
    headers["Authorization"] = "Bearer " .. config.api_key
  end
  return headers
end

local function chat(messages, config)
  local system_prompt = build_system_prompt()

  local api_messages = {}
  api_messages[#api_messages + 1] = {role = "system", content = system_prompt}
  for _, msg in ipairs(messages) do
    api_messages[#api_messages + 1] = msg
  end

  local body = json.encode({
    model = config.model or "deepseek-v4-flash-free",
    messages = api_messages,
    tools = tools_mod.list(),
    max_tokens = 2048,
    temperature = 0.7
  })

  local headers = build_headers(config)

  local code, resp, err = http_post(config.api_url or "https://opencode.ai/zen/v1/chat/completions", headers, body)
  if err then
    return {content = nil, tool_calls = nil, finish_reason = "error", error = err}
  end
  if not code or code ~= 200 then
    return {content = nil, tool_calls = nil, finish_reason = "error",
      error = "HTTP " .. tostring(code) .. ": " .. tostring(resp):sub(1, 500)}
  end

  local data, decode_err = json.decode(resp)
  if not data then
    return {content = nil, tool_calls = nil, finish_reason = "error",
      error = "JSON decode: " .. tostring(decode_err)}
  end

  local choice = data.choices and data.choices[1]
  if not choice then
    return {content = nil, tool_calls = nil, finish_reason = "error",
      error = "No choices in response"}
  end

  local msg = choice.message or {}
  return {
    content = msg.content,
    reasoning_content = msg.reasoning_content,
    tool_calls = msg.tool_calls,
    finish_reason = choice.finish_reason,
    -- provider 上报的真实 usage（opencode TUI 同款数据源）
    usage = data.usage,
  }
end

return {
  safe_call = safe_call,
  build_system_prompt = build_system_prompt,
  build_headers = build_headers,
  chat = chat,
}
