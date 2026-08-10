-- ═══════════════════════════════════════════════════════════════
-- agent.session — conversation history + compaction (Phase 2 split).
--
-- Verbatim move of the old agent.lua Section 6 history parts
-- (load/append/rebuild_history, trim_history, MAX_* constants) and
-- Section 5.5 compaction (summarize/compact/should_compact).
--
-- Dependencies: agent.json (message encode/decode), agent.config
-- (default history_path). chat is INJECTED via set_chat() (agent.lua
-- Section 5) because summarize_history routes its LLM call through the
-- shared chat client; it is nil-safe when not injected yet.
--
-- set_paths() replaces the old agent_test HISTORY_PATH rebinding hack:
-- the module owns its history path state.
-- ═══════════════════════════════════════════════════════════════

local json = require("agent.json")
local config_mod = require("agent.config")

-- Injected by agent.lua's set_chat(chat) once Section 5 is defined.
local injected_chat
-- History path state: defaults to the config module's resolved path,
-- overridable via set_paths (used by tests).
local history_path = config_mod.history_path

-- 历史/trim 预算（OC 内存约束）与压缩触发（模型窗口约束）:
--   - trim: 200KB / 60 条 —— 2MB 内存下历史+编码峰值 ~600KB，安全
--   - 压缩: 窗口比例驱动（估算 tokens ≥ 窗口 60%）+ 条数 48 兜底
-- 梯度保持: 压缩触发点 < trim 截断点。旧固定阈值（16条/40KB）导致每轮
-- 工具对话必压缩 → 每轮调 LLM 摘要 + 破坏缓存前缀。
-- 内存自适应缩放（2026-08-10 真机 4MB 升级）: 硬常量按
-- config_mod.mem_scale（= totalMemory/2MB）缩放。2MB 机器 scale=1
-- 行为不变；4MB 机器 scale=2: 更多历史进内存表（更多上下文给模型）。
-- 显式 config（mem_load_budget 等）仍优先——此处仅模块级硬常量。
local MEM_SCALE = config_mod.mem_scale or 1
local MAX_HISTORY = math.floor(60 * MEM_SCALE)
local MAX_HISTORY_BYTES = math.floor(200000 * MEM_SCALE)  -- ~200KB×scale budget; large tool results trimmed away
local MAX_TOOL_RESULT = 3000     -- per-tool-result cap (exported: agent.lua uses it in process_exchange)
-- head+tail 双保（reasonix 借鉴）: 超限结果保留前/后各 TOOL_RESULT_KEEP 字节，
-- 总预算与 MAX_TOOL_RESULT 一致（3000），中间部分以标记提示。
local TOOL_RESULT_KEEP = 1500

local COMPACT_KEEP = 4          -- 保留条数下限
local COMPACT_KEEP_MIN_TOKENS = 1500  -- 保留 token 保底（不足时向前补充，
                                      -- opencode-acp 的条数+token 双轨思路）
local COMPACT_KEEP_MAX = 8      -- 保留条数封顶（防小消息全保留、压缩无效）
local COMPACT_TRIGGER_COUNT = 48  -- 条数兜底（trim 60 条的 80%，防海量小消息退化）
local COMPACT_WINDOW_RATIO = 0.6  -- 主触发: 估算 tokens ≥ 窗口 × 0.6（tokens 上限阈值驱动）

-- 估算 token（唯一实现，init.lua 引用本模块导出）: 英文 ~4 字符/token，
-- 中文按 0.45 token/字节
local function estimate_tokens(s)
  if not s then return 0 end
  s = tostring(s)
  local ascii, non_ascii = 0, 0
  for i = 1, #s do
    if s:byte(i) < 128 then ascii = ascii + 1 else non_ascii = non_ascii + 1 end
  end
  return math.floor(ascii / 4 + non_ascii * 0.45)
end

local function msg_bytes(msg)
  local total = 0
  if type(msg.content) == "string" then total = total + #msg.content end
  if type(msg.tool_calls) == "table" then
    for _, tc in ipairs(msg.tool_calls) do
      if tc["function"] and type(tc["function"].arguments) == "string" then
        total = total + #tc["function"].arguments
      end
    end
  end
  return total
