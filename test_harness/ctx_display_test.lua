-- ctx_display_test.lua: ocvm 验证 /ctx 渲染（ANSI + 真实 OpenOS）
-- 用法: lua /mnt/<short>/ctx_display_test.lua /mnt/<short>
local base = ({...})[1] or "/mnt"
local fs = require("filesystem")
local agent_path
for item in fs.list("/mnt") do
  local full = "/mnt/" .. item
  if fs.exists(full .. "/agent.lua") then agent_path = full .. "/agent.lua" break end
end
local PASS, FAIL = 0, 0
local function log(...)
  local parts = {}
  for i = 1, select("#", ...) do parts[i] = tostring(select(i, ...)) end
  local line = table.concat(parts, " ")
  print(line)
  local f = io.open(base .. "/ctx_display_test_result.txt", "a")
  if f then f:write(line .. "\n") f:close() end
end
io.open(base .. "/ctx_display_test_result.txt", "w"):close()
local function check(name, cond, detail)
  if cond then PASS = PASS + 1 log("PASS " .. name)
  else FAIL = FAIL + 1 log("FAIL " .. name .. (detail and (" -- " .. tostring(detail)) or "")) end
end

_TEST_MODE = true
local ok, err = pcall(dofile, agent_path)
check("agent loads", ok, err)
if not ok then log("RESULT: " .. PASS .. " pass, " .. FAIL .. " fail") return end

-- /ctx 无请求记录分支
agent_test.cmd_ctx({context_window = 128000, model = "test"}, {})
-- /ctx 带 usage 分支（模拟已请求）
local msgs = {
  {role = "system", content = "You are an assistant in OpenComputers."},
  {role = "user", content = "你好，请看看这个文件的内容"},
  {role = "tool", tool_call_id = "t1", content = "file content line1\nline2\nline3"},
  {role = "assistant", content = "我看到了，共 3 行"},
}
agent_test.cmd_ctx(
  {context_window = 128000, model = "deepseek-v4-flash"},
  msgs,
  {prompt_tokens = 45678, completion_tokens = 321}
)
log("ANSI 转义可见: " .. tostring(agent_test.ctx_bar(0.5, 40):find("\27") ~= nil))

-- 校验函数本身（不依赖屏幕）
check("estimate_tokens mixed", agent_test.estimate_tokens("hello 世界 test") > 0)
check("ctx_bar contains block chars", agent_test.ctx_bar(0.5, 40):find("█") ~= nil)

log("")
log("RESULT: " .. PASS .. " pass, " .. FAIL .. " fail")
