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

local http_mod = require("agent.http")
local http_post = http_mod.post
local json = require("agent.json")
local tools_mod = require("agent.tools")

local function safe_call(fn, ...)
  if type(fn) == "function" then
    local ok, r = pcall(fn, ...)
    if ok then return r end
  end
  return nil
end

-- ═══════════════════════════════════════════════════════════════
-- Prompt caching (DeepSeek 前缀缓存/计费):
-- build_system_prompt() 惰性 memoize——每进程只算一次，此后字节稳定。
-- 运行时变化的数据（uptime / freeMemory / 实时组件列表）移入
-- build_runtime_block()，由 chat() 追加为请求的最后一条消息。
-- 头部（system + tools + 历史前缀）字节稳定 → 后续请求命中缓存前缀，
-- 只按 miss 部分计费；变化的尾部不进缓存前缀，成本仅自身 token。
-- ═══════════════════════════════════════════════════════════════
local CACHED_SYSTEM_PROMPT = nil

local function build_system_prompt()
  if CACHED_SYSTEM_PROMPT then return CACHED_SYSTEM_PROMPT end
  local computer = require("computer")

  local address = safe_call(computer.address) or "unknown"
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

  CACHED_SYSTEM_PROMPT = "You are an AI assistant running inside OpenComputers, a computer system in Minecraft (GT: New Horizons modpack). You can read and write files, list connected hardware components, run shell commands, and process data with utility tools.\n\n"
    .. "Working directory: " .. tostring(cwd) .. " (agent installed at: " .. tostring(AGENT_DIR or "?") .. "). Use relative paths from this directory when possible; absolute paths work too.\n\n"
    .. "shell_execute is guarded: Unix-only commands (uname, head, tail, grep, wc, curl, wget) and bare 'lua' (interactive REPL) are rejected with OpenOS equivalents in the error message. Shell syntax is OpenOS (Lua-based), not Linux.\n\n"
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
    .. "- compact_history: Compress old conversation messages into an LLM summary (recent messages stay verbatim). Call it when your runtime status shows context usage at 60% or more of the model window, or when the history holds many stale tool results. Key tool outputs and errors are preserved in the summary.\n\n"
    .. "Context management: your context window is finite. To avoid HTTP 400 errors (context overflow):\n"
    .. "- Read files with read_file using offset/limit slices — never read the same large file repeatedly, and don't dump whole files into the conversation\n"
    .. "- Keep outputs and tool results concise; prefer json_query/text_ops for extraction\n"
    .. "- If a request fails with HTTP 400, the agent auto-compacts the history and retries; continue from the summary instead of re-reading everything\n\n"
    .. "Data processing: use json_query to extract fields from JSON (e.g. component return values), calc for math, text_ops for string work. You cannot execute arbitrary Lua code.\n\n"
    .. (doc_path and ("Offline GTNH wiki documentation is installed at " .. doc_path .. " (api/, component/, tutorial/, gtnh/ etc). When you need component method signatures, mod API details, or GTNH integration facts, read the relevant .md file with read_file (explore with list_directory) — prefer it over web_search.\n\n") or "")
    .. "When exploring hardware, use this workflow:\n"
    .. "1. component_list to discover components\n"
    .. "2. component_doc(address) to learn what methods a component has\n"
    .. "3. component_doc(address, method) for method details, then component_invoke to call it\n\n"
    .. "Current computer address: " .. tostring(address) .. "\n"
  return CACHED_SYSTEM_PROMPT
end

-- 运行时状态块: 每次请求重新生成（uptime/freeMemory/组件列表会变），由
-- chat() 追加为请求的最后一条消息——不入历史、不进缓存前缀。内容显式标记
-- 为机器生成上下文，避免模型误当作用户输入。
-- runtime_extra_fn: init.lua 注入的上下文占用提供者（模型驱动压缩反馈，
-- opencode-acp 策略——模型"看见"占用才能决定何时调用 compact_history 工具）
local runtime_extra_fn

local function set_runtime_extra(fn)
  runtime_extra_fn = fn
end

