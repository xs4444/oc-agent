-- ═══════════════════════════════════════════════════════════════
-- OC Agent — entry script (Phase 3).
--
-- This is NOT a require-able module: it is the entry point. In the
-- multi-file (dev) layout it lives at src/agent/init.lua and is run
-- directly (dofile/lua). scripts/build_single.lua inlines this file
-- verbatim at the end of the single-file agent.lua; the file-level
-- varargs (...) then receive the real script arguments, exactly like
-- the original single-file agent.lua.
--
-- Path injection: when deployed, the whole src/agent/ tree is copied
-- to <writable>/agent/ and this file is renamed agent.lua, so
-- require("agent.json") must resolve from <writable>/ — the parent of
-- this file's own directory. We therefore prepend that parent dir to
-- package.path.
-- ═══════════════════════════════════════════════════════════════

do
  -- AGENT_DIR: the directory that contains this entry script (deploy:
  -- <writable>/agent/, where init.lua was renamed to agent.lua and the
  -- module tree sits next to it). Resolve order:
  --   1. A value already set by the harness/installer (most reliable)
  --   2. The chunk source, with or without the "@" prefix
  --   3. The shell working directory (when run as `lua agent.lua` from
  --      the agent dir)
  -- The chosen candidate is validated against the filesystem (must
  -- contain this script's sibling modules, e.g. json.lua) before use.
  local function pick_dir(cands)
    local ok_fs, fs = pcall(require, "filesystem")
    for _, c in ipairs(cands) do
      if type(c) == "string" and c ~= "" then
        if ok_fs then
          local ok_ex, ex = pcall(fs.exists, c .. "/json.lua")
          if ok_ex and ex then return c end
        else
          return c  -- no fs (host tests): trust the candidate
        end
      end
    end
    return nil
  end

  local source = debug.getinfo(1, "S").source or ""
  local cands = {}
  if type(AGENT_DIR) == "string" and AGENT_DIR ~= "" then
    cands[1] = AGENT_DIR
  end
  local m1 = source:match("^@(.*)[/\\][^/\\]+$")
  local m2 = source:match("^(.*)[/\\][^/\\]+$")
  if m1 then cands[#cands + 1] = m1 end
  if m2 then cands[#cands + 1] = m2 end
  local ok_sh, sh = pcall(require, "shell")
  if ok_sh and type(sh.getWorkingDirectory) == "function" then
    cands[#cands + 1] = sh.getWorkingDirectory()
  end
  local self_dir = pick_dir(cands)
  if not self_dir or self_dir == "" then
    self_dir = "."
    -- Plugin directory scan will be unavailable; core tools still load
    -- via require (they sit next to this script on package.path).
  end
  local parent = self_dir:match("^(.*)[/\\][^/\\]+$") or "."
  package.path = parent .. "/?.lua;" .. package.path
  AGENT_DIR = self_dir
end

-- ── Infrastructure modules (Phase 2 split) ─────────────────────
-- json is intentionally a GLOBAL (run_tests.lua and the plugin tests
-- reference `json` directly); the other modules bind locals.

json = require("agent.json")

local http_post = require("agent.http").post

local config_mod = require("agent.config")
local load_config = config_mod.load
local save_config = config_mod.save
local first_run_setup = config_mod.first_run
local WRITABLE_BASE, CONFIG_PATH, HISTORY_PATH, SESSIONS_DIR =
  config_mod.writable_base, config_mod.config_path, config_mod.history_path, config_mod.sessions_dir

local session_mod = require("agent.session")
local trim_history, compact_history, should_compact, summarize_history =
  session_mod.trim_history, session_mod.compact_history, session_mod.should_compact, session_mod.summarize_history
local load_history, append_history, rebuild_history =
  session_mod.load_history, session_mod.append_history, session_mod.rebuild_history
local MAX_TOOL_RESULT = session_mod.MAX_TOOL_RESULT

-- Tool registry + execution dispatcher (Phase 1 split). execute_tool
-- below keeps the lazy require for parity with the original agent.lua.
require("agent.tools")
require("agent.execute")

local chat_mod = require("agent.chat")
local chat = chat_mod.chat

local subagent_mod = require("agent.subagent")
local load_session_history, append_session_history, rebuild_session_history =
  subagent_mod.load_session_history, subagent_mod.append_session_history, subagent_mod.rebuild_session_history
local SUBAGENT_LISTEN_PORT, SUBAGENT_REPLY_PORT, SUBAGENT_TIMEOUT =
  subagent_mod.SUBAGENT_LISTEN_PORT, subagent_mod.SUBAGENT_REPLY_PORT, subagent_mod.SUBAGENT_TIMEOUT

local TOOLS = require("agent.tools").list()

-- Injection point: session.lua's summarize/compact path needs chat.
session_mod.set_chat(chat)

-- ── Section 4: Tool Execution ──────────────────────────────────
-- Tool implementations live in src/agent/tools/*.lua (registered in
-- agent.tools). This wrapper injects agent.lua's locals (json,
-- http_post, load_config, subagent protocol constants) as deps into
-- the plugin modules, then delegates to execute.lua.
function execute_tool(name, args_str)
  local subagent = require("agent.subagent")
  local deps = {
    json = json,
    http_post = http_post,
    load_config = load_config,
    wait_modem_message = subagent.wait_modem_message,
    subagent_listen_port = subagent.SUBAGENT_LISTEN_PORT,
    subagent_reply_port = subagent.SUBAGENT_REPLY_PORT,
    subagent_timeout = subagent.SUBAGENT_TIMEOUT,
  }
  return require("agent.execute").run(name, args_str, deps)
end

-- ── Section 7: REPL & Main Loop ────────────────────────────────

local function handle_command(cmd, config, messages)
  local parts = {}
  for w in cmd:gmatch("%S+") do parts[#parts + 1] = w end
  local command = parts[1]

  if command == "/model" then
    if parts[2] then
      config.model = parts[2]
      save_config(config)
      print("Model: " .. config.model)
    else
      print("Model: " .. config.model)
    end
  elseif command == "/key" then
    if parts[2] then
      config.api_key = parts[2]
      save_config(config)
      print("API key updated")
    else
      print("Usage: /key <api_key>")
    end
  elseif command == "/tavily" then
    if parts[2] then
      config.tavily_key = parts[2]
      save_config(config)
      print("Tavily API key set: " .. parts[2]:sub(1, 8) .. "... (web_search will use Tavily)")
    else
      if config.tavily_key then
        print("Tavily key: " .. config.tavily_key:sub(1, 8) .. "...")
      else
        print("No Tavily key set. web_search uses Hacker News (keyless). Usage: /tavily <key>")
      end
    end
  elseif command == "/url" then
    if parts[2] then
      config.api_url = parts[2]
      save_config(config)
      print("API URL: " .. config.api_url)
    else
      print("API URL: " .. config.api_url)
    end
  elseif command == "/new" then
    -- Archive current session, start fresh (config kept)
    if #messages > 0 then
      local fs = require("filesystem")
      local ok_dir, dir_err = pcall(fs.makeDirectory, SESSIONS_DIR)
      if not ok_dir then print("Note: cannot create " .. SESSIONS_DIR .. " (" .. tostring(dir_err) .. ")") end
      local stamp = ""
      if os.time then
        local ok_t, t = pcall(os.time)
        if ok_t and t then stamp = tostring(t) end
      end
      if stamp == "" then
        local comp = require("computer")
        stamp = string.format("%.0f", comp.uptime() or 0)
      end
      local archive_path = SESSIONS_DIR .. "/agent_history_" .. stamp .. ".txt"
      local ok_save, save_err = pcall(function()
        local f = io.open(archive_path, "w")
        if not f then error("cannot open " .. archive_path) end
        f:write(require("serialization").serialize(messages))
        f:close()
      end)
      if ok_save then
        print("Session archived to " .. archive_path)
      else
        print("Session archive failed: " .. tostring(save_err))
      end
    else
      print("No messages to archive")
    end
    messages = {}
    rebuild_history(messages)
    print("New session started")
  elseif command == "/compact" then
    if #messages == 0 then
      print("Nothing to compact")
    else
      print("Compacting conversation...")
      local compacted = compact_history(messages, config)
      if compacted then
        messages = compacted
        rebuild_history(messages)
        print("Compacted: " .. #messages .. " messages kept (summary + recent)")
      else
        print("Compaction failed (network or model error); conversation unchanged")
      end
    end
  elseif command == "/reset" then
    messages = {}
    rebuild_history(messages)
    print("History cleared")
  elseif command == "/hist" then
    print(#messages .. " messages in history")
  elseif command == "/tools" then
    for _, t in ipairs(TOOLS) do
      print("  " .. t["function"].name .. ": " .. t["function"].description)
    end
  elseif command == "/help" then
    print("Commands: /model /key /url /tavily /new /compact /reset /hist /tools /help /exit")
  elseif command == "/exit" then
    return true, config, messages
  else
    print("Unknown command: " .. command .. ". Type /help for commands.")
  end
  return false, config, messages
end

-- ── Section 8.5: Shared message-processing loop ─────────────────
-- Used by both the interactive REPL and the subagent server: takes one
-- user input, runs the LLM tool-calling loop, returns the final text
-- (concatenated assistant content) and updates `messages`.

local function process_exchange(messages, config, user_input, persist, session)
  messages[#messages + 1] = {role = "user", content = user_input}

  -- Auto-compact before trimming when history gets large
  if should_compact(messages) then
    local compacted = compact_history(messages, config)
    if compacted then
      messages = compacted
      if persist then
        if session then rebuild_session_history(session, messages)
        else rebuild_history(messages) end
      end
    end
  end
  messages = trim_history(messages)
  if persist then
    if session then append_session_history(session, messages[#messages])
    else append_history(messages[#messages]) end
  end

  local final_text = {}
  while true do
    io.write("Thinking...\r")
    local response = chat(messages, config)

    if response.error then
      return {error = response.error}
    end

    if response.content then
      print(response.content)
      final_text[#final_text + 1] = response.content
    end

    local assistant_msg = {role = "assistant", content = response.content or ""}
    if response.tool_calls then
      assistant_msg.tool_calls = response.tool_calls
    end
    messages[#messages + 1] = assistant_msg
    if persist then
      if session then append_session_history(session, assistant_msg)
      else append_history(assistant_msg) end
    end

    if not response.tool_calls or #response.tool_calls == 0 then
      break
    end

    for _, tc in ipairs(response.tool_calls) do
      local tool_name = tc["function"].name
      local tool_args = tc["function"].arguments
      print("[tool] " .. tool_name)
      local result = execute_tool(tool_name, tool_args)
      -- Cap large tool outputs so history + memory stay bounded
      if type(result) == "string" and #result > MAX_TOOL_RESULT then
        result = result:sub(1, MAX_TOOL_RESULT) .. "\n...[truncated " .. (#result - MAX_TOOL_RESULT) .. " chars]"
      end
      local tool_msg = {
        role = "tool",
        tool_call_id = tc.id,
        content = result
      }
      messages[#messages + 1] = tool_msg
      if persist then
        if session then append_session_history(session, tool_msg)
        else append_history(tool_msg) end
      end
    end
  end

  messages = trim_history(messages)
  return {text = table.concat(final_text, "\n")}
end

-- main(config, ...): config is loaded ONCE at the entry point below and
-- passed in (same table instance the /model /key /url /tavily commands
-- mutate via save_config).
local function main(config, ...)
  local component = require("component")
  if not component.isAvailable("internet") then
    print("Error: No internet card found. Tier 2 Internet Card required.")
    return
  end

  -- ── Subagent server mode: `lua agent.lua --subagent [port]` ──
  -- Listens on the modem network for task requests, runs them through the
  -- full agent loop, replies over modem. No interactive REPL.
  local arg1 = ...
  if arg1 == "--subagent" then
    local port_arg = select(2, ...)
    local listen_port = (port_arg and tonumber(port_arg)) or SUBAGENT_LISTEN_PORT
    local modem = component.modem
    if not modem then
      print("Error: no modem (network card) component found")
      return
    end
    local ok_open = pcall(modem.open, listen_port)
    -- Announce our modem address: print + write to writable base (for the
    -- operator to find us; the master discovers subagents via component.list
    -- on its own network — on ocvm the addresses are per-VM so the driver
    -- reads this file).
    local my_addr = type(modem.address) == "string" and modem.address or "?"
    print("Subagent modem address: " .. my_addr)
    local af = io.open(WRITABLE_BASE .. "/subagent_address.txt", "w")
    if af then
      af:write(my_addr)
      af:close()
    end
    print("Subagent listening on modem port " .. listen_port .. " (model: " .. config.model .. ")")
    local event = require("event")
    local busy_session = nil  -- currently-processing session (opencode Active state)

    while true do
      local sig = {event.pull("modem_message")}
      if sig[1] == "modem_message" then
        local sender = sig[3]
        local port = sig[4]
        local payload = sig[6]
        if port == listen_port and type(payload) == "string" then
          local ok_json, req = pcall(json.decode, payload)
          if ok_json and type(req) == "table" and req.id then
            local session = req.session
            -- Busy guard: one task at a time per session (matches opencode's
            -- "Active sessions cannot receive new instructions" rule).
            if busy_session ~= nil and session == busy_session then
              local busy_reply = json.encode({v = 1, id = req.id, ok = false, error = "busy: session '" .. tostring(session) .. "' is still processing", session = session})
              pcall(modem.send, sender, SUBAGENT_REPLY_PORT, busy_reply)
              print("[subagent] busy: rejected task " .. tostring(req.id) .. " for session " .. tostring(session))
            else
              busy_session = session
              print("[subagent] task " .. tostring(req.id) .. " from " .. tostring(sender))
              -- Session reuse: same session id continues the previous
              -- conversation (opencode-style session reuse); omit = fresh.
              local req_messages = {}
              if session and session ~= "" then
                req_messages = load_session_history(session)
                print("[subagent] session '" .. session .. "': " .. #req_messages .. " prior messages")
              end
              if req.context and req.context ~= "" then
                req_messages[#req_messages + 1] = {role = "user", content = "[来自主代理的上下文]\n" .. req.context}
              end
              local task_text = req.task or ""
              if req.role and req.role ~= "" then
                task_text = "[角色: " .. req.role .. "]\n" .. task_text
              end
              -- persist into the session file when a session id is given
              local persist = session and session ~= ""
              -- Guard against unexpected exceptions escaping process_exchange:
              -- busy_session must be released either way, or this session would
              -- be permanently stuck busy and reject all new tasks.
              local ok_proc, result = pcall(process_exchange, req_messages, config, task_text, persist, persist and session or nil)
              if not ok_proc then result = { error = tostring(result) } end
              busy_session = nil  -- release (opencode: Active → Reusable)
              local reply
              if result.error then
                reply = json.encode({v = 1, id = req.id, ok = false, error = result.error, session = session})
              else
                reply = json.encode({v = 1, id = req.id, ok = true, result = result.text, session = session})
              end
              local ok_send = pcall(modem.send, sender, SUBAGENT_REPLY_PORT, reply)
              if ok_send then
                print("[subagent] reply sent for " .. tostring(req.id))
              else
                print("[subagent] FAILED to send reply for " .. tostring(req.id))
              end
            end
          end
        end
      end
    end
    -- unreachable
  end

  local messages = load_history()
  local term_history = {}

  print("OC Agent ready. Model: " .. config.model)
  print("Type /help for commands.")

  while true do
    io.write("> ")
    local input = io.read()
    if not input then break end
    input = input:gsub("\n", "")
    if input == "" then goto continue end

    if input:sub(1, 1) == "/" then
      local exit, c, m = handle_command(input, config, messages)
      config, messages = c, m
      if exit then break end
      goto continue
    end

    term_history[#term_history + 1] = input
    if #term_history > 50 then
      table.remove(term_history, 1)  -- keep terminal history bounded
    end

    process_exchange(messages, config, input, true)

    ::continue::
  end

  print("Goodbye!")
end

-- Script args arrive as file-level varargs (OpenOS lua has no `arg` global;
-- note OpenOS's lua consumes options, so use `lua agent.lua -- --subagent`).
--   lua agent.lua                       → interactive REPL
--   lua agent.lua -- --subagent [port]  → subagent server mode
-- Alternatively set subagent=true in the config file, then plain
-- `lua agent.lua` also starts in subagent mode.
if not _TEST_MODE then
  local script_arg1 = ...
  -- Load the config exactly once; main() receives the same table so the
  -- /model /key /url /tavily commands still mutate + save the live config.
  local cfg = load_config()
  if not cfg then cfg = first_run_setup() end
  if script_arg1 == "--subagent" or (cfg and cfg.subagent) then
    main(cfg, "--subagent", select(2, ...))
  else
    main(cfg)
  end
end

-- Test hooks (available when loaded with _TEST_MODE = true)
if _TEST_MODE then
  -- History redirection now lives in agent.session: set_paths() replaces the
  -- old HISTORY_PATH rebinding hack (agent_test.set_history_path keeps its name).
  agent_test = {
    chat = chat,
    http_post = http_post,
    build_system_prompt = chat_mod.build_system_prompt,
    trim_history = trim_history,
    compact_history = compact_history,
    should_compact = should_compact,
    summarize_history = summarize_history,
    load_history = load_history,
    append_history = append_history,
    rebuild_history = rebuild_history,
    set_history_path = function(p) session_mod.set_paths(p) end,
    process_exchange = process_exchange,
    wait_modem_message = subagent_mod.wait_modem_message,
    TOOLS = TOOLS,
  }
end
