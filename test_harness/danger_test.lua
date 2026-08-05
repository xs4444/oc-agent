-- ═══════════════════════════════════════════════════════════════
-- danger_test.lua — 高危场景鲁棒性测试（本地 mock 安全模拟）
--
-- 覆盖 7 个高危场景，全部在隔离临时目录 danger_tmp/ 中进行，
-- 不触碰真实仓库文件：
--   1. self-modify  : 写"已部署的 agent.lua 副本"（修改自身文件）
--   2. bad plugin   : 写语法错误的 .lua 到 tools/ 目录
--   3. infinite loop: 生成死循环脚本（mock shell 限时执行）
--   4. disk full    : 大文件写入 + 不可写路径错误注入
--   5. config bad   : 覆盖 agent_config.txt 为无效内容
--   6. delete self  : 删除 agent.lua 文件本身
--   7. recursion    : 工具递归调用链 + subagent 自调用
--
-- 运行（test_harness/ 目录内）:
--   ../lua_portable/bin/lua.exe -e "package.path = './?.lua;' .. (package.path or '')" danger_test.lua
-- ═══════════════════════════════════════════════════════════════

package.path = "./?.lua;" .. (package.path or "")
package.path = "../src/?.lua;" .. package.path

if not os.sleep then os.sleep = function() end end

-- mock 环境注入（同 plugin_test.lua 模式）
local oc_mock = require("oc_mock")
package.loaded["component"] = oc_mock.component
package.loaded["computer"] = oc_mock.computer
package.loaded["filesystem"] = oc_mock.filesystem
package.loaded["shell"] = oc_mock.shell
package.loaded["internet"] = oc_mock.internet
package.loaded["serialization"] = oc_mock.serialization
package.loaded["event"] = oc_mock.event

_TEST_MODE = true

local pass, fail = 0, 0
local function test(label, cond, detail)
  if cond then
    pass = pass + 1
    print("  PASS  " .. label)
  else
    fail = fail + 1
    print("  FAIL  " .. label .. (detail and ("  -- " .. tostring(detail)) or ""))
  end
end

-- 隔离临时目录
local tmp = "danger_tmp"
os.execute("rmdir /s /q " .. tmp .. " 2>nul")
os.execute("mkdir " .. tmp)
os.execute("mkdir " .. tmp .. "\\agent\\tools")

-- 让 require("agent.tools.xxx") 能解析到临时目录（插件扫描测试）
package.path = tmp .. "/?.lua;" .. package.path

-- ══ 部署副本：把 src/agent 模块树复制到临时目录 ══
-- （场景 1/6 的目标文件用这份副本，绝不触碰真实 agent.lua）
local deployed_root = tmp .. "/agent"
local function copy_tree(src_dir, dst_dir)
  local handle = io.popen('cmd /c dir /b "' .. src_dir .. '" 2>nul')
  if not handle then return end
  for line in handle:lines() do
    if line ~= "" then
      local s = src_dir .. "/" .. line
      local d = dst_dir .. "\\" .. line
      local fi = io.open(s, "rb")
      if fi then
        local content = fi:read("*a")
        fi:close()
        if content then
          local fo = io.open(d, "wb")
          fo:write(content)
          fo:close()
        end
      end
    end
  end
  handle:close()
end
copy_tree("../src/agent", deployed_root)
copy_tree("../src/agent/tools", deployed_root .. "\\tools")

-- 加载 agent 入口（src 版，_TEST_MODE 跳过 main()）
local ok_load, load_err = pcall(dofile, "../src/agent/init.lua")
test("agent loads", ok_load, tostring(load_err))
if not ok_load then os.exit(1) end

local execute = require("agent.execute")
local json = require("agent.json")
local config_mod = require("agent.config")
local tools_mod = require("agent.tools")

-- 用 init.lua 的全局 execute_tool（带 DEPS 注入：subagent 端口、超时等）
local function run_tool(name, args)
  return execute_tool(name, json.encode(args or {}))
end

