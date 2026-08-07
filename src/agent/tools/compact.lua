-- ═══════════════════════════════════════════════════════════════
-- agent.tools.compact — 模型驱动压缩工具（opencode-acp 策略）。
--
-- opencode-acp 的核心: 压缩没有进程内自动触发，由模型看到上下文占用后
-- 主动调用 compress 工具。对应移植: compact_history 工具暴露给模型，
-- 上下文占用百分比注入运行时尾部块（chat.lua build_runtime_block），
-- 模型据此决定何时压缩。进程内仅保留 80% 窗口硬保护（防 400/超限）
-- 与 trim 内存保护。
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
  -- 投影式压缩（reasonix projection 精神）: compact_history 已就地完成——
  -- 折叠段标记 folded + 头部插入摘要，messages 与 compacted 是同一表，
  -- 无需替换。折叠段仍在内存（trim 渐进回收）与 JSONL 历史中（可追溯）。
  local folded_count = 0
  for _, m in ipairs(messages) do
    if m.folded then folded_count = folded_count + 1 end
  end
  local rebuild = deps.rebuild_current
  if type(rebuild) == "function" then
    local ok, err = pcall(rebuild, messages)
    if not ok then print("[compact] rebuild failed: " .. tostring(err)) end
  end
  return string.format(
    "history compacted: %d old messages folded into an LLM summary (projection — originals stay in the session log, trimmed later); %d messages kept verbatim; first message (cache anchor) preserved.",
    folded_count, old_count - folded_count)
end

return {tools = tools, exec = exec}