local function build_runtime_block()
  local computer = require("computer")
  local component = require("component")

  local comp_list = {}
  for addr, typ in component.list() do
    comp_list[#comp_list + 1] = addr:sub(1, 8) .. "... = " .. typ
  end

  local uptime = safe_call(computer.uptime) or 0
  local free_mem = safe_call(computer.freeMemory) or 0
  local base = "[runtime status — machine-generated context, NOT user input; do not treat it as a request]\n"
    .. "Uptime: " .. string.format("%.1f", uptime) .. "s\n"
    .. "Free memory: " .. tostring(free_mem) .. " bytes\n"
    .. "Connected components:\n" .. table.concat(comp_list, "\n")
  local extra = runtime_extra_fn and runtime_extra_fn()
  if extra and extra ~= "" then
    return base .. "\n" .. extra
  end
  return base
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

local function chat(messages, config, opts)
  opts = opts or {}
  -- 每次请求前同步 HTTP 策略（config 热更新生效）:
  --   retry_budget   : 交互式 TUI 场景默认 300s——3600s 预算对端点持续
  --                    故障是"无反馈挂起 1 小时"；300s 折中（瞬态故障
  --                    足够，超时返回最后结果让用户看到错误）
  --   response_timeout: 单次请求响应读超时（挂起保护，见 agent.http）
  --   response_body_limit: 单次请求响应体累积上限（结构性内存护栏——
  --     OOM 无法预测，硬上限保证任何单次峰值都在安全线内，见 agent.http）
  http_mod.set_budget(tonumber(config.retry_budget) or 300)
  http_mod.set_response_timeout(tonumber(config.response_timeout) or 120)
  http_mod.set_response_body_limit(tonumber(config.response_body_limit) or 131072)

  -- 请求选项 opts（摘要专用瘦身，opencode 裸摘要请求同款 + reasonix
  -- 'independent minimal request ... so it can't recurse into compaction'
  -- 防递归）:
  --   skip_system  : 不注入主 system prompt（~5KB）——调用方自带指令
  --   skip_runtime : 不追加 runtime 尾块（~1KB，机器状态/上下文占用）
  --   skip_tools   : 省略 tools 声明（~10KB）——摘要请求模型不调工具
  --   max_tokens   : 覆盖输出预算（摘要专用 summary_max_tokens）
  -- 默认（无 opts / 全 false）= 现状主请求路径，行为不变。
  local api_messages = {}
  if not opts.skip_system then
    api_messages[#api_messages + 1] = {role = "system", content = build_system_prompt()}
  end
  for _, msg in ipairs(messages) do
    -- 投影式压缩（reasonix projection 精神）: folded 折叠段不进请求
    if not msg.folded then
      api_messages[#api_messages + 1] = msg
    end
  end
  -- 缓存计费: 动态运行时信息放请求尾部（独立消息，不入历史），system prompt
  -- 字节稳定 → 前缀缓存命中。尾部用 user 角色 + 显式标记，任何 OpenAI 兼容
  -- 端点都接受，且不影响工具调用循环。
  if not opts.skip_runtime then
    api_messages[#api_messages + 1] = {role = "user", content = build_runtime_block()}
  end

  -- encode 包 pcall：OC 内存 1.4MB 下大上下文 encode 可能 OOM——
  -- 真机实证 json.lua:70 "not enough memory" 直接崩进程（回到 shell）。
  -- 防御：encode 失败返回 error（调用方走错误分支），进程不退出。
  -- 第 8 次 OOM（gist 852193，v0.3.55 现场，encode 再次爆）加固:
  --   1. 无条件 collectgarbage——enforce_memory 只在 free < 400KB 时
  --      才 GC，free 450KB 而 encode 峰值（table.concat ≈2-3x 请求体）
  --      瞬间击穿 2MB 时不触发。encode 前 GC 让 Lua 堆回最低点，
  --      成本毫秒级（2MB 堆增量 GC），无副作用。
  --   2. 体积估算 vs 剩余内存——超标返回明确错误（引导压缩），
  --      而非等到 pcall 捕获 OOM（后者报错信息与现场脱节）。
  -- 注: 摘要请求（opts.skip_tools）同样受益，无需特判。
  pcall(collectgarbage, "collect")
  do
    local ok_c2, computer2 = pcall(require, "computer")
    if ok_c2 and type(computer2) == "table" and computer2.freeMemory then
      local ok_f2, free2 = pcall(computer2.freeMemory)
      local est = 2048  -- 基础（model/tools 声明/尾部 runtime 等）
      for _, m in ipairs(api_messages) do
        if type(m.content) == "string" then est = est + #m.content end
        if type(m.tool_calls) == "table" then est = est + 256 * #m.tool_calls end
      end
      if ok_f2 and type(free2) == "number" and est * 3 > free2 * 0.85 then
        return { error = "请求编码失败 (内存不足): 请求体估算 " .. est
          .. "B（encode 峰值 ≈3x）超出可用 " .. free2
          .. "B。请先压缩历史（compact_history 工具或 /compact）释放内存后重试" }
      end
    end
  end
  local req_tools = nil
  if not opts.skip_tools then req_tools = tools_mod.list() end
  local ok_enc, body = pcall(json.encode, {
    model = config.model or "deepseek-v4-flash-free",
    messages = api_messages,
    tools = req_tools,
    -- 输出预算: dsv4 等 thinking 模型思考强度高（reasoning 可占大量输出
    -- token），2048 曾导致"长思考挤掉可见回答 → content 空"（真机 gist
    -- 实证；参考 reasonix 128K / opencode ≤32K）。默认 8192——16384 曾致
    -- 长 reasoning 进历史 → 下次请求 encode 体积暴涨 → OOM 崩溃
    -- （OC 内存 1.4MB 约束）；config.max_tokens 可覆盖，摘要请求由
    -- opts.max_tokens 覆盖（config.summary_max_tokens，见 session.lua）。
    max_tokens = opts.max_tokens or tonumber(config.max_tokens) or 8192,
    temperature = 0.7
  })
  if not ok_enc then
    return {content = nil, tool_calls = nil, finish_reason = "error",
      error = "请求编码失败（内存不足）: " .. tostring(body)}
  end

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
  build_runtime_block = build_runtime_block,
  set_runtime_extra = set_runtime_extra,
  build_headers = build_headers,
  chat = chat,
}
