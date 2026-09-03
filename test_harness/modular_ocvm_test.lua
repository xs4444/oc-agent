-- modular_ocvm_test.lua — ocvm 内模块化验证（Phase 4）
--
-- 验证内容：
--   1. 多文件 require 链在真实 OpenOS 中工作（agent.json / agent.tools 等模块加载）
--   2. 入口 init.lua（部署为 agent.lua）暴露 agent_test 钩子且 TOOLS 完整 19 项
--   3. 插件自举闭环：向 tools/ 目录写入新模块 → 重新扫描 → 自动注册 → 可调用
--
-- 用法: lua /mnt/<short>/modular_ocvm_test.lua /mnt/<short>
-- 结果: 写入 /mnt/<short>/modular_ocvm_test_result.txt

local base = ({...})[1] or "/mnt"

local function log(...)
  print(...)
  local f = io.open(base .. "/modular_ocvm_test_result.txt", "a")
  if f then f:write(table.concat({...}, " ") .. "\n"); f:close() end
end

-- 清理旧结果文件
io.open(base .. "/modular_ocvm_test_result.txt", "w"):close()

local PASS, FAIL = 0, 0
local function check(name, cond, detail)
  if cond then
    PASS = PASS + 1
    log("PASS " .. name)
  else
    FAIL = FAIL + 1
    log("FAIL " .. name .. (detail and (" -- " .. tostring(detail)) or ""))
  end
end

-- ── 1. 多文件 require 链 ─────────────────────────────────────────
package.path = base .. "/?.lua;" .. (package.path or "")
local ok_json, json_mod = pcall(require, "agent.json")
check("require agent.json", ok_json and type(json_mod) == "table", json_mod)
check("json module API", ok_json and type(json_mod.encode) == "function" and type(json_mod.decode) == "function")

local ok_http, http_mod = pcall(require, "agent.http")
check("require agent.http", ok_http and type(http_mod) == "table" and type(http_mod.post) == "function", http_mod)

local ok_cfg, cfg_mod = pcall(require, "agent.config")
check("require agent.config", ok_cfg and type(cfg_mod.load) == "function", cfg_mod)

local ok_sess, sess_mod = pcall(require, "agent.session")
check("require agent.session", ok_sess and type(sess_mod.load_history) == "function", sess_mod)

local ok_chat, chat_mod = pcall(require, "agent.chat")
check("require agent.chat", ok_chat and type(chat_mod.chat) == "function", chat_mod)

local ok_sub, sub_mod = pcall(require, "agent.subagent")
check("require agent.subagent", ok_sub and type(sub_mod.wait_modem_message) == "function", sub_mod)

local ok_tools, tools_mod = pcall(require, "agent.tools")
check("require agent.tools", ok_tools and type(tools_mod.list) == "function", tools_mod)

-- JSON 往返（模块版在真实环境可用）
local enc = json_mod.encode({a = 1, b = "x"})
local dec = json_mod.decode(enc)
check("json roundtrip", dec and dec.a == 1 and dec.b == "x", enc)

-- ── 2. 入口 init.lua 部署形态 ────────────────────────────────────
-- 预置 AGENT_DIR（部署场景下由安装器/启动器设置；OpenOS 的 dofile
-- chunk source 可能不含路径，无法从 debug.getinfo 自推）
AGENT_DIR = base .. "/agent"
_TEST_MODE = true
local ok_load, load_err = pcall(dofile, base .. "/agent/agent.lua")
check("load init.lua as agent.lua", ok_load, load_err)
check("agent_test hooks", ok_load and type(agent_test) == "table", load_err)
check("agent_test.chat", ok_load and type(agent_test.chat) == "function")
check("agent_test.process_exchange", ok_load and type(agent_test.process_exchange) == "function")
check("agent_test.wait_modem_message", ok_load and type(agent_test.wait_modem_message) == "function")
check("global json table (compat)", type(json) == "table" and type(json.encode) == "function")

