-- json_ctrl_e2e_test.lua: ocvm 验证控制字符消息不再触发 400
-- 场景: tool 结果/shell 输出含控制字符（\x01 \x1b \x00）→ 请求体 JSON
--       修复前裸控制字符 = 非法 JSON → 400；修复后 \u00XX 转义 → 200
-- 用法: lua /mnt/<short>/json_ctrl_e2e_test.lua /mnt/<short> <api_key> <model> <api_url>
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
  local f = io.open(base .. "/json_ctrl_e2e_result.txt", "a")
  if f then f:write(line .. "\n") f:close() end
end
io.open(base .. "/json_ctrl_e2e_result.txt", "w"):close()
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

-- 本地 json 编码检查（与请求体同路径）
local json = require("agent.json")
local ctrl_content = "probe: " .. string.char(1) .. "\27[31mcolored" .. string.char(0) .. "end"
local enc = json.encode(ctrl_content)
check("json escapes control chars", enc:find("[%c]") == nil, enc)

-- 真实请求: 消息含控制字符（模拟 shell/probe 输出污染），序列合法
local config = {api_key = api_key, model = model, api_url = api_url, context_window = 128000}
local messages = {
  {role = "system", content = "You are a concise test assistant. Reply with exactly: OK_OK"},
  {role = "user", content = "please reply OK"},
  {role = "assistant", content = "",
   tool_calls = {{id = "t1", type = "function", ["function"] = {name = "read_file", arguments = '{"path":"/x"}'}}}},
  {role = "tool", tool_call_id = "t1", content = ctrl_content},
  {role = "user", content = "continue"},
}
local cok, resp = pcall(agent_test.chat, messages, config)
if not cok then
  check("chat with control chars succeeds", false, "chat threw: " .. tostring(resp))
elseif resp.error then
  check("chat with control chars succeeds", false, tostring(resp.error):sub(1, 300))
else
  check("chat with control chars succeeds", true)
  log("finish_reason: " .. tostring(resp.finish_reason))
  log("content: " .. tostring(resp.content and resp.content:sub(1, 100) or ""))
end

log("")
log("RESULT: " .. PASS .. " pass, " .. FAIL .. " fail")
