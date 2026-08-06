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

-- Tool registry + execution dispatcher (Phase 1 split). The deps
-- table is built once at module scope (not on every call) to avoid
-- per-invocation require lookups and table construction — critical in
-- pure-Java LuaJ environments where these overheads are amplified.
require("agent.tools")
local execute_mod = require("agent.execute")

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

-- Cached deps injected into plugin tool modules; built once, reused
-- for every execute_tool call (no per-call require or table allocation).
local DEPS = {
  json = json,
  http_post = http_post,
  load_config = load_config,
  wait_modem_message = subagent_mod.wait_modem_message,
  subagent_listen_port = SUBAGENT_LISTEN_PORT,
  subagent_reply_port = SUBAGENT_REPLY_PORT,
  subagent_timeout = SUBAGENT_TIMEOUT,
}

-- ask_user: REPL 模式在 main() 里注入真实实现；subagent/无终端默认不可用。
-- 实现读取用户输入（io.read），把答案返回给工具调用链。
local function ask_user_repl(args)
  local q = (args and args.question) or "?"
  print("")
  print("[ask_user] " .. q)
  local opts = args and args.options
  if opts and #opts > 0 then
    for i, o in ipairs(opts) do
      print("  " .. i .. ") " .. tostring(o))
    end
    print("输入编号（多个用逗号分隔），或直接输入自定义回答，回车结束:")
  end
  io.write("> ")
  local answer = io.read()
  if not answer then return "(用户未回答)" end
  answer = answer:gsub("\n", ""):gsub("\r", ""):gsub("^%s+", ""):gsub("%s+$", "")
  if answer == "" then return "(用户未回答)" end
  -- 编号 → 选项文本（支持 1,2,3 多选）
  if opts and #opts > 0 then
    local sel = {}
    local ok_nums = true
    for n in answer:gmatch("%d+") do
      local idx = tonumber(n)
      if idx >= 1 and idx <= #opts then
        sel[#sel + 1] = tostring(opts[idx])
      else
        ok_nums = false
      end
    end
    if #sel > 0 and ok_nums then
      return "用户选择: " .. table.concat(sel, ", ")
    end
  end
  return "用户回答: " .. answer
end
DEPS.ask_user = ask_user_repl

-- ── Section 4: Tool Execution ──────────────────────────────────
-- Tool implementations live in src/agent/tools/*.lua (registered in
-- agent.tools). This thin wrapper delegates to execute.lua with the
-- cached DEPS table.
function execute_tool(name, args_str)
  return execute_mod.run(name, args_str, DEPS)
end

-- ── Section 7: REPL & Main Loop ────────────────────────────────

-- 最近一次 LLM 响应的 usage（provider 上报；opencode TUI 同款数据源）
local LAST_USAGE = nil

-- 粗略 token 估算（无 tokenizer，仅显示用途）: 英文 ~4 字符/token，
-- 中文按字节 3B/字 ≈ 0.45 token/字节
local function estimate_tokens(s)
  if not s then return 0 end
  s = tostring(s)
  local ascii, non_ascii = 0, 0
  for i = 1, #s do
    if s:byte(i) < 128 then ascii = ascii + 1 else non_ascii = non_ascii + 1 end
  end
  return math.floor(ascii / 4 + non_ascii * 0.45)
end

local function fmt_num(n)
  local s = tostring(math.floor(n or 0))
  local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
  return out:gsub("^,", "")
end

-- ANSI 进度条: pct 0..1，按使用率着色（绿/黄/红）
local function ctx_bar(pct, width)
  local filled = math.floor(pct * width + 0.5)
  if filled < 0 then filled = 0 end
  if filled > width then filled = width end
  local color = "\27[32m"
  if pct >= 0.85 then color = "\27[31m"
  elseif pct >= 0.6 then color = "\27[33m" end
  return color .. string.rep("█", filled) .. string.rep("░", width - filled) .. "\27[0m"
end

local function cmd_ctx(config, messages, usage_override)
  local window = tonumber(config.context_window) or 128000
  local usage = usage_override or LAST_USAGE
  print("")
  print("═══ 上下文使用 ═══")
  if usage and usage.prompt_tokens then
    local total = usage.prompt_tokens
    local pct = window > 0 and (total / window) or 0
    print("上次请求: " .. fmt_num(total) .. " tokens (" .. string.format("%.1f", pct * 100) .. "% of " .. fmt_num(window) .. ")")
    print(ctx_bar(pct, 40) .. "  " .. string.format("%.1f%%", pct * 100))
    if usage.completion_tokens then
      print("输出: " .. fmt_num(usage.completion_tokens) .. " tokens")
    end
  else
    print("尚无请求记录（发一条消息后刷新）")
  end

  -- 本次消息构成（估算）
  local sys_tok, conv_tok, tool_tok = 0, 0, 0
  local msg_count = 0
  for _, m in ipairs(messages) do
    msg_count = msg_count + 1
    local extra = ""
    if m.tool_calls then extra = tostring(m.tool_calls) end
    local t = estimate_tokens(m.content or "") + estimate_tokens(extra)
    if m.role == "system" then sys_tok = sys_tok + t
    elseif m.role == "tool" then tool_tok = tool_tok + t
    else conv_tok = conv_tok + t end
  end
  local est_total = sys_tok + conv_tok + tool_tok
  print("")
  print("┌─ 消息构成（估算，" .. msg_count .. " 条）──────")
  local function line(label, tok)
    local pct = est_total > 0 and (tok / est_total * 100) or 0
    print("│ " .. label .. string.rep(" ", 14 - #label) .. fmt_num(tok) .. " tok  " .. string.format("%.0f%%", pct))
  end
  line("system", sys_tok)
  line("对话", conv_tok)
  line("工具结果", tool_tok)
  print("└──────────────────────────────")
  print("合计(估算): " .. fmt_num(est_total) .. " tok | 模型: " .. tostring(config.model or "?"))
  -- 压缩状态
  local ok_sc, sc = pcall(should_compact, messages)
  print("压缩: " .. (ok_sc and sc and "即将触发（超过阈值，可 /compact）" or "未触发") .. " | /ctx 参考 opencode TUI 的 usage 显示")
end

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
  elseif command == "/version" then
    -- 读取安装时写入的 version.txt（install.lua 生成）
    local vf = io.open(AGENT_DIR .. "/version.txt", "r")
    if vf then
      print("Agent version: " .. (vf:read("*a"):gsub("%s", "") or "?"))
      vf:close()
    else
      print("Agent version: (未记录 — 请重新运行 update.lua 安装)")
    end
  elseif command == "/debug" then
    -- 收集诊断报告（版本+脱敏配置+最近历史）→ 写入本地 + 可选上传 Gist
    local ok_debug, debug_mod = pcall(require, "agent.debug")
    if not ok_debug then
      print("Debug module unavailable: " .. tostring(debug_mod))
    else
      local report = debug_mod.collect(config, load_history())
      local out_path = WRITABLE_BASE .. "/debug_report.txt"
      local ok_w, werr = pcall(function()
        local f = io.open(out_path, "w")
        f:write(report)
        f:close()
      end)
      if ok_w then
        print("Debug report written to " .. out_path .. " (" .. #report .. " bytes)")
      else
        print("Cannot write " .. out_path .. ": " .. tostring(werr))
      end
      local token = config.gist_token
      if token and token ~= "" then
        print("Uploading to GitHub gist...")
        local url, err = debug_mod.upload(report, token)
        if url then
          print("Gist uploaded: " .. url)
        else
          print("Upload failed: " .. tostring(err))
        end
      else
        print("(set /gist-token <github_token> to auto-upload; or paste the report content)")
      end
    end
  elseif command == "/gist-token" then
    if parts[2] then
      config.gist_token = parts[2]
      save_config(config)
      print("Gist token saved. /debug will now upload reports.")
    else
      if config.gist_token then
        print("Gist token: " .. config.gist_token:sub(1, 4) .. "***")
      else
        print("Usage: /gist-token <github_personal_access_token>")
        print("Get one at https://github.com/settings/tokens (scope: gist)")
      end
    end
  elseif command == "/tools" then
    for _, t in ipairs(TOOLS) do
      print("  " .. t["function"].name .. ": " .. t["function"].description)
    end
  elseif command == "/ctx" then
    cmd_ctx(config, messages)
  elseif command == "/help" then
    print("Commands:")
    print("  /model <name>   Switch LLM model (e.g. deepseek-v4-flash-free)")
    print("  /key <api_key>  Set API key (empty = free model, no key needed)")
    print("  /url <endpoint> Switch API endpoint (OpenAI-compatible)")
    print("  /tavily <key>   Enable Tavily web search (better than default HN search)")
    print("  /new            Archive current session, start fresh conversation")
    print("  /compact        Compress conversation (LLM summary + keep recent 4 msgs)")
    print("  /reset          Clear history without archiving")
    print("  /hist           Show message count in current session")
    print("  /version        Show installed agent version")
    print("  /debug          Collect debug report (version+config+history), write locally + upload to GitHub gist if token set")
    print("  /gist-token <t> Save GitHub token for /debug auto-upload (scope: gist)")
    print("  /tools          List available tools the AI can use")
    print("  /ctx            Show context usage (tokens + progress bar, like opencode TUI)")
    print("  /help           Show this help")
    print("  /exit           Quit the agent")
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

-- 强制裁剪: 丢弃最早消息直到估算 tokens < 窗口 60% 或只剩 4 条。
-- 用于压缩失败（LLM 已超限，summarize 同样 400）与 400 重试路径。
-- 返回裁剪后的估算值。
local function force_trim(messages, config)
  local window = tonumber(config.context_window) or 128000
  local target = window * 0.6
  local est = 0
  for _, m in ipairs(messages) do
    est = est + estimate_tokens(m.content or "")
        + estimate_tokens(m.tool_calls and tostring(m.tool_calls) or "")
  end
  while #messages > 4 and est > target do
    est = est - estimate_tokens(messages[1].content or "")
    table.remove(messages, 1)
  end
  return est
end

-- 请求前上下文预算: 估算 tokens 超窗口比例时先压缩；压缩失败（LLM 可能
-- 已超限，summarize 同样 400）强制裁剪最早消息——防止 400 死循环。
-- 返回 (新 messages, 估算 tokens)。
local function ensure_context_budget(messages, config, persist, session)
  local window = tonumber(config.context_window) or 128000
  local function est_msgs(msgs)
    local e = 0
    for _, m in ipairs(msgs) do
      e = e + estimate_tokens(m.content or "")
          + estimate_tokens(m.tool_calls and tostring(m.tool_calls) or "")
    end
    return e
  end
  local function persist_msgs(msgs)
    if persist then
      if session then rebuild_session_history(session, msgs)
      else rebuild_history(msgs) end
    end
  end

  local est = est_msgs(messages)
  -- 触发: 估算超窗口 80%，或消息条数超阈值
  if est <= window * 0.8 and not should_compact(messages) then
    return messages, est
  end

  print("上下文估算 " .. fmt_num(est) .. "/" .. fmt_num(window) .. " tokens，自动压缩...")
  local compacted = compact_history(messages, config)
  if compacted then
    messages = compacted
    persist_msgs(messages)
    return messages, est_msgs(messages)
  end

  -- 压缩失败（LLM 超限）：强制裁剪最早对话消息
  print("压缩失败（LLM 可能已超限），强制裁剪早期消息...")
  force_trim(messages, config)
  persist_msgs(messages)
  return messages, est_msgs(messages)
end

local function process_exchange(messages, config, user_input, persist, session)
  messages[#messages + 1] = {role = "user", content = user_input}

  -- 请求前上下文预算（压缩/裁剪，防 400 死循环）
  messages, _ = ensure_context_budget(messages, config, persist, session)
  messages = trim_history(messages)
  if persist then
    if session then append_session_history(session, messages[#messages])
    else append_history(messages[#messages]) end
  end

  local final_text = {}
  local retried_400 = false
  while true do
    io.write("Thinking...\n")
    local response = chat(messages, config)

    if response.error then
      if not retried_400 and tostring(response.error):find("400") then
        -- HTTP 400 大概率是上下文超限：强制裁剪后重试一次
        retried_400 = true
        print("请求被拒 (HTTP 400)，可能是上下文超限，强制裁剪后重试...")
        force_trim(messages, config)
        if persist then
          if session then rebuild_session_history(session, messages)
          else rebuild_history(messages) end
        end
        -- 继续循环重试
      else
        return {error = response.error}
      end
    else
      -- 请求成功，重置 400 重试标记（后续轮次仍可重试）
      retried_400 = false

    -- 保存 provider 上报的 usage（/ctx 显示用）
    if response.usage then LAST_USAGE = response.usage end

    if response.reasoning_content then
      print(response.reasoning_content)
    end

    if response.content then
      print(response.content)
      final_text[#final_text + 1] = response.content
    end

    local assistant_msg = {role = "assistant", content = response.content or ""}
    -- reasoning_content 必须完整传回（DeepSeek/Kimi thinking mode 要求：
    -- 网关校验后续请求中的 reasoning_content，缺失返回 400
    -- "The reasoning_content in the thinking mode must be passed back"）
    if response.reasoning_content and response.reasoning_content ~= "" then
      assistant_msg.reasoning_content = response.reasoning_content
    end
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
      local fn = tc["function"]
      if fn then
        local tool_name = fn.name or "?"
        local tool_args = fn.arguments
        local ok_call, result = pcall(execute_tool, tool_name, tool_args)
        if not ok_call then
          result = "Error: " .. tostring(result)
        end
        if type(result) == "string" and #result > MAX_TOOL_RESULT then
          result = result:sub(1, MAX_TOOL_RESULT) .. "\n...[truncated " .. (#result - MAX_TOOL_RESULT) .. " chars]"
        end

        -- 紧凑显示: [tool_name 关键参数] 结果摘要（一行）
        local KEY_FIELD = {
          read_file="path", write_file="path", edit_file="path", append_file="path",
          list_directory="path", shell_execute="command", component_doc="address",
          component_invoke="method", web_search="query", subagent_call="task",
          calc="expression", json_query="path", text_ops="op", component_list="filter",
        }
        local param_str = ""
        local kf = KEY_FIELD[tool_name]
        if kf and tool_args then
          param_str = tool_args:match('"' .. kf .. '"%s*:%s*"([^"]*)"')
                   or tool_args:match('"' .. kf .. '"%s*:%s*(%d+)') or ""
          if #param_str > 30 then param_str = param_str:sub(1, 28) .. ".." end
        end
        local result_brief = ""
        if type(result) == "string" then
          result_brief = result:gsub("\n", " | "):sub(1, 60)
          if #result > 60 then result_brief = result_brief .. "..." end
        end
        print("[" .. tool_name .. (param_str ~= "" and (" " .. param_str) or "") .. "] " .. result_brief)
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
      else
        local err_msg = "malformed tool_call (missing 'function')"
        print("[error] " .. err_msg)
        local tool_msg = {role = "tool", tool_call_id = tc.id or "?", content = "Error: " .. err_msg}
        messages[#messages + 1] = tool_msg
        if persist then
          if session then append_session_history(session, tool_msg)
          else append_history(tool_msg) end
        end
      end
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
    -- No terminal: ask_user cannot block on io.read here
    DEPS.ask_user = nil
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
      ::continue_tc::
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

    local result = process_exchange(messages, config, input, true)
    if result and result.error then
      print("[error] " .. result.error)
    end

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
    cmd_ctx = cmd_ctx,
    estimate_tokens = estimate_tokens,
    ctx_bar = ctx_bar,
    ensure_context_budget = ensure_context_budget,
    force_trim = force_trim,
    TOOLS = TOOLS,
  }
end