local tools = agent_test.TOOLS
-- v0.3.124: 工具从 19 精简到 11（删 list_directory/glob/json_query/calc/
-- text_ops/component_list/component_doc/component_invoke）
check("TOOLS count = 11", type(tools) == "table" and #tools == 11, tools and #tools)
-- 11 个工具集合齐全（顺序来自 BUILTIN 模块顺序：file/search/shell/subagent/question/compact）
local EXPECTED = {
  "read_file","edit_file","append_file","write_file","search_files",
  "web_search","shell_execute",
  "subagent_call","subagent_discover","ask_user","compact_history",
}
local names = {}
if type(tools) == "table" then
  for _, t in ipairs(tools) do names[#names + 1] = t["function"] and t["function"].name or "?" end
end
local missing = {}
for _, e in ipairs(EXPECTED) do
  local found = false
  for _, n in ipairs(names) do if n == e then found = true break end end
  if not found then missing[#missing + 1] = e end
end
check("all 19 tools present", #names == 19 and #missing == 0,
  table.concat(missing, ",") .. " | actual: " .. table.concat(names, ","))

-- ── 3. 插件自举闭环 ──────────────────────────────────────────────
-- 模拟 LLM 用 write_file 写新工具模块
local plugin_path = base .. "/agent/tools/zz_hello.lua"
local plugin_code = [[
-- plugin test module (written by modular_ocvm_test)
return {
  name = "zz_hello",
  tools = {
    { type = "function", ["function"] = {
        name = "zz_hello",
        description = "plugin test tool",
        parameters = { type = "object", properties = {}, required = {} },
    }},
  },
  exec = function(name, args, deps)
    return "HELLO_PLUGIN_OK" .. (args and args.msg and (" " .. args.msg) or "")
  end,
}
]]
local pf = io.open(plugin_path, "w")
if pf then pf:write(plugin_code); pf:close() end
local pf2 = io.open(plugin_path, "r")
check("plugin module written", pf2 ~= nil, "write failed")
if pf2 then pf2:close() end

-- 模拟重启：清缓存后重新加载 tools 注册表（等价新进程扫描）
-- 先诊断 fs.list 扫描行为
local fs_diag = require("filesystem")
local ok_list, it_diag = pcall(fs_diag.list, base .. "/agent/tools")
log("DIAG fs.list ok=" .. tostring(ok_list) .. " type=" .. type(it_diag))
if ok_list and type(it_diag) == "function" then
  local n = 0
  for entry in it_diag do
    n = n + 1
    if n <= 10 then log("DIAG entry: " .. tostring(entry)) end
  end
  log("DIAG total entries: " .. n)
else
  log("DIAG fs.list failed: " .. tostring(it_diag))
end
-- 模拟真实重启：清掉所有 agent.* 模块缓存（新进程等价），重新加载
log("DIAG AGENT_DIR=" .. tostring(AGENT_DIR))
for k in pairs(package.loaded) do
  if type(k) == "string" and k:match("^agent[%.]") then package.loaded[k] = nil end
end
local ok_rescan, tools2 = pcall(require, "agent.tools")
check("rescan after plugin write", ok_rescan and type(tools2.list) == "function", tools2)
log("DIAG tools2.tools_dir=" .. tostring(ok_rescan and tools2.tools_dir))
local tools2_list = ok_rescan and tools2.list() or {}
check("TOOLS now 20", #tools2_list == 20, #tools2_list)
-- 诊断：显式传绝对路径扫描（若成功 → 证明 TOOLS_DIR 推导在 OpenOS 下失效）
if ok_rescan and #tools2_list ~= 20 then
  tools2.scan_dir(base .. "/agent/tools")
  local after_explicit = #tools2.list()
  log("DIAG explicit scan_dir count: " .. after_explicit)
  local tnames = {}
  for _, t in ipairs(tools2.list()) do
    tnames[#tnames + 1] = t["function"] and t["function"].name or "?"
  end
  log("DIAG tools: " .. table.concat(tnames, ","))
end

-- 调用新插件工具（execute 也需重新加载拿新 REGISTRY；deps 必须带 json）
local ok_exe, exe_mod = pcall(require, "agent.execute")
local plugin_result = nil
if ok_exe then
  plugin_result = exe_mod.run("zz_hello", '{"msg":"from_ocvm"}', { json = json_mod })
end
check("plugin tool callable", plugin_result == "HELLO_PLUGIN_OK from_ocvm", plugin_result)

-- 坏模块不阻塞：写入语法错误模块再扫描
local bad_path = base .. "/agent/tools/zz_bad.lua"
local bf = io.open(bad_path, "w")
if bf then bf:write("this is not valid lua !!!"); bf:close() end
for k in pairs(package.loaded) do
  if type(k) == "string" and k:match("^agent[%.]") then package.loaded[k] = nil end
end
local ok_rescan2, tools3 = pcall(require, "agent.tools")
local tools3_count = ok_rescan2 and #tools3.list() or -1
check("bad module skipped, count stays 20", ok_rescan2 and tools3_count == 20, tools3_count)
-- 清理坏模块（插件模块保留，验证持久性）
os.remove(bad_path)

log(string.format("FINAL: %d pass, %d fail", PASS, FAIL))
