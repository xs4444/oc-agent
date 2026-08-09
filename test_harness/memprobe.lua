-- 常驻内存实测（oc_mock 加载，run_tests 同款初始化）
if not os.sleep then os.sleep = function() end end
local oc_mock = require("oc_mock")
component = oc_mock.component
computer = oc_mock.computer
filesystem = oc_mock.filesystem
shell = oc_mock.shell
internet = oc_mock.internet
serialization = oc_mock.serialization
event = oc_mock.event
package.loaded["component"] = oc_mock.component
package.loaded["computer"] = oc_mock.computer
package.loaded["filesystem"] = oc_mock.filesystem
package.loaded["shell"] = oc_mock.shell
package.loaded["internet"] = oc_mock.internet
package.loaded["serialization"] = oc_mock.serialization
package.loaded["event"] = oc_mock.event
_TEST_MODE = true

collectgarbage("collect"); collectgarbage("collect")
local base = collectgarbage("count")
local t0 = os.clock()
local ok, err = pcall(dofile, "../agent.lua")
collectgarbage("collect"); collectgarbage("collect")
local after_load = collectgarbage("count")
if not ok then print("LOAD FAILED: " .. tostring(err)) return end
print(string.format("agent.lua 加载: +%.0fKB (base %.0fKB, %.2fs)", after_load - base, base, os.clock() - t0))

-- 工具声明表（常驻 + 每请求随 body 发送）
local ok_t, tools_mod = pcall(require, "agent.tools")
if ok_t and tools_mod.list then
  local list = tools_mod.list()
  print("tools count: " .. #list)
  local total = 0
  for _, t in ipairs(list) do
    for k, v in pairs(t) do
      if type(v) == "string" then total = total + #v end
    end
  end
  print(string.format("tools 声明文本合计: %.1fKB (全部字符串字段)", total / 1024))
end

-- 系统提示（静态常驻 + 每请求前缀缓存核心）
local ok_chat, chat_mod = pcall(require, "agent.chat")
if ok_chat and chat_mod.build_system_prompt then
  collectgarbage("collect"); local sp0 = collectgarbage("count")
  local sp = chat_mod.build_system_prompt({model = "m", context_window = 128000})
  collectgarbage("collect"); local sp1 = collectgarbage("count")
  print(string.format("system prompt: %d bytes (分配 +%.0fKB)", #sp, sp1 - sp0))
end

-- 模块源码体积（产物内联的 src 文件，读文件估算常驻源码字符串）
local files = {
  "src/agent/init.lua", "src/agent/chat.lua", "src/agent/session.lua",
  "src/agent/tui.lua", "src/agent/http.lua", "src/agent/json.lua",
  "src/agent/config.lua", "src/agent/tools.lua", "src/agent/debug.lua",
  "src/agent/tools/file.lua", "src/agent/tools/compact.lua",
  "src/agent/tools/shell.lua", "src/agent/tools/data.lua",
  "src/agent/tools/search.lua", "src/agent/tools/subagent.lua",
  "src/agent/tools/question.lua", "src/agent/tools/component.lua",
  "src/agent/tools/web.lua",
}
local total_src = 0
for _, f in ipairs(files) do
  local fh = io.open(f, "r")
  if fh then
    local sz = fh:seek("end"); fh:close()
    total_src = total_src + sz
  end
end
print(string.format("模块源码合计: %.1fKB (%d files)", total_src / 1024, #files))