print("\n=== 1. Self-modification: write to agent.lua ===")
local deployed = deployed_root .. "/agent.lua"
-- 场景目标：修改"已部署的 agent.lua"（副本）
local r = run_tool("write_file", {path = deployed, content = "-- modified agent.lua by write_file tool\n"})
print("  tool returned: " .. tostring(r))
local after = io.open(deployed, "r")
local content = after and after:read("*a")
if after then after:close() end
test("deployed agent.lua content was overwritten", content == "-- modified agent.lua by write_file tool\n", "got: " .. tostring(#(content or "")) .. " bytes")
local r2 = run_tool("json_query", {json = '{"a":1}', path = "a"})
test("agent still functional after self-modify", type(r2) == "string" and r2 == "1", r2)

print("\n=== 2. Bad plugin module in tools/ ===")
local bad_plugin = deployed_root .. "/tools/bad_plugin.lua"
local r = run_tool("write_file", {path = bad_plugin, content = "this is not valid lua @#$%^&*\nreturn {}\n"})
print("  tool returned: " .. tostring(r))
local fs = require("filesystem")
local names = {}
for f in fs.list(deployed_root .. "/tools") do
  names[#names + 1] = f
end
local ok_scan = pcall(tools_mod.scan_dir, deployed_root .. "/tools", names)
test("scan_dir survives bad plugin file", ok_scan)
local bad_decl = nil
for _, t in ipairs(tools_mod.list()) do
  local f = t["function"]
  if f and f.name == "bad_plugin" then bad_decl = t end
end
test("bad plugin not registered", bad_decl == nil)

print("\n=== 3. Infinite loop script ===")
local loop_file = tmp .. "/loop.lua"
local r = run_tool("write_file", {path = loop_file, content = "while true do end\n"})
print("  tool returned: " .. tostring(r))
test("loop script created", io.open(loop_file, "r") ~= nil)
-- 语法验证（只编译不执行）
local chk = loadfile(loop_file)
test("loop script is valid Lua (compiles)", chk ~= nil, tostring(chk))
-- 执行：mock shell 替换为限时版（真实死循环在 mock 中会永久挂起，
-- 替换为"超时返回"模拟 OC 中命令卡死的恢复路径）
local orig_execute = oc_mock.shell.execute
oc_mock.shell.execute = function(cmd)
  -- 模拟执行死循环：永不返回 → 这里模拟系统超时踢出
  return false, "timeout: command exceeded 2s budget"
end
local r3 = run_tool("shell_execute", {command = "lua " .. loop_file})
oc_mock.shell.execute = orig_execute
print("  (mock-limited) tool returned: " .. tostring(r3))
-- shell_execute 把 shell.execute 的第一返回值 tostring 返回（false），
-- 关键断言：命令卡死/超时后 agent 不崩溃、返回字符串结果
test("agent survives infinite-loop command (no crash)", type(r3) == "string", r3)
local r4 = run_tool("calc", {expression = "2+2"})
test("agent functional after loop command", r4 == "4", r4)

print("\n=== 4. Disk space exhaustion ===")
-- 4a. 大文件写入（200MB 流式）：agent 不应 OOM/崩溃
local big = string.rep("x", 1024 * 1024)
local big_file = tmp .. "/big.bin"
local ok_big, big_err = pcall(function()
  local f = io.open(big_file, "w")
  for i = 1, 200 do f:write(big) end
  f:close()
end)
test("large file write succeeds without crash", ok_big, big_err)
-- 4b. 不可写路径（错误注入路径）：写失败返回 Error 而非崩溃
local r5 = run_tool("write_file", {path = tmp .. "\\no_such_dir\\file.txt", content = "x"})
print("  write to missing dir returned: " .. tostring(r5))
test("write to unwritable path returns error, not crash", r5:find("Error") ~= nil, r5)
-- 4c. 配额注入：mock filesystem.open 对超限文件返回 not enough space
local mock_fs_open = oc_mock.filesystem.open
oc_mock.filesystem.open = function(path, mode)
  if mode == "w" and oc_mock.filesystem.size(path) and oc_mock.filesystem.size(path) > 1024 * 1024 then
    return nil, "not enough space"
  end
  return mock_fs_open(path, mode)
end
local r6 = run_tool("append_file", {path = tmp .. "/quota.txt", content = "x"})
oc_mock.filesystem.open = mock_fs_open
test("append_file works after quota mock (no crash)", r6:find("Error") == nil, r6)
-- 清理
os.remove(big_file)
os.remove(tmp .. "/quota.txt")

print("\n=== 5. Config corruption ===")
-- 写 config_mod 实际使用的路径（mock 下 writable_base 探测结果）
local cfg_path = config_mod.config_path
local wf = io.open(cfg_path, "w")
wf:write("this is not a valid serialized table {{{")
wf:close()
local cfg = config_mod.load()
test("config.load returns nil on corrupt config (no crash)", cfg == nil, tostring(cfg))
local ser = require("serialization")
local wf3 = io.open(cfg_path, "w")
wf3:write(ser.serialize({api_key = "k", model = "m", api_url = "u"}))
wf3:close()
local cfg2 = config_mod.load()
test("config recovers after valid rewrite", type(cfg2) == "table" and cfg2.model == "m", tostring(cfg2 and cfg2.model))

print("\n=== 6. Delete self (agent.lua) ===")
local ok_del = os.remove(deployed)
test("deployed agent.lua file deleted", ok_del or not io.open(deployed, "r"))
local r7 = run_tool("calc", {expression = "6*7"})
test("agent still functional after deleting its own file", r7 == "42", r7)
local r8 = run_tool("text_ops", {text = "hello world", op = "upper"})
print("  text_ops returned: " .. tostring(r8))
test("text_ops works after self-delete", r8 ~= nil and r8:find("HELLO") ~= nil, r8)

print("\n=== 7. Recursive tool calls ===")
-- 7a. 插件工具递归：chain 插件通过 execute.run 自调用
local chain_plugin = deployed_root .. "/tools/chain.lua"
local chain_code = [[
-- chain plugin: recursively calls itself via execute.run
local json = require("agent.json")
local tools = { {type="function", ["function"]={
  name="chain_recursive",
  description="recursive tool call test",
  parameters={type="object", properties={depth={type="number"}}, required={"depth"}}
}} }
local function exec(name, args, deps)
  if name == "chain_recursive" then
    local d = tonumber(args.depth) or 0
    if d <= 0 then return "chain-bottom" end
    local execute = require("agent.execute")
    local r = execute.run("chain_recursive", json.encode({depth = d - 1}), {json = json})
    return "chain(" .. d .. ")->" .. tostring(r)
  end
  return nil
end
return {tools = tools, exec = exec}
]]
local cf = io.open(chain_plugin, "w")
cf:write(chain_code)
cf:close()
package.loaded["agent.tools.chain"] = nil
local ok_chain_scan = pcall(tools_mod.scan_dir, deployed_root .. "/tools", {"chain.lua"})
test("chain plugin registers", ok_chain_scan)
local ok_rec, rec_res = pcall(function()
  return run_tool("chain_recursive", {depth = 100})
end)
print("  recursion result: " .. tostring(rec_res))
test("deep recursion (100) completes or errors gracefully", ok_rec, rec_res)
local r9 = run_tool("calc", {expression = "1+1"})
test("agent functional after recursion", r9 == "2", r9)

-- 7b. 子代理自调用（modem 环路 → 超时）：用 mock modem 地址但无对端
local r10 = run_tool("subagent_call", {address = "11aa22bb-3344-5566-7788-99aabbccddee", task = "ping", timeout = 0.1})
print("  subagent self-call returned: " .. tostring(r10))
test("subagent_call to self times out gracefully", type(r10) == "string" and r10:find("timeout") ~= nil, r10)

-- 清理
os.execute("rmdir /s /q " .. tmp .. " 2>nul")

print("\n======================================")
print(string.format("DANGER TESTS: %d pass, %d fail out of %d", pass, fail, pass + fail))
print("======================================")
if fail > 0 then os.exit(1) end
