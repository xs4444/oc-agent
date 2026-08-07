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

local MAX_HISTORY = 20
local MAX_HISTORY_BYTES = 50000  -- ~50KB budget; large tool results trimmed away
local MAX_TOOL_RESULT = 3000     -- per-tool-result cap (exported: agent.lua uses it in process_exchange)

local COMPACT_KEEP = 4          -- recent messages kept verbatim after compaction
local COMPACT_TRIGGER_COUNT = 16  -- auto-compact when history exceeds this many messages
local COMPACT_TRIGGER_BYTES = 40000 -- ... or this many bytes (of the 50KB budget)

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
  -- Then cap by total bytes (drop oldest until under budget); 同样保留
  -- messages[1]，从第 2 条开始丢
  while #messages > 3 do  -- keep the first message + the last 2 (current exchange)
    local total = 0
    for _, m in ipairs(messages) do
      total = total + msg_bytes(m)
    end
    if total <= MAX_HISTORY_BYTES then break end
    table.remove(messages, 2)
  end
  return messages
end

-- Ask the LLM to summarize older messages. Independent minimal request
-- (no tools, no system prompt) so it can't recurse into compaction.
-- Returns summary string or nil on any failure.
local function summarize_history(messages, config, previous_summary)
  local transcript_parts = {}
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
      transcript_parts[#transcript_parts + 1] = role .. ": " .. content
    end
  end
  local transcript = table.concat(transcript_parts, "\n")
  -- Cap what we send to the summarizer
  if #transcript > 12000 then
    transcript = transcript:sub(1, 12000) .. "\n...[truncated]"
  end

  -- Anchored summary (opencode-style): when a previous summary exists, ask the
  -- model to UPDATE it instead of summarizing from scratch. Keeps older facts
  -- stable and saves tokens.
  local sys_prompt = "You are a conversation summarizer for an AI agent running inside OpenComputers (Minecraft). Keep: user goals and questions, decisions, tool results that matter, file paths, component addresses, and any constraints. Preserve factual details. Output only the summary, no preamble."
  local user_prompt
  if previous_summary and previous_summary ~= "" then
    sys_prompt = "You maintain an anchored summary for an AI agent conversation. Update the previous summary below using the new conversation history: keep still-true details, remove stale ones, merge new facts. Keep it concise. Output only the updated summary."
    user_prompt = "<previous-summary>\n" .. previous_summary .. "\n</previous-summary>\n\n<new-history>\n" .. transcript .. "\n</new-history>\n\nUpdate the summary."
  else
    user_prompt = "Summarize this conversation:\n\n" .. transcript
  end

  -- Route through the injected chat() (set via set_chat) so session.lua does
  -- not need its own HTTP stack; chat is nil until agent.lua finishes Section 5.
  local chat = injected_chat
  if type(chat) ~= "function" then return nil end
  local response = chat({
    {role = "system", content = sys_prompt},
    {role = "user", content = user_prompt}
  }, config)
  if type(response) ~= "table" then return nil end
  local summary = response.content
  if not summary or summary == "" then return nil end
  return summary
end

-- Compact: replace older messages with an LLM summary, keep recent verbatim.
-- Anchored: if the history already starts with a summary (system message),
-- the new summary is an UPDATE of it (opencode-style), preserving old facts.
-- Returns new message list on success, nil on failure (caller falls back to trim).
local function compact_history(messages, config)
  if #messages <= COMPACT_KEEP + 1 then return nil end
  local previous_summary
  local old = {}
  for i = 1, #messages - COMPACT_KEEP do
    local m = messages[i]
    if m.role == "system" and type(m.content) == "string" then
      local s = m.content:match("^%[对话摘要%] (.*)$")
      if s then
        previous_summary = s
        -- drop the old summary message from the transcript (it's passed separately)
      else
        old[#old + 1] = m
      end
    else
      old[#old + 1] = m
    end
  end
  local summary = summarize_history(old, config, previous_summary)
  if not summary then return nil end

  local result = {{role = "system", content = "[对话摘要] " .. summary}}
  for i = #messages - COMPACT_KEEP + 1, #messages do
    result[#result + 1] = messages[i]
  end
  return result
end

-- Decide whether compaction is worthwhile before trimming
local function should_compact(messages)
  if #messages <= COMPACT_KEEP + 1 then return false end
  if #messages >= COMPACT_TRIGGER_COUNT then return true end
  local total = 0
  for _, m in ipairs(messages) do
    total = total + msg_bytes(m)
    if total >= COMPACT_TRIGGER_BYTES then return true end
  end
  return false
end

-- Append-only session log: each line is one JSON-encoded message.
-- Append per message (O(new) memory) instead of rewriting the whole history
-- (O(n) each call, O(n^2) cumulative). load_history replays + trims.
local function append_history(msg)
  local f = io.open(history_path, "a")
  if not f then return end
  f:write(json.encode(msg), "\n")
  f:close()
end

-- Full rewrite of the session log (after compaction / new session / reset).
local function rebuild_history(messages)
  local f = io.open(history_path, "w")
  if not f then return end
  for _, m in ipairs(messages) do
    f:write(json.encode(m), "\n")
  end
  f:close()
end

local function load_history()
  local fs = require("filesystem")
  if not fs.exists(history_path) then return {} end
  local f = io.open(history_path, "r")
  if not f then return {} end
  local content = f:read("*a")
  f:close()
  if content == "" then return {} end

  -- JSON-line format: one message per line, skip corrupt lines.
  -- Detect it first: the first char is "{" AND the content contains a
  -- quoted "role" key. A legacy whole-table file never matches (OC's
  -- serialization writes bare keys like role="user", no quotes), so this
  -- can't be a false positive — and it prevents a JSON-lines file whose
  -- first line happens to be a valid Lua expression from being
  -- mis-migrated by the unserialize path below.
  local is_json_lines = content:sub(1, 1) == "{" and content:find('"role"', 1, true) ~= nil

  if not is_json_lines then
    -- Legacy format (whole-table serialization): migrate once to JSON-line format.
    local ser = require("serialization")
    local ok, data = pcall(ser.unserialize, content)
    if ok and type(data) == "table" and (data[1] or data.role) then
      local list = data.role and {data} or data
      rebuild_history(list)  -- migrate
      return trim_history(list)
    end
  end

  -- JSON-line format: one message per line, skip corrupt lines.
  local messages = {}
  for line in content:gmatch("[^\r\n]+") do
    local ok2, msg = pcall(json.decode, line)
    if ok2 and type(msg) == "table" and msg.role then
      messages[#messages + 1] = msg
    end
  end
  return trim_history(messages)
end

-- Redirect history storage (replaces the old agent_test HISTORY_PATH
-- rebinding hack). Tests call agent_test.set_history_path → this.
local function set_paths(p)
  history_path = p
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
  compact_history = compact_history,
  should_compact = should_compact,
  summarize_history = summarize_history,
  set_paths = set_paths,
  set_chat = set_chat,
  -- Exported because agent.lua's process_exchange still uses this constant.
  MAX_TOOL_RESULT = MAX_TOOL_RESULT,
}