end

local function trim_history(messages)
  -- Cap by count first — 保留 messages[1]（首个 user 消息 = 前缀缓存锚点，
  -- 裁剪会破坏缓存前缀，锚定头部让命中跨裁剪存活）
  if #messages > MAX_HISTORY then
    local trimmed = {messages[1]}
    for i = #messages - MAX_HISTORY + 2, #messages do
      trimmed[#trimmed + 1] = messages[i]
    end
    messages = trimmed
  end
  -- Then cap by total bytes; 优先丢折叠段消息（已进摘要，删除无损——
  -- folded 分支保留为无害兼容，折叠段已由 compact_history 物理删除，
  -- 此路径实际不触发），其次从头丢；保留 messages[1] 与最近消息
  while #messages > 3 do  -- keep the first message + the last 2 (current exchange)
    local total = 0
    for _, m in ipairs(messages) do
      total = total + msg_bytes(m)
    end
    if total <= MAX_HISTORY_BYTES then break end
    local target = nil
    for i = 2, #messages - 2 do
      if messages[i].folded then target = i break end
    end
    table.remove(messages, target or 2)
  end
  return messages
end

-- 物理裁剪到字节预算（保内存优先，OC 2MB 内存约束）: 保留 messages[1]
-- （前缀缓存锚点），从第 2 条起无条件删除（folded 段也删——已进摘要，
-- 且本函数目的就是释放内存），直到总字节 ≤ budget 或只剩 MEM_MIN_KEEP 条。
-- 与 trim_history 的"优先丢折叠段"语义分层:
--   折叠（compact_history 字节阈值 / ensure_context_budget 窗口路径 /
--     模型 compact_history 工具）→ 物理删除折叠段（摘要承载内容），
--     缓存前缀随摘要位置变化 miss 一次——传统自动压缩语义（opencode 同）；
--   物理裁剪（mem_pressure 内存紧张 / load_history 加载上限）→ 无条件
--     释放内存，缓存前缀同样 miss——真机已 OOM 两次（v0.3.45 折叠不
--     释放内存是第二次根因，gist 10d45721），保命优先。
-- JSONL 文件不受影响（append-only 保留完整历史，只动内存表）。
-- 返回裁剪后总字节。
local MEM_MIN_KEEP = 5  -- 最低保留（锚点 + 最近 4 条，与 force_trim 一致）
local function trim_to_bytes(messages, budget)
  local total = 0
  for _, m in ipairs(messages) do total = total + msg_bytes(m) end
  local guard = 0
  while #messages > MEM_MIN_KEEP and total > budget and guard < 10000 do
    guard = guard + 1
    total = total - msg_bytes(messages[2])
    table.remove(messages, 2)
  end
  -- 只剩 MEM_MIN_KEEP 条仍超预算（个别超大消息）: 保锚点 + 最近消息兜底
  while #messages > 3 and total > budget and guard < 10000 do
    guard = guard + 1
    total = total - msg_bytes(messages[2])
    table.remove(messages, 2)
  end
  return total
end

-- 构建发送给摘要模型的 transcript，返回 {text, parts}——parts[i] 是 text
-- 第 i 行对应的原始消息（KEEP 展开时按行号找回原文）。纯函数:
-- compact_history 与 summarize_history 对同一批消息调用结果一致。
local function build_transcript(messages)
  local parts, text_parts = {}, {}
  for _, m in ipairs(messages) do
    local role = m.role or "?"
    local content = ""
    if m.content and m.content ~= "" then
      content = m.content
    elseif m.tool_calls then
      local names = {}
      for _, tc in ipairs(m.tool_calls) do
        names[#names + 1] = (tc["function"] and tc["function"].name) or "?"
      end
      content = "[tool_calls: " .. table.concat(names, ", ") .. "]"
    elseif m.role == "tool" then
      content = tostring(m.content):sub(1, 200)
    end
    if content ~= "" then
      parts[#parts + 1] = m
      text_parts[#text_parts + 1] = string.format("[%d] %s: %s", #parts, role, content)
    end
  end
  local text = table.concat(text_parts, "\n")
  -- Cap what we send to the summarizer
  if #text > 12000 then
    text = text:sub(1, 12000) .. "\n...[truncated]"
  end
  return {text = text, parts = parts}
end

-- Ask the LLM to summarize older messages. Independent minimal request
-- (no tools, no runtime block, no main system prompt — only the summary
-- instruction + transcript, via chat() opts) so it can't recurse into
-- compaction. Returns summary string or nil on failure (empty summary
-- after one retry, or transport error).
local function summarize_history(messages, config, previous_summary)
  local transcript = build_transcript(messages).text

  -- Anchored summary (opencode-style): when a previous summary exists, ask the
  -- model to UPDATE it instead of summarizing from scratch. Keeps older facts
  -- stable and saves tokens. KEEP/REF 指令（opencode-acp 移植）: KEEP 行号标记
  -- 嵌入关键原文，REF 行号标记做省 token 的引用指针；压缩后由
  -- expand_keep_markers 展开。七节骨架（reasonix compact 借鉴）。
  local sys_prompt = "You are a conversation summarizer for an AI agent running inside OpenComputers (Minecraft). Keep: user goals and questions, decisions, tool results that matter, file paths, component addresses, and any constraints. Preserve factual details. Output only the summary, no preamble.\n\nOrganize the summary with these sections: Standing facts（持续成立的事实）、Goal（当前目标）、Decisions（已做的决定及理由）、Files（涉及的文件与改动）、Commands（重要命令）、Errors（关键错误与教训）、Pending（未完成事项）。Omit sections that have nothing to report.\n\nTranscript lines are numbered [N]. If any message is critical to preserve VERBATIM (exact tool result, exact error text, exact user request), inline it in the summary with a marker: [[KEEP:N]] followed by the original text in quotes. For less critical messages, reference them cheaply with [[REF:N|简短描述]] instead of embedding the full text. Use at most 3 KEEP markers and at most 5 REF markers."
  local user_prompt
  if previous_summary and previous_summary ~= "" then
    sys_prompt = "You maintain an anchored summary for an AI agent conversation. Update the previous summary below using the new conversation history: keep still-true details, remove stale ones, merge new facts. Keep it concise. Output only the updated summary.\n\nOrganize the summary with these sections: Standing facts（持续成立的事实）、Goal（当前目标）、Decisions（已做的决定及理由）、Files（涉及的文件与改动）、Commands（重要命令）、Errors（关键错误与教训）、Pending（未完成事项）。Omit sections that have nothing to report.\n\nTranscript lines are numbered [N]. If any message is critical to preserve VERBATIM (exact tool result, exact error text, exact user request), inline it with a marker: [[KEEP:N]] followed by the original text in quotes. For less critical messages, reference them cheaply with [[REF:N|简短描述]] instead of embedding the full text. Use at most 3 KEEP markers and at most 5 REF markers."
    user_prompt = "<previous-summary>\n" .. previous_summary .. "\n</previous-summary>\n\n<new-history>\n" .. transcript .. "\n</new-history>\n\nUpdate the summary."
  else
    user_prompt = "Summarize this conversation:\n\n" .. transcript
  end

  -- Route through the injected chat() (set via set_chat) so session.lua does
  -- not need its own HTTP stack; chat is nil until agent.lua finishes Section 5.
  -- 摘要请求专用瘦身路径（opencode 裸摘要请求同款 + reasonix 'independent
  -- minimal request ... so it can't recurse into compaction' 防递归）:
  --   主请求带 ~5KB system + ~1KB runtime 尾块 + ~10KB tools 声明，摘要
  --   请求全部跳过 → 请求体只剩 [摘要指令 system + transcript user] ≈1KB；
  --   max_tokens 用摘要专用预算（config.summary_max_tokens 默认 16384）——
  --   deepseek 强思考模型下 opencode 的 4096 不够（reasoning 先吃大部分
  --   输出预算，可见摘要 content 被挤掉 → 摘要残缺 → 重复压缩）。
  -- 摘要响应**不持久化**（只提取 content 写摘要消息），128KB 响应体上限
  -- （response_body_limit）已保护——与主请求 8192（长 reasoning 进历史 →
  -- encode OOM）不同场景，专用大 max_tokens 无 OOM 风险。
  local chat = injected_chat
  if type(chat) ~= "function" then return nil end
  local summary_opts = {
    skip_system = true,
    skip_runtime = true,
    skip_tools = true,
    max_tokens = tonumber(config.summary_max_tokens) or 16384,
  }
  -- 请求一次摘要: 返回 (summary, fatal)。fatal=true = 传输/HTTP 失败
  -- （不重试）；fatal=nil + summary=nil = content 空/空白（thinking 模型
  -- reasoning 挤占输出预算的典型表现，可重试）。
  local function request_summary(hint)
    local prompt = user_prompt
    if hint then prompt = prompt .. "\n\n" .. hint end
    local response = chat({
      {role = "system", content = sys_prompt},
      {role = "user", content = prompt}
    }, config, summary_opts)
    if type(response) ~= "table" then return nil, true end
    if response.error then return nil, true end
    local s = response.content
    if not s or s:gsub("%s", "") == "" then return nil end
    return s
  end

  local summary, fatal = request_summary(nil)
  if not summary then
    if fatal then return nil end  -- 传输失败: 不重试（与空摘要区分）
    -- 空摘要兜底（v0.3.33 空回答重试网简化版，摘要专用一次重试）:
    -- thinking 模型 reasoning 挤占输出预算时 content 空/空白——注入
    -- "直接输出摘要"提示再调一次；仍空返回 nil → compact_history 走
    -- trim 兜底（force_trim/字节裁剪），不阻断压缩流程。
    print("[compact] 摘要为空（可能被 reasoning 挤占），重试一次...")
    summary, fatal = request_summary(
      "Please output the summary directly as plain text now. Do not output reasoning/thinking content.")
    if not summary then
      print("[compact] 摘要重试仍" .. (fatal and "失败" or "为空")
        .. "，放弃压缩（调用方走 trim 兜底）")
      return nil
    end
  end
  return summary
end

-- KEEP/REF 标记展开（opencode-acp keep-markers 移植）: 摘要里的 [[KEEP:N]]
-- 替换为对应消息原文（截断 KEEP_EMBED_MAX_CHARS）；[[REF:N|desc]] 只展开为
-- 引用指针 "[消息 N] desc"（描述来自摘要本身，不嵌入原文——省 token）。
-- 越界引用保留原样并警告（非阻塞质量门——引用解析率是压缩质量指标，
-- 失败不阻断压缩）。
local KEEP_PATTERN = "%[%[KEEP:(%d+)%]%]"
local REF_PATTERN = "%[%[REF:(%d+)%|([^%]]-)%]%]"
local KEEP_EMBED_MAX_CHARS = 1000

local function expand_keep_markers(summary, transcript_parts)
  summary = (summary:gsub(KEEP_PATTERN, function(idx_s)
    local idx = tonumber(idx_s)
    local m = transcript_parts and transcript_parts[idx]
    if not m then
      print("[compact] KEEP 引用越界: " .. idx_s)
      return "[[KEEP:" .. idx_s .. "]]"
    end
    local content = ""
    if type(m.content) == "string" then
      content = m.content
    elseif m.tool_calls then
      local names = {}
      for _, tc in ipairs(m.tool_calls) do
        names[#names + 1] = (tc["function"] and tc["function"].name) or "?"
      end
      content = "[tool_calls: " .. table.concat(names, ", ") .. "]"
    end
    if #content > KEEP_EMBED_MAX_CHARS then
      content = content:sub(1, KEEP_EMBED_MAX_CHARS)
        .. "\n...[truncated, " .. #content .. " chars total]"
    end
    local label = m.role or "?"
    return "\n--- [KEEP:" .. idx_s .. ": " .. label .. "] ---\n"
      .. content .. "\n--- end ---\n"
  end))
  -- REF 引用指针: 展开为 "[消息 N] desc"（不嵌原文）
  return (summary:gsub(REF_PATTERN, function(idx_s, desc)
    local idx = tonumber(idx_s)
    local m = transcript_parts and transcript_parts[idx]
    if not m then
      print("[compact] REF 引用越界: " .. idx_s)
      return "[[REF:" .. idx_s .. "|" .. desc .. "]]"
    end
    return "[消息 " .. idx .. "] " .. desc
  end))
end

-- 折叠段归档（2026-08-10 硬盘利用）: compact_history 物理删除折叠段前，
-- 先 append 到 <history_path>.archive.jsonl（磁盘冷存储，内存零成本）。
-- 用途: ①可追溯——被折叠的原文永久保留，模型需要旧消息时可 read_file
-- 读归档（JSONL 逐行，grep 定位）；②修正旧注释"JSONL append-only 完整
-- 保留"的谎言——compact 后调用方 rebuild_history 用内存表重写文件，
-- 折叠段从主文件消失，此前是彻底丢失。
-- 限制: 磁盘满时静默跳过（compact 主流程不受影响，内存优先）；归档只
-- 增不减，超限由 /relocate 换盘或手动清理承担（用户明确"尽可能利用
-- 硬盘"）。
local function archive_folded(messages)
  if not messages or #messages == 0 then return end
  local f = io.open(history_path .. ".archive.jsonl", "a")
  if not f then return end
  for _, m in ipairs(messages) do
    local ok_w, werr = pcall(f.write, f, json.encode(m), "\n")
    if not ok_w then break end
  end
  f:close()
end
-- Compact（传统 opencode 自动压缩语义）: 折叠段消息**物理删除**——
-- （含 KEEP/REF 静态展开的原文，见下方 expand_keep_markers 调用点）已
-- 承载旧消息内容；折叠段不进请求体、对缓存无贡献，留在内存表纯占内存
-- （真机第二次 OOM 根因: 折叠不释放内存，93.6KB JSONL → 表 ~300KB
-- 驻留）。删除仅释放内存；**原文由 archive_folded 归档到
-- history.archive.jsonl（磁盘冷存储）承担可追溯**（旧注释称"JSONL
-- append-only 完整保留"与实际不符——compact 后 rebuild_history 用内存
-- 表重写主文件，折叠段会从主文件消失）。旧摘要消息被新摘要取代（锚定
-- 更新语义不变）。请求构造/估算的 folded 分支逻辑保留（无害兼容——
-- 折叠段已不存在，未来也不会再产生）。
local function compact_history(messages, config)
  if #messages <= COMPACT_KEEP + 1 then return nil end
  local keep = COMPACT_KEEP
  local est = 0
  for i = #messages, #messages - keep + 1, -1 do
    est = est + estimate_tokens(messages[i].content or "")
  end
  while keep < COMPACT_KEEP_MAX and est < COMPACT_KEEP_MIN_TOKENS
      and #messages - keep >= 1 do
    keep = keep + 1
    est = est + estimate_tokens(messages[#messages - keep + 1].content or "")
  end
  local previous_summary
  local old = {}
  for i = 1, #messages - keep do
    local m = messages[i]
    if m.role == "system" and type(m.content) == "string" then
      local s = m.content:match("^%[对话摘要%] (.*)$")
      if s then
        previous_summary = s
        -- drop the old summary message from the fold (it's passed separately)
      else
        old[#old + 1] = m
      end
    else
      old[#old + 1] = m
    end
  end
  local summary = summarize_history(old, config, previous_summary)
  if not summary then return nil end
  -- KEEP 标记展开（与 summarize 同源 transcript 序号）
  summary = expand_keep_markers(summary, build_transcript(old).parts)

  -- 折叠段**物理删除**（不标记、不驻留）: 旧摘要消息被新摘要取代直接
  -- 丢弃；其余折叠段内容已进摘要（KEEP/REF 展开），删除仅释放内存——
  -- 请求体本就是 [摘要 + 保留段]（folded 分支跳过），折叠段对缓存无
  -- 贡献，纯占内存。JSONL append-only 完整保留可追溯。
  -- 保留段首条不能是 role=tool（孤立 tool 消息缺陷，真机 gist 783a0f7
  -- 实证）: 若折叠边界恰落在 assistant(tool_calls) 与其 tool 结果之间，
  -- 保留段以孤立 tool 开头——OpenAI 规范要求 tool 消息必须对应前置
  -- assistant.tool_calls（部分端点直接 400，opencode.ai/zen 实测宽容
  -- 但这是请求合法性缺陷）。修复：首条是 tool 则向前多保留一条（其
  -- 前置 assistant），保证保留段以 user/assistant/system 开头。
  local first_keep = #messages - keep + 1
  while first_keep > 1 and messages[first_keep].role == "tool" do
    first_keep = first_keep - 1
  end
  -- 折叠段归档到磁盘（先于物理删除; old 含旧摘要以外的全部折叠消息。
  -- 磁盘满静默跳过——内存优先，compact 主流程不受影响）
  archive_folded(old)
  local result = {{role = "system", content = "[对话摘要] " .. summary}}
  for i = first_keep, #messages do
    result[#result + 1] = messages[i]
  end
  -- 就地替换（调用方持有同一表引用）
  for i = #messages, 1, -1 do messages[i] = nil end
  for i = 1, #result do messages[i] = result[i] end
  return messages
end

-- 压缩触发判定（tokens 上限阈值驱动，用户要求按 context_window 比例）:
--   估算 tokens ≥ 窗口 × COMPACT_WINDOW_RATIO → 压缩；条数 ≥
--   COMPACT_TRIGGER_COUNT 兜底（防海量小消息退化）。
-- window 缺省/为 0 时仅按条数。超限场景由 ensure_context_budget 的
-- 80% 窗口估算先行（压缩失败再 force_trim）。
local function should_compact(messages, window)
  if #messages <= COMPACT_KEEP + 1 then return false end
  if #messages >= COMPACT_TRIGGER_COUNT then return true end
  local w = tonumber(window) or 0
  if w <= 0 then return false end
  local est = 0
  for _, m in ipairs(messages) do
    if not m.folded then
      est = est + estimate_tokens(m.content or "")
          + estimate_tokens(m.tool_calls and tostring(m.tool_calls) or "")
      if est >= w * COMPACT_WINDOW_RATIO then return true end
    end
  end
  return false
end

-- Append-only session log: each line is one JSON-encoded message.
-- Append per message (O(new) memory) instead of rewriting the whole history
-- (O(n) each call, O(n^2) cumulative). load_history replays + trims.
-- 写盘失败警告（真机 2026-08-10 现场: 数据盘满 → io.open("a") 失败原本
-- 静默——新消息只进内存不进文件，且会话继续积累最终 encode OOM;
-- json.lua:98 table.concat 是 encode 峰值点）。首次失败打印一次，
-- disk_warned 防止刷屏。
local disk_warned = false
local function warn_disk(label)
  if disk_warned then return end
  disk_warned = true
  print("[disk] 警告: " .. label .. " 写盘失败（数据盘可能已满）——"
    .. "新消息仅存内存，重启后丢失；请清理磁盘或 /new 归档后重试")
end
local function append_history(msg)
  local f = io.open(history_path, "a")
  if not f then
    warn_disk("history")
    return
  end
  f:write(json.encode(msg), "\n")
  f:close()
end

-- Full rewrite of the session log (after compaction / new session / reset).
local function rebuild_history(messages)
  local f = io.open(history_path, "w")
  if not f then
    warn_disk("history")
    return
  end
  for _, m in ipairs(messages) do
    f:write(json.encode(m), "\n")
  end
  f:close()
end

-- 加载 history 到内存表（有界）。流式逐行读取——真机 2026-08-10 OOM
-- 根因修复: 旧实现 f:read("*a") 一次性读全文件再逐行 decode，峰值 =
-- 文件全文 + 解析表 + decode 中间态，数据盘满（history 巨大）时 2MB
-- 内存必爆；且 /debug 的 collect 也走 load_history → gist 提交失败。
-- 现改为逐行读: 峰值 = 单行 + 有界表（MAX_LOAD_HISTORY 条 + 字节预算），
-- 与文件总大小解耦。legacy 迁移路径保留全读（旧格式一次性迁移，量小）。
local function load_history()
  local fs = require("filesystem")
  if not fs.exists(history_path) then return {} end
  local f = io.open(history_path, "r")
  if not f then return {} end

  -- 首行探测格式（原逻辑只依赖 content 首字符 + 引号 role 键）
  local first_line = f:read("*l")
  if not first_line then f:close() return {} end
  local line0 = first_line:gsub("\r$", "")
  local is_json_lines = line0:sub(1, 1) == "{" and line0:find('"role"', 1, true) ~= nil

  if not is_json_lines then
    -- Legacy format (whole-table serialization): migrate once to JSON-line
    -- format. 一次性迁移（旧格式文件通常远小于 JSONL 积累），全读可接受。
    f:close()
    local f2 = io.open(history_path, "r")
    if not f2 then return {} end
    local content = f2:read("*a")
    f2:close()
    if content == "" then return {} end
    local ser = require("serialization")
    local ok, data = pcall(ser.unserialize, content)
    if ok and type(data) == "table" and (data[1] or data.role) then
      local list = data.role and {data} or data
      rebuild_history(list)  -- migrate
      return trim_history(list)
    end
    return {}
  end

  -- JSON-line format: 流式逐行，跳过损坏行。
  local messages = {}
  -- 条数上限（内存表有界）: 超过 MAX_LOAD_HISTORY 条丢更早的——真机
  -- 93.6KB JSONL 全量解析后表 ~300KB（OOM 根因之一）。文件本身
  -- append-only 完整保留（可追溯），只限内存表。
  local MAX_LOAD_HISTORY = math.floor(120 * MEM_SCALE)
  local function ingest(line)
    local ok2, msg = pcall(json.decode, line)
    if ok2 and type(msg) == "table" and msg.role then
      if #messages == MAX_LOAD_HISTORY then
        table.remove(messages, 1)
      end
      messages[#messages + 1] = msg
    end
  end
  ingest(line0)
  for line in f:lines() do
    ingest(line:gsub("\r$", ""))
  end
  f:close()
  -- 字节上限: 解析后表裁剪到 mem_load_budget（可配，默认 100KB）。
  -- 配置经 pcall 读取（真机/测试均安全，缺失/损坏回退默认值）。
  local ok_cfg, cfg = pcall(config_mod.load)
  local load_budget = tonumber(ok_cfg and cfg and cfg.mem_load_budget) or 100000
  trim_to_bytes(messages, load_budget)

  -- 磁盘防护（真机 2026-08-10 现场: 数据盘满 + history 文件巨大）:
  -- append-only 文件跨会话无限累积（内存表每次只取 ≤120 条/100KB，
  -- 但文件本身只增不减），盘小（OC 数据盘通常 <1MB）时最终写满——
  -- 磁盘满又导致 append 静默失败 → 会话内存膨胀 → encode OOM
  -- （json.lua:98）。修复: 文件超过 mem_history_max_bytes（默认 256KB）
  -- 时自动 rebuild 截断到内存表规模（早段仅文件里有，内存表本就不
  -- 加载它们，截断不丢任何已加载内容；可追溯性由 /new 归档承担）。
  -- 文件大小用标准库 io.open+seek 获取（OpenOS filesystem 库无 size，
  -- 组件 getSize 需 proxy 解析；标准库最稳，测试环境也可用）。
  local history_size = 0
  local hf = io.open(history_path, "r")
  if hf then
    history_size = hf:seek("end") or 0
    hf:close()
  end
  local max_file = tonumber(ok_cfg and cfg and cfg.mem_history_max_bytes) or 256000
  if history_size > max_file then
    print("[disk] history 文件 " .. history_size .. "B 超过上限 " .. max_file
      .. "B，自动截断到当前内存表（" .. #messages .. " 条）...")
    rebuild_history(messages)
  end
  return trim_history(messages)
end

-- Redirect history storage (replaces the old agent_test HISTORY_PATH
-- rebinding hack). Tests call agent_test.set_history_path → this.
local function set_paths(p)
  history_path = p
end

-- 当前会话文件路径（/hist 显示会话名用）
local function current_path()
  return history_path
end

-- 会话列表（类 opencode /session）: 扫描目录下 *.jsonl 会话文件
--（/new 归档的 .txt 是归档而非会话，不列入）。dir 缺省用配置的
-- sessions 目录（测试可注入临时目录）。
-- 返回 {{name, count, modified}, ...} 按 modified 倒序。
local function list_sessions(dir)
  local fs = require("filesystem")
  local base = dir or sessions_dir
  -- pcall 兼容两环境: 真实 OC 对不存在路径抛错，测试 mock 返回空迭代器
  local ok_l, iter = pcall(fs.list, base)
  if not ok_l or type(iter) ~= "function" then return {} end
  local out = {}
  for name in iter do
    if name:sub(-6) == ".jsonl" then
      local path = base .. "/" .. name
      local count = 0
      local f = io.open(path, "r")
      if f then
        for _ in f:lines() do count = count + 1 end
        f:close()
      end
      local modified = 0
      local ok_m, m = pcall(fs.lastModified, path)
      if ok_m and m then modified = m end
      out[#out + 1] = {name = name:sub(1, -7), count = count, modified = modified}
    end
  end
  table.sort(out, function(a, b) return a.modified > b.modified end)
  return out
end

-- 运行时切换 sessions 目录（/relocate 迁移后立即生效；重启后由
-- config 的 data_dir 引导自动落到新盘）。
local function set_sessions_dir(p)
  sessions_dir = p
end

-- 当前 sessions 目录（disk 工具 list_storage 统计占用用）
local function get_sessions_dir()
  return sessions_dir
end

-- 磁盘清理（2026-08-10 新增，配合 /cleanup）: 删除非当前会话的旧
-- 会话文件（保留最近 keep 个，keep=0 仅保留当前）。当前会话按路径
-- 精确匹配（/session 切换后当前文件在 sessions 目录内）。返回
-- (删除数, 释放字节)。归档 .txt（/new 产物）不动——清理只针对
-- *.jsonl 会话文件；history 文件本体由 init.lua /cleanup 按
-- mem_history_max_bytes 截断。
local function cleanup_sessions(keep)
  local sessions = list_sessions()
  local current = current_path()
  local deleted, freed = 0, 0
  for i, s in ipairs(sessions) do
    if i > (keep or 0) then
      local path = sessions_dir .. "/" .. s.name .. ".jsonl"
      if path ~= current then
        local size = 0
        local f = io.open(path, "r")
        if f then
          size = f:seek("end") or 0
          f:close()
        end
        local ok_rm, res = pcall(os.remove, path)
        -- os.remove 成功返回 true（非 nil）；失败返回 nil + 错误信息。
        -- 曾误写 err==nil（成功时 err=true 恒不成立 → 永远删不掉，
        -- 2026-08-10 smoke 测试捕获）。
        if ok_rm and res == true then
          deleted = deleted + 1
          freed = freed + size
        end
      end
    end
  end
  return deleted, freed
end

-- Inject the chat client (agent.lua calls this after Section 5 defines
-- chat). Needed by summarize_history's LLM call.
local function set_chat(fn)
  injected_chat = fn
end

return {
  load_history = load_history,
  append_history = append_history,
  rebuild_history = rebuild_history,
  trim_history = trim_history,
  -- 物理字节裁剪（mem_pressure / load_history 上限共用，init.lua 引用）
  trim_to_bytes = trim_to_bytes,
  compact_history = compact_history,
  should_compact = should_compact,
  summarize_history = summarize_history,
  set_paths = set_paths,
  set_sessions_dir = set_sessions_dir,
  get_sessions_dir = get_sessions_dir,
  cleanup_sessions = cleanup_sessions,
  set_chat = set_chat,
  current_path = current_path,
  list_sessions = list_sessions,
  -- Exported because agent.lua's process_exchange still uses this constant.
  MAX_TOOL_RESULT = MAX_TOOL_RESULT,
  -- head+tail 每半预算（init.lua 截断用）
  TOOL_RESULT_KEEP = TOOL_RESULT_KEEP,
  -- 单一 token 估算实现（init.lua 引用，避免重复定义）
  estimate_tokens = estimate_tokens,
}
