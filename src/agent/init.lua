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
-- 物理字节裁剪（session.lua 导出）: mem_pressure 内存紧张时释放内存用
local trim_to_bytes = session_mod.trim_to_bytes
local estimate_tokens = session_mod.estimate_tokens
local MAX_TOOL_RESULT = session_mod.MAX_TOOL_RESULT
local TOOL_RESULT_KEEP = session_mod.TOOL_RESULT_KEEP

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
  -- 模型驱动压缩（opencode-acp 策略）: compact_history 工具依赖注入。
  -- get_context/rebuild_current 由 process_exchange 每次调用时更新。
  compact_history = session_mod.compact_history,
  get_context = nil,
  rebuild_current = nil,
}

-- TUI 集成（agent.tui）: main() 检测 gpu+screen+keyboard 后设置。
--   UI_INPUT:   输入函数（TUI readInput 或 nil → io.read）——ask_user /
--               多行收集共用，避免工具循环内 io.read 破坏 TUI 界面。
--   UI_HOOKS:   工具活动钩子（onToolCall → 状态栏 "Running X..."；
--               onAssistantText → assistant 输出走角色色，避免与日志
--               一样渲染成灰色——历史记录与实时输出视觉一致）。
local UI_INPUT = nil
local UI_HOOKS = {onToolCall = nil, onAssistantText = nil}

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
  local answer
  if UI_INPUT then
    -- TUI 模式: 走 TUI 输入行（不破坏界面）
    answer = UI_INPUT()
  else
    io.write("> ")
    answer = io.read()
  end
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

-- UTF-8 安全截断: 取前 n 字节，回退到字符边界（不劈裂多字节字符）。
-- 规则: 续字节 = 0x80-0xBF；单字节 < 0x80；起始字节 0xC0+。
-- 切点 p 合法当且仅当 p == #s 或 s:byte(p+1) 不是续字节（下一字符从头开始）。
-- 从 n 往回找：若 byte(p+1) 是续字节，说明字符被劈裂，前移一位。
local function utf8_safe_cut(s, n)
  if not s or #s <= n then return s end
  local cut = n
  while cut < #s and cut >= 1 do
    local b = s:byte(cut + 1)
    if not b or b < 0x80 or b >= 0xC0 then break end
    cut = cut - 1  -- 下一字节是续字节 → 当前切点劈裂字符，回退
  end
  if cut < 0 then cut = 0 end  -- 0 = 空（首个字符都放不下时不劈裂）
  return s:sub(1, cut)
end

-- UTF-8 安全尾部截断: 从末尾保留约 n 字节，向前扫描对齐到字符边界
-- （跳过头部可能是续字节的部分——它属于前一个被切掉的字符）。
local function utf8_safe_tail(s, n)
  if not s or #s <= n then return s end
  local start = #s - n + 1
  while start <= #s do
    local b = s:byte(start)
    if not b or b < 0x80 or b >= 0xC0 then break end
    start = start + 1  -- 续字节属于前一个字符，跳过
  end
  return s:sub(start)
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

-- 缓存命中统计: 兼容两种 provider 上报格式
--   DeepSeek/zen:        usage.prompt_cache_hit_tokens / prompt_cache_miss_tokens
--   讯飞星辰(kimi)/OpenAI 新格式: usage.prompt_tokens_details.cached_tokens
-- 返回 hit, miss（无缓存字段或 hit=0 时返回 nil）。
-- 全防御: provider usage 结构怪异（字段类型不对/嵌套非表）时返回 nil 而非抛错
-- ——statusData 回调依赖它，异常曾导致 TUI 状态栏绘制中断（只剩 status）。
local function cache_stats(usage)
  if not usage or not usage.prompt_tokens then return nil end
  local hit = usage.prompt_cache_hit_tokens
  if hit == nil and type(usage.prompt_tokens_details) == "table" then
    hit = usage.prompt_tokens_details.cached_tokens
  end
  hit = tonumber(hit) or 0
  if hit <= 0 then return nil end
  local miss = usage.prompt_cache_miss_tokens
  if miss == nil then
    local pt = tonumber(usage.prompt_tokens) or 0
    miss = math.max(0, pt - hit)
  end
  miss = tonumber(miss) or 0
  return hit, miss
end

-- 运行时上下文自动显示: 每次 LLM 响应后一行（opencode TUI 底栏同款数据）
local function show_ctx_line(usage, config)
  if not (usage and usage.prompt_tokens) then return end
  local window = tonumber(config.context_window) or 128000
  local total = usage.prompt_tokens
  local pct = window > 0 and (total / window) or 0
  local line = "[ctx] " .. fmt_num(total) .. " / " .. fmt_num(window) .. " tokens ("
    .. string.format("%.1f", pct * 100) .. "%) " .. ctx_bar(pct, 20)
  -- 缓存命中率（provider 上报；无字段/全 miss 则不显示）
  local hit, miss = cache_stats(usage)
  if hit and hit + miss > 0 then
    line = line .. "  cache " .. string.format("%.0f%%", hit / (hit + miss) * 100)
  end
  print("")
  print(line)
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
    -- 缓存计费: provider 上报的缓存命中/未命中（DeepSeek 或 OpenAI 新格式）
    local hit, miss = cache_stats(usage)
    if hit then
      print("缓存: 命中 " .. fmt_num(hit) .. " / 未命中 " .. fmt_num(miss) .. " tokens ("
        .. string.format("%.0f", hit / (hit + miss) * 100) .. "% hit)")
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
  local ok_sc, sc = pcall(should_compact, messages, window)
  print("压缩: " .. (ok_sc and sc and "即将触发（超过阈值，可 /compact）" or "未触发") .. " | /ctx 参考 opencode TUI 的 usage 显示")
end

