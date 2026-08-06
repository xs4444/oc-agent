-- reasoning_e2e_test.lua: ocvm 实测 reasoning_content 传回修复
-- 场景: 真实模型返回 reasoning_content + tool_calls → 主循环执行工具 →
--       第二轮请求带 reasoning_content → 必须成功（否则 400）
-- 用法: lua /mnt/<short>/reasoning_e2e_test.lua /mnt/<short> <api_key> <model> <api_url>
local base = ({...})[1] or "/mnt"
local api_key = ({...})[2] or "free"
local model = ({...})[3] or "deepseek-v4-flash"
local api_url = ({...})[4] or "https://opencode.ai/zen/go/v1/chat/completions"

local PASS, FAIL = 0, 0
local function log(...)
  local parts = {}
  for i = 1, select("#", ...) do parts[i] = tostring(select(i, ...)) end
  local line = table.concat(parts, " ")
  print(line)
  local f = io.open(base .. "/reasoning_e2e_result.txt", "a")
  if f then f:write(line .. "\n") f:close() end
end
io.open(base .. "/reasoning_e2e_result.txt", "w"):close()
local function check(name, cond, detail)
  if cond then PASS = PASS + 1 log("PASS " .. name)
  else FAIL = FAIL + 1 log("FAIL " .. name .. (detail and (" -- " .. tostring(detail)) or "")) end
end

local fs = require("filesystem")
local agent_path
for item in fs.list("/mnt") do
  local full = "/mnt/" .. item
  if fs.exists(full .. "/agent.lua") then agent_path = full .. "/agent.lua" break end
end
if not agent_path then log("ERROR: agent.lua not found") log("RESULT: 0 pass, 0 fail") return end

_TEST_MODE = true
local ok, err = pcall(dofile, agent_path)
check("agent loads", ok, err)
if not ok then log("RESULT: " .. PASS .. " pass, " .. FAIL .. " fail") return end

-- 完整主循环 exchange: 强制模型调用工具（触发 reasoning + tool_calls 链）
local config = {api_key = api_key, model = model, api_url = api_url, context_window = 128000}
local messages = {}
local res = agent_test.process_exchange(
  messages, config,
  "必须调用 calc 工具计算 12*34 的结果，然后直接报告结果数字，不要调用其他工具。",
  false
)

if res and res.error then
  log("ERROR: " .. tostring(res.error))
  check("exchange succeeds (no 400)", false, tostring(res.error):sub(1, 300))
else
  check("exchange succeeds (no 400)", true)
  log("final text: " .. tostring(res and res.text or "?"):sub(1, 200))
end

-- 校验 assistant 消息带 reasoning_content（修复的核心）
local assistant_msgs = 0
local with_reasoning = 0
local tool_calls_seen = 0
for _, m in ipairs(messages) do
  if m.role == "assistant" then
    assistant_msgs = assistant_msgs + 1
    if m.reasoning_content and m.reasoning_content ~= "" then with_reasoning = with_reasoning + 1 end
    if m.tool_calls then tool_calls_seen = tool_calls_seen + 1 end
  end
end
log("assistant msgs: " .. assistant_msgs .. ", with reasoning: " .. with_reasoning .. ", with tool_calls: " .. tool_calls_seen)
check("assistant messages carry reasoning_content", with_reasoning >= tool_calls_seen or tool_calls_seen == 0,
  "with_reasoning=" .. with_reasoning .. " tool_calls=" .. tool_calls_seen)

log("")
log("RESULT: " .. PASS .. " pass, " .. FAIL .. " fail")
