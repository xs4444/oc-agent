-- ════════════════════════════════════════════════════════════════
-- 单文件产物（agent.lua）让出闸门接线测试（v0.3.127）
--
-- 为什么必须独立进程跑: 本测试要验证**单文件构建的 package.preload 路径**
-- ——init.lua 的模块级 `local ok_pm, patch_mod = pcall(require,"agent.patch")`
-- 是否真的绑到闸门表上。在 run_tests.lua 里 dofile 会复用已被 src 路径
-- require 过的 package.loaded，preload 表根本不会被走到 → 测了个寂寞。
--
-- 防的是本项目「隐形 nil」坑: 写成裸自由变量 → 静默变 nil →
-- `if patch_mod and patch_mod.yield_gate then` 守卫把闸门整个跳过，
-- 且**没有任何报错**（真机 /resume 照样崩，还查不出原因）。
--
-- 运行（独立进程，cwd = test_harness）:
--   LUA_PATH="./?.lua;;" lua5.3 build_artifact_gate_test.lua
-- ════════════════════════════════════════════════════════════════

io.stdout:setvbuf("no")
package.path = "./?.lua;" .. package.path

local oc_mock = require("oc_mock")
component = oc_mock.component
computer = oc_mock.computer
filesystem = oc_mock.filesystem
shell = oc_mock.shell
internet = oc_mock.internet
serialization = oc_mock.serialization
event = oc_mock.event
keyboard = oc_mock.keyboard
for k, v in pairs(oc_mock) do
  if type(v) == "table" then package.loaded[k] = v end
end
_TEST_MODE = true

local pass, fail = 0, 0
local function test(name, cond, detail)
  if cond then
    pass = pass + 1
    print("PASS " .. name)
  else
    fail = fail + 1
    print("FAIL " .. name .. (detail and (" -- " .. tostring(detail)) or ""))
  end
end

-- 单文件产物（preload 路径）
local ok_build, err_build = pcall(dofile, "../agent.lua")
test("单文件产物可加载（_TEST_MODE）", ok_build, tostring(err_build))

local patch = require("agent.patch")
test("agent.patch 经 preload 可见且带闸门",
  type(patch) == "table" and type(patch.yield_gate) == "function",
  "yield_gate=" .. type(patch and patch.yield_gate))

local agent_test = _G.agent_test
test("_TEST_MODE 测试钩子可见", type(agent_test) == "table",
  tostring(type(agent_test)))

if type(agent_test) == "table" and agent_test.handle_command then
  local sess_mod = require("agent.session")
  local cfg_mod = require("agent.config")
  local ok_cfg, cfg = pcall(cfg_mod.load)
  if not ok_cfg or type(cfg) ~= "table" then cfg = cfg_mod end

  local TMPDIR = "test_bag_tmp"
  os.execute("mkdir -p " .. TMPDIR)
  local BIG = TMPDIR .. "/sess.jsonl"
  do
    local f = assert(io.open(BIG, "w"))
    for i = 1, 300 do
      local role = (i % 4 == 0) and "user" or ((i % 4 == 1) and "assistant" or "tool")
      f:write(require("agent.json").encode(
        {role = role, content = string.rep("z", 120 + (i % 50))}), "\n")
    end
    f:close()
  end

  local saved_sdir = sess_mod.get_sessions_dir()
  local saved_path = sess_mod.current_path()
  sess_mod.set_sessions_dir(TMPDIR)
  agent_test.set_history_path(TMPDIR .. "/main.jsonl")

  -- 计数桩: 只要 init.lua 的 patch_mod 绑对了，picker/load_history 的
  -- 逐行循环就会打到这里
  local calls = 0
  local orig = patch.yield_gate
  patch.yield_gate = function() calls = calls + 1 end
  local ok_r, e_r, _c, m_r = pcall(agent_test.handle_command,
    "/resume sess", cfg, {})
  local gate_after_resume = calls
  calls = 0
  local ok_l, e_l = pcall(agent_test.load_history)
  local gate_after_load = calls
  patch.yield_gate = orig

  test("单文件产物: /resume picker 逐行循环调用闸门（接线正确）",
    ok_r and gate_after_resume > 0,
    "ok=" .. tostring(ok_r) .. " err=" .. tostring(e_r)
      .. " calls=" .. tostring(gate_after_resume))
  test("单文件产物: load_history 逐行循环调用闸门（接线正确）",
    ok_l and gate_after_load > 0,
    "ok=" .. tostring(ok_l) .. " err=" .. tostring(e_l)
      .. " calls=" .. tostring(gate_after_load))
  test("单文件产物: /resume 恢复出消息表",
    type(m_r) == "table" and #m_r > 0, "msgs=" .. tostring(type(m_r) == "table" and #m_r or -1))

  sess_mod.set_sessions_dir(saved_sdir)
  agent_test.set_history_path(saved_path or BIG)
  os.execute("rm -rf " .. TMPDIR)
end

print(string.format("RESULT: %d pass, %d fail", pass, fail))
os.exit(fail > 0 and 1 or 0)