-- 多行输入收集: 逐行 io.read，直到独立行 EOF（或 Ctrl+D → nil）取消。
-- 对应 opencode TUI 的多行粘贴场景——OC 端无 bracketed paste，
-- ocvm 精简 OpenOS 也无 term.paste 处理，逐行收集最稳（粘贴多行时
-- 每行被提交为一行，这里合并为一条消息）。返回文本或 nil（取消/空）。
local function collect_multiline()
  print("--- 多行输入模式: 逐行收集，单独一行 EOF 结束，Ctrl+D 取消 ---")
  local lines = {}
  while true do
    local line
    if UI_INPUT then
      line = UI_INPUT()
    else
      io.write("...> ")
      line = io.read()
    end
    if not line then
      print("(已取消)")
      return nil
    end
    line = line:gsub("\r", ""):gsub("\n", "")
    if line == "EOF" then
      break
    end
    lines[#lines + 1] = line
  end
  if #lines == 0 then
    print("未收集任何内容。")
    return nil
  end
  return table.concat(lines, "\n")
end

-- 分块复制文件（/relocate 用）。避免整文件读入内存（2MB 约束下大
-- history 全量 read("*a") 会 OOM——与 load_history 流式化同一原则）。
-- src 不存在 → 返回 nil（调用方按需处理）；目标不可写 → false。
local function copy_file_chunked(src, dst)
  local fi = io.open(src, "rb")
  if not fi then return nil end
  local fo = io.open(dst, "wb")
  if not fo then fi:close() return false end
  while true do
    local chunk = fi:read(4096)
    if not chunk then break end
    fo:write(chunk)
  end
  fi:close()
  fo:close()
  return true
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
  elseif command == "/sessions" then
    local list = session_mod.list_sessions()
    if #list == 0 then
      print("No saved sessions (use /session <name> to create one)")
    else
      print("Sessions (" .. #list .. "):")
      for _, s in ipairs(list) do
        print("  " .. s.name .. "  (" .. s.count .. " msgs)")
      end
    end
  elseif command == "/session" then
    -- 类 opencode /session: 切换/创建命名会话（JSONL），default 回主会话
    if not parts[2] then
      print("Usage: /session <name>  |  /sessions  |  /session default")
    else
      local target = parts[2]
      if target == "default" then
        session_mod.set_paths(HISTORY_PATH)
        messages = session_mod.load_history()
        print("Session: default (" .. #messages .. " msgs)")
      else
        local safe = target:gsub("[^%w_%-]", "_"):sub(1, 64)
        local fs = require("filesystem")
        local ok_dir, dir_err = pcall(fs.makeDirectory, SESSIONS_DIR)
        if not ok_dir then
          print("Session dir unavailable: " .. tostring(dir_err))
        else
          session_mod.set_paths(SESSIONS_DIR .. "/" .. safe .. ".jsonl")
          messages = session_mod.load_history()
          print("Session: " .. safe .. " (" .. #messages .. " msgs)")
        end
      end
    end
  elseif command == "/up" or command == "/pgup" then
    -- 翻页命令（PgUp/PgDn 在部分键盘/远程环境不产生键码时的兜底）
    if UI_HOOKS.scrollUp then
      UI_HOOKS.scrollUp(tonumber(parts[2]))
    else
      print("Scroll commands are TUI-only (PgUp/PgDn or /up /down)")
    end
  elseif command == "/down" or command == "/pgdn" then
    if UI_HOOKS.scrollDown then
      UI_HOOKS.scrollDown(tonumber(parts[2]))
    else
      print("Scroll commands are TUI-only (PgUp/PgDn or /up /down)")
    end
  elseif command == "/top" then
    if UI_HOOKS.scrollToTop then UI_HOOKS.scrollToTop()
    else print("Scroll commands are TUI-only (PgUp/PgDn or /up /down)") end
  elseif command == "/bottom" then
    if UI_HOOKS.scrollToBottom then UI_HOOKS.scrollToBottom()
    else print("Scroll commands are TUI-only (PgUp/PgDn or /up /down)") end
  elseif command == "/hist" then
    local p = session_mod.current_path()
    local name = p:match("([^/\\]+)%.jsonl$") or "default"
    print(name .. ": " .. #messages .. " messages")
  elseif command == "/relocate" then
    -- 配置数据存储路径迁移（2026-08-10，引导式）: 把 config/history/
    -- sessions 迁移到另一块可写盘（OC 数据盘小，写满会导致 OOM——见
    -- v0.3.53 磁盘防护）。原盘 config 写 data_dir 引导，重启后自动
    -- 落到新盘；本进程内立即切换 session 路径。
    -- 用法: /relocate               引导式（列出可写盘 → 输入路径 → 确认）
    --       /relocate <path>        直接迁移到指定路径
    local fs_r = require("filesystem")
    local target = parts[2]
    local function readline(prompt)
      io.write(prompt)
      if UI_INPUT then
        return UI_INPUT()
      else
        return io.read()
      end
    end
      if not target then
        -- 引导: 列出可写挂载盘（df.lua 同款组件 API）+ 识别线索
        --（根目录几个文件名）→ 编号选择或取消。
        print("[relocate] 当前数据目录: " .. WRITABLE_BASE)
        print("[relocate] 可写挂载盘:")
        local ok_m, iter = pcall(fs_r.mounts)
        local choices = {}
        if not ok_m or type(iter) ~= "function" then
          print("[relocate] (无法枚举挂载盘)")
        else
          local idx = 0
          for proxy, path in iter do
            if path ~= "/" and path ~= WRITABLE_BASE then
              local probe = io.open(path .. "/wprobe.txt", "w")
              if probe then
                probe:close()
                os.remove(path .. "/wprobe.txt")
                idx = idx + 1
                local info = path
                local ok_l, label = pcall(function() return proxy.getLabel() end)
                if ok_l and label then info = info .. "  (" .. label .. ")" end
                local ok_t, total = pcall(function() return proxy.spaceTotal() end)
                local ok_u, used = pcall(function() return proxy.spaceUsed() end)
                if ok_t and ok_u and type(total) == "number" and type(used) == "number" then
                  if total == math.huge then
                    info = info .. "  free=unlimited"
                  else
                    info = info .. "  free=" .. math.floor((total - used) / 1024) .. "KB"
                  end
                end
                -- 识别线索: 该盘根目录前几个文件名
                local samples = {}
                local ok_s, s_iter = pcall(fs_r.list, path)
                if ok_s and type(s_iter) == "function" then
                  local n = 0
                  for entry in s_iter do
                    n = n + 1
                    if n > 3 then break end
                    samples[#samples + 1] = tostring(entry)
                  end
                end
                if #samples > 0 then
                  info = info .. "  files: " .. table.concat(samples, ", ")
                end
                print("  " .. idx .. ") " .. info)
                choices[idx] = path
              else
                print("  [只读] " .. path)
              end
            end
          end
        end
        if #choices == 0 then
          print("[relocate] 没有其他可写盘")
          return false, config, messages
        end
        local sel = readline("选择目标盘编号（回车取消）: ")
        local n = tonumber(sel or "")
        if not n or n < 1 or n > #choices then
          print("[relocate] 已取消")
          return false, config, messages
        end
        target = choices[n]
        print("[relocate] 目标盘: " .. target)
      end
      -- 校验目标可写
      local probe = io.open(target .. "/wprobe.txt", "w")
      if not probe then
        print("[relocate] 目标不可写: " .. target)
        print("[relocate] 用 /relocate 引导式查看可用挂载盘")
        return false, config, messages
      end
    probe:close()
    os.remove(target .. "/wprobe.txt")
    -- 执行迁移（只复制到新盘+写引导，不删除原盘数据——误选可逆）
    local moved = 0
    local failed = {}
    -- 1) config 复制到目标盘
    local r1 = copy_file_chunked(WRITABLE_BASE .. "/agent_config.txt", target .. "/agent_config.txt")
    if r1 == false then failed[#failed + 1] = "config" end
    if r1 ~= nil then moved = moved + 1 end
    -- 2) history（当前会话 + 默认路径兜底）+ 折叠归档（swap 盘核心数据:
    -- compact 折叠段 <history>.archive.jsonl 是"分页文件"本体——折叠段
    -- 原文冷存储于此，迁移必须一并搬走，否则新盘上模型读不回旧消息）
    local src_hist = session_mod.current_path()
    local function copy_hist(src, dst)
      local r = copy_file_chunked(src, dst)
      if r == false then failed[#failed + 1] = dst end
      if r ~= nil then moved = moved + 1 end
      -- 归档同迁（存在才复制；r==nil 表示源不存在，归档也跳过）
      local r_a = copy_file_chunked(src .. ".archive.jsonl", dst .. ".archive.jsonl")
      if r_a == false then failed[#failed + 1] = dst .. ".archive.jsonl" end
      if r_a ~= nil then moved = moved + 1 end
    end
    copy_hist(src_hist, target .. "/agent_history.txt")
    if src_hist ~= WRITABLE_BASE .. "/agent_history.txt" then
      copy_hist(WRITABLE_BASE .. "/agent_history.txt", target .. "/agent_history.txt")
    end
    -- 3) sessions 目录（复制 *.jsonl；归档 .txt 保留原盘）
    local ok_dir, d_iter = pcall(fs_r.list, SESSIONS_DIR)
    if ok_dir and type(d_iter) == "function" then
      for name in d_iter do
        if name:sub(-6) == ".jsonl" then
          local r3 = copy_file_chunked(SESSIONS_DIR .. "/" .. name, target .. "/sessions/" .. name)
          if r3 == false then failed[#failed + 1] = "session " .. name end
          if r3 ~= nil then moved = moved + 1 end
        end
      end
    end
    -- 4) 原盘 config 写 data_dir 引导（重启后自动落新盘）
    local cfg_ok, cfg_cur = pcall(load_config)
    local cfg_data = cfg_ok and cfg_cur or {}
    cfg_data.data_dir = target
    local ok_save_dir, err_save = pcall(save_config, cfg_data)
    if not ok_save_dir then
      failed[#failed + 1] = "data_dir 引导写入: " .. tostring(err_save)
    end
    -- 5) 本进程内立即切换 session 路径
    session_mod.set_paths(target .. "/agent_history.txt")
    session_mod.set_sessions_dir(target .. "/sessions")
    print("[relocate] 已迁移 " .. moved .. " 个文件到 " .. target
      .. "（data_dir 引导已写入原盘 config）")
    if #failed > 0 then
      print("[relocate] 部分失败: " .. table.concat(failed, ", "))
    end
    print("[relocate] 本会话已切换；重启 agent 后 data_dir 引导使全部路径落到新盘")
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
        print("Uploading to GitHub gist (timeout 30s)...")
        print("  (报告已保存本地: " .. out_path .. "——上传失败/超时不影响内容)")
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
  elseif command == "/preset-200k" then
    -- 一键 200K 上下文配置（2026-08-10 用户需求）: context_window=200000。
    -- 字节预算（byte_budget/mem_prefold_bytes/mem_load_budget）已按内存
    -- scale² 自动放大（4MB→800KB，可承载 ~200K tokens 中文），无需
    -- 改动——本命令只写窗口并校验硬件是否匹配。2MB 平台警告但照设
    -- （窗口是模型属性，与硬件无关；只是历史装不满会被折叠浪费）。
    local ok_c, comp = pcall(require, "computer")
    local total = 0
    if ok_c and type(comp) == "table" and comp.totalMemory then
      local ok_t, t = pcall(comp.totalMemory)
      if ok_t and type(t) == "number" then total = t end
    end
    local cfg_ok, cfg_p = pcall(load_config)
    local cfg_d = cfg_ok and cfg_p or {}
    cfg_d.context_window = 200000
    local ok_s, err_s = pcall(save_config, cfg_d)
    if not ok_s then
      print("[preset-200k] 写入失败: " .. tostring(err_s))
    else
      print("[preset-200k] context_window=200000 已写入 config")
      if total > 0 and total < 4194304 then
        print("[preset-200k] ⚠️ 当前内存 " .. math.floor(total / 1048576)
          .. "MB < 4MB——字节预算约 " .. math.floor(200000 / 3.5 / 1000)
          .. "K tokens（中文），窗口喂不满会被折叠浪费；建议装 4MB 内存条")
      else
        print("[preset-200k] 内存充足（4MB+）：字节预算已按 scale² 放大，"
          .. "可承载 ~200K tokens 中文 ✓")
      end
      print("[preset-200k] 重启 agent 后生效（当前进程仍用旧窗口）")
    end
  elseif command == "/ctx" then
    cmd_ctx(config, messages)
  elseif command == "/ml" then
    -- 多行输入（粘贴多行代码场景）: 收集到 EOF 后作为一条消息发送
    local text = collect_multiline()
    if text then
      print("已收集，发送给 AI...")
      local result = process_exchange(messages, config, text, true)
      if result and result.error then
        print("[error] " .. result.error)
      end
    end
  elseif command == "/help" then
    print("Commands:")
    print("  /model <name>   Switch LLM model (e.g. deepseek-v4-flash-free)")
    print("  /key <api_key>  Set API key (empty = free model, no key needed)")
    print("  /url <endpoint> Switch API endpoint (OpenAI-compatible)")
    print("  /tavily <key>   Enable Tavily web search (better than default HN search)")
    print("  /new            Archive current session, start fresh conversation")
    print("  /compact        Compress conversation (LLM summary + keep recent 4 msgs)")
    print("  /reset          Clear history without archiving")
    print("  /hist           Show current session name and message count")
    print("  /sessions       List saved sessions")
    print("  /session <name> Switch to (or create) a named session; default = main")
    print("  /relocate       Move config/history/sessions to another (writable) disk — guided")
    print("  /preset-200k    One-shot: set context_window=200000 (+ memory check)")
    print("  /up /down       Scroll content (alias /pgup /pgdn; or /top /bottom)")
    print("  /version        Show installed agent version")
    print("  /debug          Collect debug report (version+config+history), write locally + upload to GitHub gist if token set")
    print("  /gist-token <t> Save GitHub token for /debug auto-upload (scope: gist)")
    print("  /tools          List available tools the AI can use")
    print("  /ctx            Show context usage (tokens + progress bar, like opencode TUI)")
    print("  /ml             Multi-line input (paste code: collect until EOF line)")
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

-- 强制裁剪: 丢弃最早消息直到估算 tokens < 窗口 60% 或只剩 5 条。
-- 保留 messages[1]（首个 user 消息 = 前缀缓存锚点），从第 2 条开始丢。
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
  -- 保留头部锚点（缓存前缀），最低 1 + 4 条
  while #messages > 5 and est > target do
    est = est - estimate_tokens(messages[2].content or "")
        - estimate_tokens(messages[2].tool_calls and tostring(messages[2].tool_calls) or "")
    table.remove(messages, 2)
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
      -- folded 分支保留为无害兼容（compact_history 已物理删除折叠段，
      -- 不再产生 folded 消息）
      if not m.folded then
        e = e + estimate_tokens(m.content or "")
            + estimate_tokens(m.tool_calls and tostring(m.tool_calls) or "")
      end
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
  -- 压缩分层（v0.3.47+）: 常规压缩由 process_exchange 开头的字节阈值
  -- 自动折叠（mem_prefold_bytes 默认 100KB）与模型 compact_history 工具
  -- 承担；此处保留 80% 窗口硬保护防 400/超限（最后窗口防线）。
  -- should_compact 仅用于 /ctx 建议显示。
  if est > window * 0.8 then
    print("上下文估算 " .. fmt_num(est) .. "/" .. fmt_num(window) .. " tokens 超 80% 窗口，硬保护压缩...")
    local compacted = compact_history(messages, config)
    if compacted then
      messages = compacted
      persist_msgs(messages)
    else
      -- 压缩失败（LLM 超限）：强制裁剪最早对话消息
      print("压缩失败（LLM 可能已超限），强制裁剪早期消息...")
      force_trim(messages, config)
      persist_msgs(messages)
    end
  end

  -- ═══ 字节硬预算（OC 内存 1.4MB 限制）═══
  -- token 估算通过不代表 encode 不 OOM：json.encode 峰值 ≈ 2-3x 文本字节
  -- （结果 + parts 数组 + 输入）。真机实证：ctx 43%（55K tokens≈190KB 文本）
  -- 时 table.concat 一次性分配崩溃（json.lua:70 "not enough memory"）。
  -- 独立字节预算（config.byte_budget 可调，默认 200KB×scale²——4MB 机器
  -- 800KB：可承载 200K tokens 中文文本（≈700KB），用户配
  -- context_window=200000 即达成 200K 上下文目标；2MB 机器 scale=1 时
  -- 200KB，真机 encode 峰值实测 137-230KB 安全），作为自动折叠
  -- （mem_prefold_bytes）之后的最终兜底：超限直接裁剪早期消息
  -- （保留 head 锚点 + 最近 5 条）。
  local byte_est = 0
  for _, m in ipairs(messages) do
    if not m.folded then
      byte_est = byte_est + #(m.content or "")
          + #(m.tool_calls and tostring(m.tool_calls) or "")
    end
  end
  local MEM_SCALE_I = (require("agent.config")).mem_scale or 1
  local BYTE_BUDGET = tonumber(config.byte_budget)
    or math.floor(200000 * MEM_SCALE_I * MEM_SCALE_I)
  if byte_est > BYTE_BUDGET then
    print("上下文 " .. fmt_num(byte_est) .. " 字节超内存预算 " .. fmt_num(BYTE_BUDGET) .. "，裁剪早期消息...")
    local guard = 0
    while #messages > 5 and byte_est > BYTE_BUDGET and guard < 500 do
      guard = guard + 1
      local m2 = messages[2]
      if m2 and not m2.folded then
        byte_est = byte_est - #(m2.content or "")
            - #(m2.tool_calls and tostring(m2.tool_calls) or "")
      end
      table.remove(messages, 2)
    end
    persist_msgs(messages)
  end

  return messages, est_msgs(messages)
end

-- ── 内存压力检测（真机 OOM→error 根因修复）──
-- fix-5 实证: 60 条真实历史 → 请求体 114KB，encode 峰值 ~137-230KB；
-- 真机 free 内存低谷 278KB（agent 自测）→ encode 必超限 → OOM→error
-- （chat.lua pcall 捕获后 TUI 只显示不落盘——gist 只见 user 无 assistant，
-- 第二轮无响应根因）。context_window=128K 是误导: 24.3K tokens 仅占窗口
-- 19%，低于 should_compact 的 60% 阈值——模型永远不会主动 compact_history
-- （v0.3.47 起由 process_exchange 的字节阈值自动折叠接管，见上）。这里
-- 按运行时 freeMemory 低谷兜底物理裁剪（process_exchange 中自动折叠之后
-- trim_to_bytes 到 mem_trim_bytes——自动折叠已物理回收折叠段，此处是
-- 内存悬崖的最后防线，真机第二次 OOM 已实证）。
-- computer.freeMemory() 不可用时返回 false（不阻塞任何环境——oc_mock/
-- ocvm 精简环境无 computer 也安全）。每次调用重新 pcall(require,"computer"):
-- package.loaded 命中时仅为表查找（无文件 IO 开销），且允许测试临时移除
-- computer 验证缺失路径。阈值可配: config.mem_compact_threshold（字节），
-- 默认 400000（400KB——OC 1.4MB 内存下 encode 峰值 2-3x 文本，低谷必超限）。
local function mem_pressure(config)
  local ok_c, computer = pcall(require, "computer")
  if not ok_c or not computer or not computer.freeMemory then return false end
  local ok_f, free = pcall(computer.freeMemory)
  if not ok_f or type(free) ~= "number" then return false end
  local threshold = tonumber(config.mem_compact_threshold) or 400000  -- 默认 400KB
  return free < threshold
end

-- 运行时诊断表（v0.3.56，debug 报告 Diagnostics 段数据源）:
-- 真机第 7 次现场（gist 5ff1d4）: [mem] 裁剪触发后对话卡死无反馈，
-- debug 报告只有历史、没有裁剪事件/请求状态——信息不足无法定位。
-- 本表记录: 内存曲线（每轮 exchange/工具循环采样）、最后一次内存裁剪
-- （触发时间/前后 free/裁剪条数）、最后一次 chat 请求（耗时/错误）。
-- 经 _G._AGENT_DIAG 全局挂载（与 json 全局同先例），debug.lua collect
-- 读取；TUI/REPL 卡死时用户 /debug 即可见最后状态。
local DIAG = { mem_curve = {}, last_trim = nil, last_chat = nil,
  chat_started = nil, last_tool = nil }
rawset(_G, "_AGENT_DIAG", DIAG)
-- DIAG 快照持久化（2026-08-10 debug 优化: gist 535cfe 现场丢失教训——
-- 用户卡死时重启 agent 再 /debug，Diagnostics 全空（进程内 DIAG 清空，
-- 历史是旧会话加载的）。修复: 每次 chat/裁剪更新后写盘
-- <WRITABLE_BASE>/agent_diag.json；重启后 debug.lua 读文件恢复现场，
-- 标注"重启前快照"。写盘频率=每轮 chat 一次（~1KB，可接受——
-- 与 history append 同量级）；_TEST_MODE 跳过防测试污染。）
local DIAG_FILE = WRITABLE_BASE .. "/agent_diag.json"
local function persist_diag()
  if _TEST_MODE then return end
  local f = io.open(DIAG_FILE, "w")
  if not f then return end
  f:write(json.encode(DIAG))
  f:close()
end

local function now_uptime()
  local ok_c, computer = pcall(require, "computer")
  if ok_c and computer and computer.uptime then
    local ok_u, u = pcall(computer.uptime)
    if ok_u and u then return u end
  end
  return 0
end

-- 内存压力强制裁剪（真机第二次/第三次 OOM 根因修复，gist 10d45721/3c0c3914）:
-- free 内存低谷（真机 278KB→101KB 实测）时 encode 大历史必 OOM→error
-- （chat.lua pcall 捕获，TUI 只显示不落盘——第二轮无响应）。v0.3.45
-- 的投影式折叠（folded 标记不删除）只缩小请求体、**不释放内存**——
-- 93.6KB JSONL 解析后历史表 ~300KB 驻留不变，free 低谷 encode 仍爆。
-- 第三次 OOM（gist 3c0c3914，free=101KB）：mem_pressure 原只在 exchange
-- 开头检查一次，长探索工具循环（多轮 read_file 大结果 append）中途
-- free 跌破阈值无复查 → 继续 encode 峰值 OOM。修复：本函数在 exchange
-- 开头与工具循环每轮 chat() 前各调一次，触发即物理裁剪到 mem_trim_bytes。
-- 三层防御（宽裕→悬崖）:
--   1. 字节阈值自动折叠（上方 auto compact）→ 折叠段物理回收，表字节
--      真实下降——宽裕期保上下文（先于下方 mem_pressure 触发）；
--   2. 窗口超限（ensure_context_budget 80% 硬保护 / 模型 compact_history
--      工具）→ 折叠，防 400/超限；
--   3. 内存紧张（此处 mem_pressure）→ 物理裁剪（trim_to_bytes 到
--      mem_trim_bytes 默认 60KB，悬崖保命——已 OOM 三次，保命优先）。
-- 自动折叠后表字节回落到摘要+保留段，mem_pressure 大概率不触发。
-- 裁剪后持久化（JSONL 同步缩小，历史可追溯性由 /new 归档承担）。
local function enforce_memory(messages, config, persist, session)
  -- 内存曲线采样（每轮调用一次，限 20 点防膨胀；debug 报告可见下降路径）
  local u_now = now_uptime()
  local ok_c, computer = pcall(require, "computer")
  local f_now = 0
  if ok_c and computer and computer.freeMemory then
    local ok_f, f = pcall(computer.freeMemory)
    if ok_f and f then f_now = f end
  end
  DIAG.mem_curve[#DIAG.mem_curve + 1] = { uptime = u_now, free = f_now }
  if #DIAG.mem_curve > 20 then table.remove(DIAG.mem_curve, 1) end

  if not mem_pressure(config) then return end
  print("[mem] 空闲内存紧张，物理裁剪历史（保锚点+最近消息）...")
  local before = #messages
  local trim_budget = tonumber(config.mem_trim_bytes) or 60000
  trim_to_bytes(messages, trim_budget)
  -- 强制 GC（真机第 7 次现场修复，gist 5ff1d4）: 物理删除表条目后 Lua
  -- 堆不立即归还系统（增量 GC）——v0.3.45 折叠不释放内存的教训重演:
  -- 裁剪后 free 不回升，继续 encode 仍可能 OOM。主动 collect 让
  -- computer.freeMemory() 真实回升。OpenOS 有 collectgarbage；
  -- pcall 兼容精简/测试环境（collectgarbage 可能为 nil）。
  pcall(collectgarbage, "collect")
  if persist then
    if session then rebuild_session_history(session, messages)
    else rebuild_history(messages) end
  end
  local removed = before - #messages
  local f_after = 0
  if ok_c and computer and computer.freeMemory then
    local ok_f2, f2 = pcall(computer.freeMemory)
    if ok_f2 and f2 then f_after = f2 end
  end
  DIAG.last_trim = {
    uptime = u_now,
    free_before = f_now,
    removed = removed,
    free_after = f_after,
  }
  persist_diag()
  print("[mem] 裁剪 " .. removed .. " 条（free " .. fmt_num(f_now)
    .. " → " .. fmt_num(f_after) .. "）")
end

local function process_exchange(messages, config, user_input, persist, session, tools_override)
  messages[#messages + 1] = {role = "user", content = user_input}

  -- 模型驱动压缩（opencode-acp 策略）: compact_history 工具通过 DEPS
  -- 访问当前消息列表与当前会话的持久化函数（每次 exchange 更新）。
  DEPS.get_context = function() return messages end
  DEPS.rebuild_current = persist and function(msgs)
    if session then rebuild_session_history(session, msgs)
    else rebuild_history(msgs) end
  end or nil

  -- 传统自动压缩（opencode 模式）: 表字节超阈值系统自动折叠，不等模型
  -- 调用 compact_history 工具——模型驱动路径需模型"看见" ≥60% 窗口才
  -- 自觉压缩（真机 24K tokens 只占窗口 19%，自动路径实际是死的）。
  -- 字节阈值 mem_prefold_bytes（默认 100KB，config 可配）< 字节预算
  -- byte_budget（150KB）→ 自动折叠先于 ensure_context_budget 的裁剪
  -- 触发（宽裕期保上下文）；mem_pressure（内存悬崖）仍在其后兜底。
  -- compact_history 折叠段**物理删除**（见 session.lua）→ 表字节真实
  -- 下降，请求体不变（折叠段本就跳过），缓存前缀随摘要位置 miss 一次
  -- （传统自动压缩语义，opencode 同，接受）。
  local prefold_bytes = tonumber(config.mem_prefold_bytes) or 100000
  local byte_now = 0
  for _, m in ipairs(messages) do
    if not m.folded then
      byte_now = byte_now + #(m.content or "")
          + #(m.tool_calls and tostring(m.tool_calls) or "")
    end
  end
  if byte_now > prefold_bytes then
    print("[compact] 自动压缩（" .. fmt_num(byte_now) .. "B > "
      .. fmt_num(prefold_bytes) .. "B）...")
    local compacted = compact_history(messages, config)
    if compacted then
      messages = compacted
      if persist then
        if session then rebuild_session_history(session, messages)
        else rebuild_history(messages) end
      end
    end
  end

  -- 内存压力强制裁剪（真机第二/三次 OOM 根因修复，见 enforce_memory）:
  -- free 低谷时 encode 大历史必 OOM，此处 exchange 开头检查一次，
  -- 工具循环每轮 chat() 前还会复查（第三次 OOM 修复，见下方循环）。
  enforce_memory(messages, config, persist, session)

  -- 上下文占用反馈: 注入运行时尾部块，模型据此决定何时调用 compact_history。
  -- est_now 在 exchange 开始时快照（工具循环多轮请求共用，粒度足够）。
  local window_now = tonumber(config.context_window) or 128000
  local est_now = 0
  for _, m in ipairs(messages) do
    if not m.folded then
      est_now = est_now + estimate_tokens(m.content or "")
          + estimate_tokens(m.tool_calls and tostring(m.tool_calls) or "")
    end
  end
  chat_mod.set_runtime_extra(function()
    local pct = window_now > 0 and (est_now / window_now * 100) or 0
    return "Context usage: " .. string.format("%.0f%%", pct)
      .. " of model window (est. " .. fmt_num(est_now) .. "/" .. fmt_num(window_now)
      .. " tokens). If >=60% or the history is long, call compact_history."
  end)

  -- 请求前上下文预算（压缩/裁剪，防 400 死循环）
  messages, _ = ensure_context_budget(messages, config, persist, session)
  messages = trim_history(messages)
  if persist then
    if session then append_session_history(session, messages[#messages])
    else append_history(messages[#messages]) end
  end

  local final_text = {}
  local retried_400 = false
  -- 工具循环轮次上限（oc-ai maxSteps / reasonix tool-round cap 借鉴）:
  -- 安全网防无限循环；正常探索不触发（opencode 默认 Infinity）。可配
  -- config.max_tool_steps 覆盖。
  local MAX_TOOL_STEPS = tonumber(config.max_tool_steps) or 40
  local tool_steps = 0
  local tool_cap_reached = false
  local retried_empty = false  -- 空回答重试网（reasonix 借鉴，限一次）
  local stall_count = 0        -- 停滞检测: 连续无产出轮数（reasonix todoStallPause 借鉴）
  local stall_nudged = false   -- nudge 已注入（限一次，防刷屏）
  -- 重复调用检测（doom-loop 护栏，opencode 借鉴）: 记录最近工具调用签名
  -- （name + arguments 摘要，最多 8 条）；最近 4 条内同签名 ≥3 次 → 循环。
  -- 与 cap_trigger 是两套独立机制；重复检测优先于工具执行。
  local recent_calls = {}
  local loop_warned = false
  local function call_signature(tc)
    local fn = tc and tc["function"]
    local name = fn and fn.name or "?"
    local args = fn and fn.arguments or ""
    if type(args) ~= "string" then args = tostring(args) end
    return name .. ":" .. args:sub(1, 120)
  end
  while true do
    -- TUI 模式（UI_INPUT ~= nil）不输出 "Thinking..."：状态栏 setStatus
    -- 已实时显示；io.write 直写终端会与 TUI 屏幕叠加产生多状态行残留。
    if not UI_INPUT then io.write("Thinking...\n") end
    tool_steps = tool_steps + 1
    -- 工具循环中途内存复查（真机第三次 OOM 根因修复，gist 3c0c3914）:
    -- 长探索（多轮 read_file 大结果 append）中途 free 会跌破 400KB 阈值，
    -- 而 exchange 开头只检查一次——encode 峰值（2-3x 文本）仍在低谷爆。
    -- 每轮 chat() 前复查，触发即物理裁剪（不执行工具、不回滚本轮，
    -- 与 exchange 开头路径同语义；mem_pressure 未触发时零开销）。
    enforce_memory(messages, config, persist, session)
    -- chat 请求状态记录（v0.3.56 诊断）: 卡死无反馈时（真机第 7 次现场，
    -- gist 5ff1d4——[mem] 裁剪后对话中断）debug 报告可见最后一次请求的
    -- 耗时与错误，区分"端点慢/挂起（elapsed 接近 retry_budget）"与
    -- "编码失败（error 有值）"。chat 内部 pcall 捕获不抛异常。
    -- v0.3.80 补充"进行中"标记: gist dec2a65 现场（uptime 8.5h 卡死，
    -- last chat 只有上一次成功的 6.8s——卡住的那次 chat 从未完成，快照
    -- 无记录）暴露盲区: persist_diag 只在 chat 完成后写。现在 chat 调用
    -- 前先写 chat_started（uptime + 请求体估算），卡死时快照能区分
    -- "卡在 chat 进行中"（chat_started 有值且无对应 last_chat）。
    local t_start = now_uptime()
    DIAG.chat_started = { uptime = t_start, est = 0 }
    -- 请求体估算（与 encode 守卫同口径）: 非 folded 消息字节和
    for _, m in ipairs(messages) do
      if not m.folded then
        DIAG.chat_started.est = DIAG.chat_started.est
          + #(m.content or "") + #(m.tool_calls and tostring(m.tool_calls) or "")
      end
    end
    persist_diag()
    local response = chat(messages, config, {tools = tools_override})
    DIAG.chat_started = nil  -- chat 完成: 清除进行中标记
    DIAG.last_chat = {
      uptime = t_start,
      elapsed = now_uptime() - t_start,
      error = response and response.error,
    }
    persist_diag()

    if response.error then
      if not retried_400 and tostring(response.error):find("400") then
        -- 400 不一定是上下文超限（也可能是 reasoning 缺失/格式/限流）。
        -- 仅当估算确实超限（>85% 窗口）才裁剪重试；其余直接报错保留现场。
        retried_400 = true
        local est = 0
        for _, m in ipairs(messages) do
          est = est + estimate_tokens(m.content or "")
              + estimate_tokens(m.tool_calls and tostring(m.tool_calls) or "")
        end
        local window = tonumber(config.context_window) or 128000
        if est > window * 0.85 then
          print("HTTP 400（上下文估算 " .. fmt_num(est) .. "/" .. fmt_num(window) .. " 超限），强制裁剪后重试...")
          force_trim(messages, config)
          if persist then
            if session then rebuild_session_history(session, messages)
            else rebuild_history(messages) end
          end
          -- 继续循环重试
        else
          print("HTTP 400（上下文估算 " .. fmt_num(est) .. "/" .. fmt_num(window)
            .. " 未超限，非上下文原因），请求失败: " .. tostring(response.error):sub(1, 200))
          return {error = response.error}
        end
      else
        return {error = response.error}
      end
    else
      -- 请求成功，重置 400 重试标记（后续轮次仍可重试）
      retried_400 = false

    -- 保存 provider 上报的 usage（/ctx 显示用）+ 运行时自动显示
    -- TUI 模式（UI_INPUT ~= nil）跳过 [ctx] 行：状态栏 setStatusData 已实时
    -- 显示 ctx%/cache%，内容区再打 [ctx] 行是命令行时期残留。
    if response.usage then
      LAST_USAGE = response.usage
      if config.ctx_auto ~= false and not UI_INPUT then show_ctx_line(response.usage, config) end
    end

    if response.reasoning_content then
      -- TUI 模式（UI_INPUT ~= nil）: 思考/推理内容不显示——内容区清理策略：
      -- reasoning 是内容区无界增长的最大源（长思考占单轮文本大头），且状态栏
      -- 已有 "Thinking..." 提示；用户输入与 LLM 输出（printRole）完整保留。
      -- 模型侧 messages 仍完整回传 reasoning_content（400 防护不受影响）。
      if not UI_INPUT then
        print(response.reasoning_content)
      end
    end

    if response.content then
      -- TUI 模式（onAssistantText 已注册）走角色色渲染，与历史记录一致；
      -- REPL 模式保持原生 print
      if UI_HOOKS.onAssistantText then
        UI_HOOKS.onAssistantText(response.content)
      else
        print(response.content)
      end
      final_text[#final_text + 1] = response.content
    end

    local has_tool_calls = response.tool_calls and #response.tool_calls > 0
    -- 任务1: 本轮触顶（超过轮次上限且模型还想调用工具）——不执行本轮工具，
    -- 注入提示后做最后一次收尾请求
    local cap_trigger = has_tool_calls and not tool_cap_reached and tool_steps > MAX_TOOL_STEPS

    -- ── 重复调用检测（doom-loop 护栏，opencode 借鉴）──
    -- 签名 = name:arguments 摘要（前 120 字符）。基于此前轮次记录的
    -- recent_calls（最多 8 条）判定: 最近 4 条内同签名出现 ≥3 次 → 循环。
    -- 首次触发注入 tool 错误消息提示一次（loop_action="warn"）；随后 2 轮内
    -- 再次触发 → 硬收尾丢弃 tool_calls 只取 content（"stop"，防烧钱）。
    -- 与 cap_trigger 独立；重复检测优先于工具执行。
    local round_sigs = {}
    if has_tool_calls then
      for _, tc in ipairs(response.tool_calls) do
        local fn = tc["function"]
        local name = fn and fn.name or "?"
        local args = fn and fn.arguments or ""
        if type(args) ~= "string" then args = tostring(args) end
        round_sigs[#round_sigs + 1] = name .. ":" .. args:sub(1, 120)
      end
    end
    local loop_action = nil  -- nil = 正常 | "warn" = 提示一次 | "stop" = 硬收尾
    local loop_sig = nil     -- 触发检测的签名（用于错误消息取工具名）
    if has_tool_calls and #round_sigs > 0 then
      local counts = {}
      local wstart = math.max(1, #recent_calls - 3)
      for i = wstart, #recent_calls do
        local s = recent_calls[i]
        counts[s] = (counts[s] or 0) + 1
      end
      for _, sig in ipairs(round_sigs) do
        if counts[sig] and counts[sig] >= 3 then
          loop_sig = sig
          if loop_warned then
            loop_action = (tool_steps - loop_warn_step <= 2) and "stop" or "warn"
          else
            loop_action = "warn"
          end
          break
        end
      end
      -- 记录本轮签名（无论执行与否——模型确实尝试了这些调用）
      for _, sig in ipairs(round_sigs) do
        recent_calls[#recent_calls + 1] = sig
      end
      if #recent_calls > 8 then
        local keep = {}
        for i = #recent_calls - 7, #recent_calls do keep[#keep + 1] = recent_calls[i] end
        recent_calls = keep
      end
    end

    local assistant_msg = {role = "assistant", content = response.content or ""}
    -- reasoning_content 必须完整传回（DeepSeek/Kimi thinking mode 要求：
    -- 网关校验后续请求中的 reasoning_content，缺失返回 400
    -- "The reasoning_content in the thinking mode must be passed back"）
    if response.reasoning_content and response.reasoning_content ~= "" then
      assistant_msg.reasoning_content = response.reasoning_content
    end
    -- 触顶轮/重复循环收尾轮丢弃 tool_calls：不执行、不入历史，
    -- 防悬空 tool_calls（assistant 带 tool_calls 却无 tool 响应 → 网关 400）
    if has_tool_calls and not tool_cap_reached and not cap_trigger and loop_action ~= "stop" then
      assistant_msg.tool_calls = response.tool_calls
    end
    messages[#messages + 1] = assistant_msg
    if persist then
      if session then append_session_history(session, assistant_msg)
      else append_history(assistant_msg) end
    end

    -- ── 任务2: reasoning-only 轮接受 + 空回答重试网（reasonix 借鉴）──
    if not has_tool_calls then
      local content_blank = not response.content or response.content:gsub("%s", "") == ""
      local has_reasoning = response.reasoning_content ~= nil and response.reasoning_content ~= ""
      if content_blank and has_reasoning and response.finish_reason == "stop" then
        -- 情形 A（reasoningOnlyFinishHonoured）: content 空 + reasoning 非空 +
        -- finish=stop。中间轮可接受（tool_calls 已排除），但最终轮（final_text
        -- 空）不能直接收尾——thinking 模式模型常只输出思考就 stop，真机会
        -- 出现"对话静默停止"（gist 实证：agent 探索完代码后无可见回答）。
        -- 与情形 B 共用 retried_empty 重试网（合计限一次）。
        if #final_text == 0 and not retried_empty then
          retried_empty = true
          print("[reasoning-only] 无可见回答，注入重试消息（限一次）")
          local retry_msg = {role = "user",
            content = "你只产出了思考内容，没有给出可见回答。请直接给出最终回答。"}
          messages[#messages + 1] = retry_msg
          if persist then
            if session then append_session_history(session, retry_msg)
            else append_history(retry_msg) end
          end
          -- 继续循环（不 break）
        elseif #final_text == 0 then
          print("[reasoning-only] 重试后仍无可见回答，接受收尾")
          return {content = "(模型仅产出思考未给出可见回答)", text = "(模型仅产出思考未给出可见回答)"}
        else
          break
        end
      elseif content_blank and not has_reasoning
          and (response.finish_reason == "stop" or response.finish_reason == "length") then
        -- 情形 B: 纯空回答 → 注入重试消息（限一次）
        if not retried_empty then
          retried_empty = true
          print("[empty-reply] 空回答，注入重试消息（限一次）")
          local retry_msg = {role = "user", content = "你的回复内容为空，请直接回答用户的问题。"}
          messages[#messages + 1] = retry_msg
          if persist then
            if session then append_session_history(session, retry_msg)
            else append_history(retry_msg) end
          end
          -- 继续循环（不 break）
        else
          break
        end
      else
        break
      end
    elseif tool_cap_reached then
      -- 任务1 触顶收尾: 丢弃 tool_calls 只取 content（content 空 → 错误）
      if #final_text == 0 then
        print("[tool-cap] 触顶后仍返回工具调用且无 content，终止")
        return {error = "工具循环超出轮次上限"}
      end
      break
    elseif cap_trigger then
      -- 任务1 触顶: 注入提示消息，再做一次收尾请求（本轮工具不执行）
      tool_cap_reached = true
      local notice = "已达到工具调用轮次上限（" .. MAX_TOOL_STEPS .. " 轮）。请总结已有进展并给出最终回答；如需继续探索请明确说明下一步要做什么。"
      print("[tool-cap] " .. notice)
      local notice_msg = {role = "user", content = notice}
      messages[#messages + 1] = notice_msg
      if persist then
        if session then append_session_history(session, notice_msg)
        else append_history(notice_msg) end
      end
    elseif loop_action == "warn" then
      -- 重复循环首次检测: 注入 tool 错误消息提示一次，本轮不执行工具
      loop_warned = true
      loop_warn_step = tool_steps
      local name = (loop_sig or round_sigs[1] or "?"):match("^([^:]+)") or "?"
      local err_msg = "Error: repeated tool call detected (" .. name
        .. " called 3 times with identical arguments in recent rounds). You appear to be looping. Stop retrying this call; change strategy or answer directly with what you have."
      print("[loop-guard] " .. err_msg)
      -- assistant_msg 已携带全部 tool_calls → 每个调用都要有 tool 响应配对
      -- （防悬空 tool_calls → 网关 400）。首条注入完整错误，其余简短跳过说明。
      for i, tc in ipairs(response.tool_calls) do
        local tool_msg = {role = "tool",
          tool_call_id = tc.id or ("call_" .. (i - 1)),
          content = (i == 1) and err_msg
            or "skipped: loop detected (see previous tool error)"}
        messages[#messages + 1] = tool_msg
        if persist then
          if session then append_session_history(session, tool_msg)
          else append_history(tool_msg) end
        end
      end
      -- 继续循环让模型修正
    elseif loop_action == "stop" then
      -- 提示后 2 轮内仍重复 → 丢弃 tool_calls 只取 content 收尾（防烧钱）
      if #final_text == 0 then
        print("[loop-guard] 提示后仍重复调用且无 content，终止")
        return {error = "工具循环重复调用（doom loop），已终止"}
      end
      break
    elseif response.finish_reason == "length" then
      -- 任务3（pi agent-loop 借鉴）: finish_reason=length 时工具参数可能被
      -- 截断，不执行任何工具——为每个调用生成错误结果，让模型修正/收尾
      print("[truncated] finish_reason=length，截断工具调用不执行")
      for i, tc in ipairs(response.tool_calls) do
        local trunc_err = "Error: tool call truncated (finish_reason=length), parameters incomplete — do NOT retry the same call. Summarize progress and answer directly."
        local tool_msg = {role = "tool", tool_call_id = tc.id or ("call_" .. (i - 1)), content = trunc_err}
        messages[#messages + 1] = tool_msg
        if persist then
          if session then append_session_history(session, tool_msg)
          else append_history(tool_msg) end
        end
      end
      -- 继续循环让模型修正
    else
      for _, tc in ipairs(response.tool_calls) do
          local fn = tc["function"]
          if fn then
            local tool_name = fn.name or "?"
            local tool_args = fn.arguments
            -- TUI: 状态栏显示正在运行的工具
            if UI_HOOKS.onToolCall then UI_HOOKS.onToolCall(tool_name) end
            -- 工具执行标记（v0.3.80 诊断）: 执行前写 last_tool（uptime+名
            -- 称），完成后清除——卡死时快照能定位"卡在哪个工具"。工具
            -- 执行可能长时间阻塞（subagent_call 240s / shell 60s），
            -- chat_started 只覆盖请求阶段，工具阶段靠本标记。
            DIAG.last_tool = { uptime = now_uptime(), name = tool_name }
            persist_diag()
            local ok_call, result = pcall(execute_tool, tool_name, tool_args)
            DIAG.last_tool = nil  -- 工具完成: 清除
            if not ok_call then
              result = "Error: " .. tostring(result)
            end
            if type(result) == "string" and #result > MAX_TOOL_RESULT then
              -- head+tail 双保（reasonix 借鉴）: 前/后各 TOOL_RESULT_KEEP 字节，
              -- UTF-8 安全切分（不劈裂多字节字符），中间加截断标记 + 续读提示。
              local head = utf8_safe_cut(result, TOOL_RESULT_KEEP)
              local tail = utf8_safe_tail(result, TOOL_RESULT_KEEP)
              local cut_bytes = #result - (#head + #tail)
              local marker = "\n...\n[truncated " .. cut_bytes .. " bytes] (head+tail kept)\n...\n"
              -- 续读提示（按工具类型）: 文件类工具给出路径续读指引
              local path = tool_args and tool_args:match('"path"%s*:%s*"([^"]*)"')
              if tool_name == "read_file" or tool_name == "edit_file"
                  or tool_name == "append_file" or tool_name == "list_directory" then
                if path and path ~= "" then
                  marker = marker .. "\n[full output exceeds cap; use read_file with offset/limit to read the rest of " .. path .. "]"
                else
                  marker = marker .. "\n[full output exceeds cap; use read_file with offset/limit to read the rest]"
                end
              else
                marker = marker .. "\n[output truncated at " .. MAX_TOOL_RESULT .. " bytes (head+tail); rerun with narrower arguments to see the middle]"
              end
              result = head .. marker .. tail
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

    -- ── todo 停滞检测 + nudge（reasonix todoStallPause 借鉴）──
    -- 模型连续多轮只产出工具调用、无任何可见回答（final_text 空）时，
    -- 注入一次引导消息让其收尾/换策略——而不是默默烧完 MAX_TOOL_STEPS
    -- 轮后由 cap_trigger 硬提示（更早介入，省 token 省时间）。
    -- nudge 限一次（stall_nudged），防模型无视后无限刷提示；
    -- 有可见内容产出即重置计数。
    if #final_text == 0 then
      stall_count = stall_count + 1
      local nudge_rounds = tonumber(config.stall_nudge_rounds) or 5
      if stall_count >= nudge_rounds and not stall_nudged then
        stall_nudged = true
        print("[stall] 连续 " .. stall_count .. " 轮无可见回答，注入 nudge")
        local nudge_msg = {role = "user",
          content = "你已连续 " .. stall_count
            .. " 轮只调用工具但没有产出可见回答。请基于已有信息总结进展并给出最终回答；如果确实还需要信息，请明确说明下一步要做什么、需要什么。"}
        messages[#messages + 1] = nudge_msg
        if persist then
          if session then append_session_history(session, nudge_msg)
          else append_history(nudge_msg) end
        end
      end
    else
      stall_count = 0
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

  -- REPL（无 TUI）模式欢迎语：TUI 模式不打印命令行时期的欢迎文本，
  -- 由 "OC Agent TUI ready" 取代（避免残留）。
  if not ui then
    print("OC Agent ready. Model: " .. config.model)
    print("Type /help for commands.")
  end

  while true do
      local sig = {event.pull("modem_message")}
      if sig[1] == "modem_message" then
        local sender = sig[3]
        local port = sig[4]
        local payload = sig[6]
        if port == listen_port and type(payload) == "string" then
          local ok_json, req = pcall(json.decode, payload)
          -- 广播发现配对（v0.3.78）: 主 agent broadcast {v=1, op="discover"}
          -- （无 id，非任务消息）→ 回自己的 modem 地址到主 agent 的
          -- reply 端口。远端 modem 不在 component_list（OC 组件只列本机
          -- 可见），address 文件也不跨机——发现回复是唯一可靠寻址方式。
          if ok_json and type(req) == "table" and not req.id and req.op == "discover" then
            local reply_payload = json.encode({v = 1, op = "discover_reply",
              address = my_addr, model = config.model})
            pcall(modem.send, sender, SUBAGENT_REPLY_PORT, reply_payload)
            print("[subagent] discover reply sent to " .. tostring(sender))
          elseif ok_json and type(req) == "table" and req.id then
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
              -- explorer 角色（v0.3.84）: 只读探索子代理——工具集过滤为
              -- 只读集合（物理不能写），且 file 工具代理到主代理执行
              -- （内网读主代理硬盘代码/文档，经 modem FILE_PORT 9092）。
              -- 工具集覆盖规则: TOOLS 声明里 name 在只读白名单 → 保留;
              -- 写工具/shell/ask_user/subagent_call 等 → 剔除。
              -- 执行拦截: execute_tool 全局替换——read_file/list_directory/
              -- search_files/glob 转发到 subagent_mod.file_proxy(master=
              -- sender)（任务发送者即主代理地址），其余走原 execute_mod.run。
              local tools_override = nil
              if req.role and req.role == "explorer" then
                local READONLY = {
                  read_file = true, list_directory = true,
                  search_files = true, glob = true,
                  component_list = true, component_doc = true,
                  json_query = true, calc = true, text_ops = true,
                  web_search = true, subagent_discover = true,
                }
                local FILE_PROXY_TOOLS = {
                  read_file = true, list_directory = true,
                  search_files = true, glob = true,
                }
                tools_override = {}
                for _, t in ipairs(TOOLS) do
                  local name = t and t["function"] and t["function"].name
                  if name and READONLY[name] then
                    tools_override[#tools_override + 1] = t
                  end
                end
                local orig_execute = execute_tool
                execute_tool = function(name, args_str)
                  if FILE_PROXY_TOOLS[name] then
                    local args = {}
                    local ok_args = pcall(function()
                      args = json.decode(args_str)
                    end)
                    local res = subagent_mod.file_proxy(name, type(args) == "table" and args or {}, DEPS, sender)
                    if type(res) == "string" and res:sub(1, 6) == "Error:" then
                      return nil, res
                    end
                    return res, nil
                  end
                  return orig_execute(name, args_str)
                end
                print("[subagent] explorer mode: " .. #tools_override .. " readonly tools, file ops proxied to " .. tostring(sender))
              end
              if req.role and req.role ~= "" then
                task_text = "[角色: " .. req.role .. "]\n" .. task_text
              end
              -- persist into the session file when a session id is given
              local persist = session and session ~= ""
              -- Guard against unexpected exceptions escaping process_exchange:
              -- busy_session must be released either way, or this session would
              -- be permanently stuck busy and reject all new tasks.
              local ok_proc, result = pcall(process_exchange, req_messages, config, task_text, persist, persist and session or nil, tools_override)
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

  -- ── 文件服务（v0.3.84）: explorer 子代理经 modem 读主代理硬盘 ──
  -- 主代理空闲时（TUI readInput 事件回调 / REPL 每轮对话间隙）处理
  -- 只读文件请求（read_file/list_directory/search_files/glob，绝不写）。
  -- chat 阻塞期间请求在事件队列排队，恢复空闲后处理。
  -- 仅在有 modem 网卡时启用；失败静默（无网卡机器不受影响）。
  local FILE_EXEC = function(name, args)
    local ok, result = pcall(execute_tool, name, json.encode(args))
    if not ok then return false, tostring(result) end
    if type(result) == "string" and result:sub(1, 6) == "Error:" then
      return false, result
    end
    return true, result
  end
  local FILE_SERVE_HOOK = nil  -- 由 TUI/REPL 分支设置（避免无 modem 时重复 require）
  pcall(function()
    local component = require("component")
    if component.modem then
      component.modem.open(subagent_mod.FILE_PORT)
      -- 统一入口: TUI 回调推模式 / REPL 拉模式
      FILE_SERVE_HOOK = function(sig)
        return subagent_mod.handle_file_message(FILE_EXEC, sig[3], sig[4], sig[6])
      end
    end
  end)

  -- ── TUI 模式（参考 DonChong2000/oc-ai 的 oc-code TUI）──
  -- gpu+screen+keyboard 齐全时启用; 否则回退传统 REPL。
  local ui = nil
  local real_print = print
  if component.isAvailable("gpu") and component.isAvailable("screen") and component.isAvailable("keyboard") then
    local ok_tui, tui_mod = pcall(require, "agent.tui")
    if ok_tui then
      ui = tui_mod
      local mono = config.monochrome
      if not mono then
        local ok_d, depth = pcall(component.gpu.getDepth)
        mono = ok_d and depth == 1  -- 机器人 T1 GPU: 单色方案
      end
      ui.init(mono and {monochrome = true} or nil)
      ui.print("OC Agent TUI ready. Model: " .. config.model)
      ui.print("Type /help for commands.", ui.colors.dim)
      -- 进入 TUI 显示当前会话历史（填充内容区——避免空屏/输入区占半屏感知）
      ui.printHistory(messages)
      -- print 代理: 所有日志（工具行/[ctx]/reasoning/命令输出）进内容区
      print = function(s) ui.print(s, ui.colors.dim) end
      -- 状态栏右侧: 上下文占用 + 缓存命中 + 模型（opencode TUI 同款数据）
      -- 全防御: provider usage 字段可能为字符串（"446"）——数值运算前
      -- tonumber，避免回调抛错导致状态栏只剩 status（真机已现）。
      ui.setStatusData(function()
        local parts = {}
        if LAST_USAGE and LAST_USAGE.prompt_tokens then
          local win = tonumber(config.context_window) or 128000
          local pt = tonumber(LAST_USAGE.prompt_tokens) or 0
          local pct = win > 0 and (pt / win * 100) or 0
          parts[#parts + 1] = string.format("ctx %.0f%%", pct)
          local hit, miss = cache_stats(LAST_USAGE)
          if hit and hit + miss > 0 then
            parts[#parts + 1] = string.format("cache %.0f%%", hit / (hit + miss) * 100)
          end
        end
        -- 内存显示（2026-08-10 用户需求: 状态栏要 mem）: free/total MB。
        -- pcall 全防御——组件不可用/调用失败时静默跳过（与 ctx/cache
        -- 同款容错；真机 4MB 平台显示 "mem 2.3/4.0M"）。
        local ok_c, comp = pcall(require, "computer")
        if ok_c and type(comp) == "table" then
          local ok_f, free = pcall(comp.freeMemory)
          local ok_t, total = pcall(comp.totalMemory)
          if ok_f and type(free) == "number" and ok_t and type(total) == "number"
              and total > 0 then
            -- 显示"占用/总量 + 占用百分比"（2026-08-11 用户反馈: free/total
            -- 易误读成占用——真机显示 3.4/4.0M 实为空闲 3.4MB，实际占用
            -- 仅 0.6MB。改为 used/total，直观反映真实占用）。
            local used = math.max(0, total - free)
            parts[#parts + 1] = string.format("mem %.1f/%.1fM (%.0f%%)",
              used / 1048576, total / 1048576, used / total * 100)
          end
        end
        parts[#parts + 1] = config.model
        return table.concat(parts, "  ")
      end)
      -- Tab 补全: 命令 + 工具名
      local comps = {"/help", "/ctx", "/ml", "/new", "/reset", "/compact", "/hist",
        "/sessions", "/session", "/relocate", "/preset-200k", "/up", "/down", "/pgup", "/pgdn", "/top", "/bottom",
        "/version", "/debug", "/tools", "/model", "/key", "/url", "/tavily",
        "/gist-token", "/exit"}
      for _, t in ipairs(TOOLS) do
        comps[#comps + 1] = t["function"].name
      end
      ui.setCompletions(comps)
      UI_INPUT = function() return ui.readInput() end
      UI_HOOKS.onToolCall = function(name) ui.setStatus("Running " .. name .. "...") end
      -- assistant 正文输出走角色色（白色），与历史 printHistory 一致；
      -- 日志/工具行仍由 print 代理渲染为 dim 灰色。
      UI_HOOKS.onAssistantText = function(s) ui.printRole("assistant", s) end
      -- 翻页命令钩子（PgUp/PgDn 在部分键盘/远程环境不产生键码 → /up /down 兜底）
      UI_HOOKS.scrollUp = function(n)
        ui.scrollUp(n or ui.pageStep() or 1)
      end
      UI_HOOKS.scrollDown = function(n)
        ui.scrollDown(n or ui.pageStep() or 1)
      end
      UI_HOOKS.scrollToTop = function() ui.scrollToTop() end
      UI_HOOKS.scrollToBottom = function() ui.scrollToBottom() end
    end
  end

  while true do
    if ui then
      -- TUI 主循环: 输入/命令/交换（assistant 文本已由 print 代理进内容区）
      ui.setStatus("Ready")
      local input = ui.readInput(FILE_SERVE_HOOK)  -- 文件服务回调（modem 请求不丢失）
      if input == nil then
        ui.print("^C", ui.colors.dim)
        goto continue
      end
      -- 空/空白输入: 不提交（readInput 已拦空白回车；此处兜底 io.read
      -- 回退路径与未来调用方——空白消息会触发 Thinking 状态+完整请求+
      -- 空回答重试网，造成状态栏反复切换）
      if input == "" or input:match("^%s+$") then goto continue end

      if input:sub(1, 1) == "/" then
        local exit, c, m = handle_command(input, config, messages)
        config, messages = c, m
        if exit then ui.stop() break end
        goto continue
      end

      term_history[#term_history + 1] = input
      if #term_history > 50 then
        table.remove(term_history, 1)  -- keep terminal history bounded
      end

      -- 用户输入回显统一由 readInput 内部完成（事件驱动分支 tui.print
      -- "> " 前缀 + io.read 回退分支同样打印）——v0.3.24 曾在主循环重复
      -- 回显，v0.3.40 键盘检测修复后事件驱动激活 → 同一消息显示两行
      -- （真机反馈）。此处不再回显。
      ui.setStatus("Thinking...")
      local result = process_exchange(messages, config, input, true)
      if result and result.error then
        ui.printRole("error", result.error)
      end
      ui.print("", ui.colors.foreground)
      goto continue
    end

    io.write("> ")
    if FILE_SERVE_HOOK then
      -- REPL 模式: io.read 阻塞期间事件排队，回到主循环时集中处理
      -- （文件服务请求——explorer 子代理读主代理硬盘）
      local ok_e, event = pcall(require, "event")
      if ok_e then
        while true do
          local sig = {event.pull(0, "modem_message")}
          if not sig[1] then break end
          FILE_SERVE_HOOK(sig)
        end
      end
    end
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

  -- TUI 清理: 恢复全局 print 与终端状态
  if ui then
    print = real_print
    ui.cleanup()
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
    build_runtime_block = chat_mod.build_runtime_block,
    trim_history = trim_history,
    compact_history = compact_history,
    set_chat = session_mod.set_chat,
    should_compact = should_compact,
    summarize_history = summarize_history,
    load_history = load_history,
    append_history = append_history,
    rebuild_history = rebuild_history,
    set_history_path = function(p) session_mod.set_paths(p) end,
    list_sessions = session_mod.list_sessions,
    current_session_path = session_mod.current_path,
    handle_command = handle_command,
    process_exchange = process_exchange,
    wait_modem_message = subagent_mod.wait_modem_message,
    cmd_ctx = cmd_ctx,
    estimate_tokens = estimate_tokens,
    ctx_bar = ctx_bar,
    show_ctx_line = show_ctx_line,
    cache_stats = cache_stats,
    -- 测试钩子: 模型驱动压缩的上下文注入（对应 DEPS.get_context/rebuild_current
    -- 与 chat_mod.set_runtime_extra，由 process_exchange 每次调用更新）
    set_context_getter = function(fn) DEPS.get_context = fn end,
    set_rebuild_current = function(fn) DEPS.rebuild_current = fn end,
    set_runtime_extra = chat_mod.set_runtime_extra,
    collect_multiline = collect_multiline,
    ensure_context_budget = ensure_context_budget,
    force_trim = force_trim,
    mem_pressure = mem_pressure,
    TOOLS = TOOLS,
  }
end
