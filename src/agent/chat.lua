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
-- 消息真实字节口径（OOM 修复，见 session.lua msg_bytes/msg_tokens）。
-- session.lua 不 require chat.lua（init.lua 是唯一汇聚点），无循环依赖。
local session_mod = require("agent.session")
local msg_bytes = session_mod.msg_bytes

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

  CACHED_SYSTEM_PROMPT = "You are an AI assistant running inside OpenComputers, a computer system in Minecraft (GT: New Horizons modpack). You can read and write files, inspect connected hardware, and run OpenOS shell commands.\n\n"
    .. "Working directory: " .. tostring(cwd) .. " (agent installed at: " .. tostring(AGENT_DIR or "?") .. "). Use relative paths from this directory when possible; absolute paths work too.\n\n"
    .. "The OpenOS shell is NOT Linux but has a rich Unix-like command set: ls, find, grep, cat, head, df, du, tree, man, wget, components, lua, realtime, etc. (no tail/wc/curl). TIME: `date`/`os.date` show the in-game Minecraft clock (year-1976 style); for the real wall clock use `realtime` (or `realtime -u` for UTC) — it fetches timeapi.io and needs egress network. Prefer these real commands for directory listing (ls), file finding (find), and content search (grep -rn) — check `man <cmd>` when unsure. shell_execute is guarded: truly unavailable commands (uname, tail, wc, curl) and bare 'lua' (interactive REPL) are rejected with an OpenOS-equivalent hint in the error message.\n\n"
    .. "Available tools:\n"
    .. "- read_file: Read file contents (whole file, or a line slice with offset/limit; negative offset = tail; sliced reads show line numbers)\n"
    .. "- write_file: Write content to a file (new files or full rewrites)\n"
    .. "- edit_file: Replace an exact string in a file (must be unique; replace_all for multiple). Read first, keep files under 20KB\n"
    .. "- append_file: Append content to a file — use for logs and growing files, memory cost is constant regardless of file size\n"
    .. "- search_files: Search file contents for a pattern (recursive; 'path:line: content' output; result cap 50). Use for broad code search; for quick one-off greps, `grep` via shell_execute works too\n"
    .. "- web_search: Search the web for information (titles, URLs, snippets). Backends: Tavily if configured, else Bing (general + Chinese, keyless), Hacker News as last resort.\n"
    .. "- web_fetch: Fetch a URL and return readable text (HTML stripped). No redirect following — if it reports 'redirected to: ...', call web_fetch again with that URL. Capped at 32KB by default (max_bytes up to 65536).\n"
    .. "- GitHub from this machine: this world's egress filters github 443 (github.com/gist.github.com/raw.githubusercontent.com connect time out ~25% of the time, each failure wastes ~21s). web_fetch AUTO-REWRITES raw files, gists, issues and PRs to reachable endpoints (cdn.jsdelivr.net / api.github.com — result starts with a 'GFW rewrite:' note). For other GitHub HTML pages prefer the API form when possible (api.github.com/repos/...); if a page is truly unreachable, ask the user to fetch it with the local gh_fetch tool (it lands at /home/cache/<name> — then read_file it).\n"
    .. "- subagent_call: Delegate heavy work to another computer on your modem network running agent.lua --subagent. Pass its modem address + task (+ role). It uses its own memory/disk.\n"
    .. "Subagent session reuse: pass the same `session` id to a subagent to continue its previous conversation (context preserved on its disk); omit `session` for a fresh session. Reuse the session of a subagent when a new task continues prior work; use a fresh session for unrelated work. A subagent may reply 'busy' if it is still processing a previous task in that session — retry later.\n\n"
    .. "- shell_execute: Run an OpenOS shell command (ls/find/grep/df/components all available; run Lua via a script file — `lua /tmp/x.lua`, the lua wrapper has NO -e flag). SCRIPTS: `print()` writes to the machine terminal (leaks to the in-game screen), NOT to the captured output — use `io.stdout:write(...)` for output you want captured, or write a result file and `cat` it. SYNTAX TRAPS: `head` only accepts `--lines=N` (`head -40` prints usage to the screen and leaves the captured output empty); `grep` uses LUA patterns, not POSIX (no `\\|` alternation, no -E; -i -r -n -l -c -w -x -v -o --max-count=N are supported) — for alternation run grep once per pattern\n"
    .. "- ask_user: Ask the user a question and wait for their answer (shown on the terminal with numbered options). Use when you need to clarify requirements, get a decision, or offer choices before proceeding — e.g. which option to take, which file to modify, or confirmation for a destructive action.\n\n"
    .. "- compact_history: Compress old conversation messages into an LLM summary (recent messages stay verbatim). Call it when your runtime status shows context usage at 60% or more of the model window, or when the history holds many stale tool results. Key tool outputs and errors are preserved in the summary. Folded messages are archived verbatim to the history file's sibling `*.archive.jsonl` (JSONL, one message per line) — if you later need a detail that the summary lost, read the archive with read_file/search_files.\n\n"
    .. "Context management: your context window is finite. To avoid HTTP 400 errors (context overflow):\n"
    .. "- Read files with read_file using offset/limit slices — never read the same large file repeatedly, and don't dump whole files into the conversation\n"
    .. "- Keep outputs and tool results concise (e.g. cap shell output with `| head -N`)\n"
    .. "- If a request fails with HTTP 400, the agent auto-compacts the history and retries; continue from the summary instead of re-reading everything\n\n"
    .. "You can do math, parse JSON, and manipulate text yourself — no helper tools for that. For exact/long arithmetic: write a small script with write_file (e.g. /tmp/v.lua) that writes its answer to a file (io.open(\"/tmp/v_out.txt\",\"w\"):write(tostring(result))), then run `lua /tmp/v.lua; cat /tmp/v_out.txt` via shell_execute. The lua wrapper has no -e flag (its first arg is always a filename), and a script's print output reaches the terminal unreliably — always capture results in a file.\n\n"
    .. (doc_path and ("Offline GTNH wiki documentation is installed at " .. doc_path .. " (api/, component/, tutorial/, gtnh/ etc). When you need component method signatures, mod API details, or GTNH integration facts, read the relevant .md file with read_file (explore with `ls`/`find` via shell_execute) — prefer it over web_search.\n\n") or "")
    .. "When working with hardware, use this workflow via shell_execute:\n"
    .. "1. `components` (or `components <type>`) to list connected components; `components -l` also shows each component's methods and one-line docs\n"
    .. "2. `man <component-type>` or the offline docs for method details\n"
    .. "3. Call a method: write_file a script (e.g. /tmp/c.lua) with `local r = component.invoke(\"<address>\", \"<method>\", <Lua literal args>)` and `io.open(\"/tmp/c_out.txt\",\"w\"):write(tostring(r))`, then `lua /tmp/c.lua; cat /tmp/c_out.txt` (no lua -e; boolean/table args need real Lua — the shell can't carry them inline)\n\n"
    .. "REMOTE-CONTROL SCRIPTING (a peer computer over the modem — read this BEFORE writing any modem/Lua probe):\n"
    .. "Use the ready-made client library instead of hand-rolling packet code: `local remote = dofile(\"/home/remote_client.lua\")` then `remote.connect(addr, {modem=<your modem addr>, port=8100})` gives you h:ping()/info()/exec()/read()/write()/delete()/cancel(). Each returns a table {ok=..., out=..., err=..., offline=...}. Hand-written send+recv loops are the #1 cause of hung probes.\n"
    .. "!!! NEVER use `os.clock()` as a timeout/deadline. It measures CPU time, and a thread parked in event.pull does not consume CPU — so the clock FREEZES and any `while os.clock() < deadline` loop NEVER EXITS (measured: 0.047s of os.clock over 15s of wall time; an 8s timeout ran 75s+ and had to be hard-capped). This exact bug has caused repeated outages. ALWAYS use the wall clock: `local computer = require(\"computer\"); local deadline = computer.uptime() + timeout; while computer.uptime() < deadline do event.pull(0.25) end`.\n"
    .. "Waiting: `os.sleep(n)` EXISTS and is a proper yielding wall-clock wait (it needs require nothing; it is not the same as computer.sleep, which is nil on OpenOS). Use `os.sleep(n)` — do not hand-roll sleep loops.\n"
    .. "Ports: the only remote-control port is 8100 (the v6 protocol). Port 8001 and the old v5 `remote_debug.lua` are RETIRED and deleted — sending to 8001 gets zero replies forever. Do not write probes against 8001.\n"
    .. "Timeouts: shell_execute kills a command at its timeout and does NOT return the partial output captured so far — a timing-out probe therefore yields no evidence at all. Make remote probes bail out fast, write progress to a file with `io.open`/`:flush()` as they go, and `cat` that file separately so a timeout still leaves you a clue.\n"
    .. "Diagnosing a silent peer: an empty reply is ambiguous (powered off / out of range / crashed / not listening). retrying the identical command cannot disambiguate it — change the probe (different port, different address, check your own modem with `components`) or ask the user. Repeated identical retries get killed by the loop guard anyway.\n\n"    .. "Current computer address: " .. tostring(address) .. "\n"
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
  http_mod.set_response_timeout(tonumber(config.response_timeout) or 900)
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
  --      才 GC，free 450KB 而 encode 峰值瞬间击穿 2MB 时不触发。
  --      encode 前 GC 让 Lua 堆回最低点，成本毫秒级，无副作用。
  --   2. 体积估算 vs 剩余内存——超标返回明确错误（引导压缩），
  --      而非等到 pcall 捕获 OOM（后者报错信息与现场脱节）。
  -- 峰值系数: json.lua 分片优化后 encode 峰值 ≈1.2x 文本（注释实证:
  -- 55K tokens≈190KB → 峰值 ~230KB；无转义字符串零复制、片段引用进
  -- out 表、最终一次 concat）。守卫用 1.5x（实测 + 20% 余量）——
  -- 曾误用 3x（旧 json 时代的数字）导致合法请求被误拒（200KB 请求体
  -- + 600KB free 时 3x 超阈值但实际 240KB 峰值完全可行）。
  -- 峰值系数（真机实测 2026-09-12，/mnt/bb7/agent/json.lua encode 探针）:
  --   增量 = encode 峰值 − 起始 free，实测 body=313KB→532KB(1.70x)、
  --   626KB→1,260KB(2.01x)、939KB→1,527KB(1.63x)、825KB→3.14MB 绝对峰值。
  --   取 2.0x 覆盖最坏（+~19% 余量）。旧值 1.5x 源自"分片优化后 1.2x"
  --   的注释假设，与实测不符（真机现场 554KB 请求体在 free 2.8MB 仍 OOM）。
  --   **注意**: 本轮实测已证「分块 concat」反而更差（4.34x→5.6x 峰值），
  --   「数组按元素子缓冲」更差（6.39x）——不要按旧注释的方向优化 json.lua。
  -- OOM 可复现性关键发现: 同一 626KB payload 在 free=1.79MB 成功、
  --   1.57MB 失败 → 失败由 **free 水位**主导而非 body 大小（见下方判定 2）。
  -- （守卫本体移至 req_tools 构建之后——需要 tools 声明的真实字节）

  local req_tools = nil
  if not opts.skip_tools then
    -- 工具集覆盖（v0.3.84, explorer 子代理）: opts.tools 显式传列表时
    -- 用之（init.lua 子代理模式按 role 过滤后的只读集合），否则默认全量。
    req_tools = opts.tools or tools_mod.list()
  end
  -- tools normalize（2026-08-11 真机 chat 全挂根因，gist 现场 + ocvm probe）:
  -- OC json.lua 把空表 {} 编码为 []（数组）。端点严格校验
  -- parameters.properties=[] 直接 400——subagent_discover（v0.3.78 新增，
  -- 唯一空 properties 工具）导致所有请求 400 → "完全无法 chat 卡 thinking"。
  -- 统一在编码前删除空 properties/required 字段（省略合法: OpenAI 规范
  -- 两者皆 optional），防未来新工具再踩。
  if req_tools then
    for _, t in ipairs(req_tools) do
      local fn = t and t["function"]
      local params = fn and fn.parameters
      if type(params) == "table" then
        if type(params.properties) == "table" and next(params.properties) == nil then
          params.properties = nil
        end
        if type(params.required) == "table" and next(params.required) == nil then
          params.required = nil
        end
      end
    end
  end
  local PEAK_FACTOR = 2.0
  -- 水位判据（判定 2）——**仅对超大请求生效**，按 totalMemory 比例。
  -- 教训（本次修复过程实测）: 先写死绝对值 1450000B，4 个回归用例失败
  -- （mock 是 2MB 机/free=524288）；再改无条件比例 0.30 仍失败（mock
  -- 水位 25%）。水位判据对**小请求**没有意义——小请求在任何水位都能
  -- encode 成功，无条件套用只会误拒。故限定 est > LARGE_BODY 才检查。
  -- 真机 4MB 实测失败带从 free/total ≈ 0.39 起（626KB body 于 0.399 失败、
  -- 于 0.426 成功）→ 取 0.30 为下限，留 ~23% 余量，且只在真实大请求时生效。
  local LARGE_BODY = 400000
  local MIN_FREE_RATIO = 0.30
  pcall(collectgarbage, "collect")
  do
    local ok_c2, computer2 = pcall(require, "computer")
    if ok_c2 and type(computer2) == "table" and computer2.freeMemory then
      local ok_f2, free2 = pcall(computer2.freeMemory)
      local total2 = 0
      if computer2.totalMemory then
        local ok_t2, t2 = pcall(computer2.totalMemory)
        if ok_t2 and type(t2) == "number" and t2 > 0 then total2 = t2 end
      end
      -- 真实字节口径（OOM 修复）: 逐条 msg_bytes + 固定开销 + system/tools。
      -- 旧口径三处漏算导致守卫永不触发（真机现场 est=337,068B vs 真实
      -- 570,200B，est*1.5=505,602 << free*0.85=1,931,761 → 放行后 OOM）:
      --   ① tool_calls 用 256*#tool_calls 而非 #arguments（真实 198,759B
      --      被记成 77,312B，低估 2.57x）；
      --   ② build_system_prompt() + tools 声明（真机实测 system=6,618B +
      --      tools=8,678B = 15,296B）完全没进 est（旧注释写"基础 2048"）；
      --   ③ 每条消息 JSON 结构开销与转义膨胀未计。
      if ok_f2 and type(free2) == "number" then
        local est = 4096  -- 固定开销: model/max_tokens/temperature 等顶层键 + runtime 尾部块
        for _, m in ipairs(api_messages) do
          est = est + msg_bytes(m)
        end
        -- 每条消息的结构开销（键名/引号/逗号）: 真机实测 640 条 554,904B
        -- JSONL 对应 encode 产物 554,976B，纯内容 457,463B → 结构 97,513B
        -- ≈ 152B/条（含 tool_call 骨架，见 session.msg_bytes_json 的
        -- STRUCT_PER_MSG/STRUCT_PER_CALL 分摊）。此处按消息数粗算，
        -- 与 token 路径同源。
        est = est + 160 * #api_messages
        -- system_prompt + tools 声明（旧口径完全漏算）
        local sp = build_system_prompt()
        if type(sp) == "string" then est = est + #sp end
        -- tools 声明真实字节（旧口径完全漏算；真机实测 8,678B）。
        -- 用 json.encode 量准，失败则退回粗估（绝不让守卫自身抛错）。
        local ok_tj, tools_json = pcall(json.encode, req_tools)
        if ok_tj and type(tools_json) == "string" then
          est = est + #tools_json
        else
          est = est + 8192 * #(req_tools or {})
        end
        -- 判定 1: 估算峰值超可用内存
        if est * PEAK_FACTOR > free2 * 0.85 then
          return { error = "请求编码失败 (内存不足): 请求体估算 " .. est
            .. "B（encode 峰值 ≈" .. PEAK_FACTOR .. "x）超出可用 " .. free2
            .. "B。请先压缩历史（compact_history 工具或 /compact）释放内存后重试" }
        end
        -- 判定 2: 超大请求的 free 水位比例下限。真机实测: 同一 626KB body
        -- 在 free=1.79MB(0.426×total) 成功、1.57MB(0.399) 失败——body 估算
        -- 无法解释该差异，说明连续块可得性由 free 水位主导。仅 est 超过
        -- LARGE_BODY 时检查（小请求在任何水位都能成功，无条件套用会误拒
        -- ——本次修复中该误拒已被回归用例捕获）。
        if est > LARGE_BODY then
          local min_free = 0
          if total2 > 0 then min_free = total2 * MIN_FREE_RATIO end
          if min_free > 0 and free2 < min_free then
            return { error = "请求编码失败 (内存紧张): 可用内存 " .. free2
              .. "B 低于安全水位 " .. math.floor(min_free) .. "B——encode 需要"
              .. "一次性连续块，碎片化堆会直接 OOM。请先压缩历史"
              .. "（compact_history 工具或 /compact）后重试" }
          end
        end
      end
    end
  end
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

  -- v0.3.118: opts.on_retry 透传给 http_post——重试过程状态透出
  -- （init.lua 注入 → 状态栏"重试第 N 次 (HTTP xxx) 退避 Xs"）
  -- v0.3.126r1: opts.on_wait 透传——单次请求读取期间状态栏耗时心跳
  local code, resp, err = http_post(config.api_url or "https://opencode.ai/zen/v1/chat/completions",
    headers, body, opts and opts.on_retry, opts and opts.on_wait)
  if err then
    return {content = nil, tool_calls = nil, finish_reason = "error", error = err}
  end
  if not code or code ~= 200 then
    return {content = nil, tool_calls = nil, finish_reason = "error",
      error = "HTTP " .. tostring(code) .. ": " .. tostring(resp):sub(1, 500)}
  end

  -- decode 包 pcall（2026-08-10 补齐——encode 侧有 pcall+守卫，decode
  -- 侧曾是裸调用）: json.decode 失败时 error() 抛出（无内部捕获），
  -- 而旧代码期望 (data, decode_err) 双值——decode_err 恒为 nil，
  -- 损坏 JSON（端点半截响应）或 decode OOM（131072B 响应构建表+字符串
  -- 峰值可观）会直接崩进程回 shell，TUI 无提示（用户感知为"卡死"）。
  -- 修复: pcall 包裹，失败返回明确错误；decode 峰值与 encode 同源
  -- （响应体 131072 硬上限已由 http 层保证，此处只补崩溃兜底）。
  local ok_d, data = pcall(json.decode, resp)
  if not ok_d then
    return {content = nil, tool_calls = nil, finish_reason = "error",
      error = "JSON decode: " .. tostring(data)}
  end
  if not data then
    return {content = nil, tool_calls = nil, finish_reason = "error",
      error = "JSON decode: empty response"}
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
