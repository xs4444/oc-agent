-- wire_check.lua: 本地 mock 捕获 chat() 请求体，验证 ask_user 声明
-- 用法: ../lua_portable/bin/lua.exe -e "package.path = './?.lua;' .. (package.path or '')" wire_check.lua
local oc_mock = require("oc_mock")
component = oc_mock.component
computer = oc_mock.computer
filesystem = oc_mock.filesystem
shell = oc_mock.shell
internet = oc_mock.internet
serialization = oc_mock.serialization
event = oc_mock.event
local orig_require = require
package.loaded["component"] = oc_mock.component
package.loaded["computer"] = oc_mock.computer
package.loaded["filesystem"] = oc_mock.filesystem
package.loaded["shell"] = oc_mock.shell
package.loaded["internet"] = oc_mock.internet
package.loaded["serialization"] = oc_mock.serialization
package.loaded["event"] = oc_mock.event
_TEST_MODE = true

-- 拦截 internet.request：捕获请求参数，返回假响应
local captured
local orig_request = oc_mock.internet.request
oc_mock.internet.request = function(url, body, headers)
  captured = {url = url, body = body, headers = headers}
  local fake = {
    __index = { response = function() return 200 end },
  }
  return setmetatable({}, { __index = fake.__index, __call = function() return nil end })
end

local ok, err = pcall(dofile, "../src/agent/init.lua")
if not ok then print("LOAD FAILED: " .. tostring(err)); os.exit(1) end

local config = {api_key = "free", model = "deepseek-v4-flash-free", api_url = "https://opencode.ai/zen/v1/chat/completions"}
local cok, resp = pcall(agent_test.chat, {{role = "user", content = "尝试调用 ask_user 工具"}}, config)
print("chat pcall ok:", cok)
print("chat resp:", resp and (resp.content or tostring(resp.error)))

if captured then
  print("=== 请求体 (url: " .. captured.url .. ") ===")
  local json = require("agent.json")
  local body = json.decode(captured.body)
  local tools = body.tools or {}
  print("tools 数组工具数: " .. #tools)
  local has_ask = false
  for _, t in ipairs(tools) do
    local fn = t["function"] or {}
    print("  - " .. tostring(fn.name))
    if fn.name == "ask_user" then has_ask = true end
  end
  print("tools 含 ask_user: " .. tostring(has_ask))
  local sys = body.messages[1].content
  print("系统提示含 ask_user: " .. tostring(sys:find("ask_user") ~= nil))
  local s, e = sys:find("Available tools:")
  if s then print("--- 系统提示 Available tools 段 ---"); print(sys:sub(s, s + 1400)) end
else
  print("未捕获到请求")
end
