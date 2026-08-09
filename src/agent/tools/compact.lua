-- ═══════════════════════════════════════════════════════════════
-- agent.tools.compact — 压缩工具（v0.3.47 起: 传统自动压缩为主，本工具为
-- 模型主动压缩的辅助路径）。opencode 传统模式: 表字节超 mem_prefold_bytes
-- 时 process_exchange 请求前系统自动折叠（不依赖模型调用本工具）；本
-- 工具保留给模型想主动压缩时使用（上下文占用仍注入运行时尾部块），
-- 80% 窗口硬保护（防 400/超限）与 trim 内存保护不变。
--
-- deps 注入（agent.execute → init.lua DEPS）:
--   json, load_config, compact_history, get_context, rebuild_current
-- get_context/rebuild_current 由 process_exchange 每次调用注入。
-- ═══════════════════════════════════════════════════════════════

local tools = {
  {type = "function", ["function"] = {
    name = "compact_history",
    description = "Compress conversation history: replace old messages with an LLM summary, keeping recent messages verbatim. Call this when your context usage (shown in runtime status) is >=60% of the model window, or the history contains many stale tool results. Critical tool results and errors are preserved inline in the summary via KEEP markers.",
    parameters = {type = "object", properties = {topic = {type = "string", description = "Optional topic hint to focus the summary on"}}},
  }},
}

local function exec(name, args, deps)
  if name ~= "compact_history" then return nil end
  local get_context = deps.get_context
  if type(get_context) ~= "function" then
    return "compact_history unavailable: no session context"
  end
  local messages = get_context()
  if not messages or #messages <= 6 then
    return "history too short to compact (" .. tostring(messages and #messages or 0) .. " messages)"
  end
  local config = deps.load_config and deps.load_config() or {}
  local old_count = #messages
  local compacted = deps.compact_history(messages, config)
  if not compacted then
    return "compaction failed (summarizer unavailable or error)"
  end
  -- 传统自动压缩（opencode 模式）: compact_history 已就地完成——折叠段
  -- **物理删除** + 头部插入摘要，messages 与 compacted 是同一表，无需
  -- 替换。折叠段从内存表释放（释放内存是压缩的核心目的之一——折叠段
  -- 不进请求体、对缓存无贡献，纯占内存）；JSONL append-only 完整保留
  -- 历史可追溯。
  local deleted = old_count - #messages  -- 物理删除条数
  local kept = #messages - 1              -- 摘要之外的保留条数
  local rebuild = deps.rebuild_current
  if type(rebuild) == "function" then
    local ok, err = pcall(rebuild, messages)
    if not ok then print("[compact] rebuild failed: " .. tostring(err)) end
  end
  return string.format(
    "history compacted: %d old messages folded into an LLM summary and removed from memory (session log keeps full history); %d messages kept verbatim.",
    deleted, kept)
end

return {tools = tools, exec = exec}
