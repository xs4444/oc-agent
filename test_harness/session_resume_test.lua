-- ════════════════════════════════════════════════════════════════
-- session 回归测试（v0.3.126）
--
-- ① sessions_dir 模块默认值（回归: 曾是全局自由变量——启动时无人
--    初始化 → get_sessions_dir()=nil → /resume fs.list(nil) 报错被
--    pcall 吞掉 → "No resumable sessions" 空列表，真机 2026-09-07 实证）
-- ② archive.jsonl 冷存储封顶（防 /home 写满 → writable base 漂到 /tmp
--    tmpfs → 重启历史丢失；行对齐截断保首行完整 JSON）
--
-- 独立文件原因: run_tests.lua 主 chunk 局部变量贴近 200 上限——内联
-- IIFE 触发 Lua 5.3 编译器寄存器分配敏感布局（/resume IIFE 的
-- CLOSURE 寄存器被冲掉 → "attempt to call a nil value"）。同
-- tui_mouse_render_test.lua 模式: dofile 接入, 零主 chunk 布局扰动。
--
-- 运行:
--   独立:  cd test_harness && lua5.3 session_resume_test.lua
--   接入:  run_tests.lua 设置 _IN_RUN_TESTS=true 后 dofile，
--          本文件跳过 os.exit 并 return pass, fail 由宿主累加。
-- ════════════════════════════════════════════════════════════════

io.stdout:setvbuf("no")

-- 环境搭建（幂等: 被 run_tests dofile 时 oc_mock 已加载、agent 已加载）
if not package.loaded["oc_mock"] then
  package.path = "./?.lua;" .. package.path
end
if not os.sleep then os.sleep = function() end end
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
if not package.loaded["agent.session"] then
  package.path = "../src/?.lua;" .. package.path
  pcall(dofile, "../src/agent/init.lua")
end
local ok_sess, sess_mod = pcall(require, "agent.session")
if not ok_sess or type(sess_mod) ~= "table" then
  print("FAIL session_resume_test: agent.session load failed: " .. tostring(ok_sess))
  os.exit(1)
end
local json = require("agent.json")

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

-- ① fresh require: sessions_dir 默认 = config 值（不依赖 set_sessions_dir）
do
  local saved_mod = package.loaded["agent.session"]
  package.loaded["agent.session"] = nil
  local fresh = require("agent.session")
  package.loaded["agent.session"] = saved_mod
  local ok_cfg, cfg_mod = pcall(require, "agent.config")
  test("session: sessions_dir 默认 = config 值（回归: 未初始化全局）",
    ok_cfg and fresh.get_sessions_dir() == cfg_mod.sessions_dir,
    "got=" .. tostring(fresh.get_sessions_dir())
    .. " want=" .. tostring(ok_cfg and cfg_mod.sessions_dir))
end

-- ② cap_archive: 超 cap 截断至后半（行对齐）
do
  local hook = sess_mod._internal
  test("session: _internal 测试钩子（_TEST_MODE）",
    type(hook) == "table" and type(hook.cap_archive) == "function",
    tostring(type(hook)))
  if type(hook) == "table" and type(hook.cap_archive) == "function" then
    local saved_path = sess_mod.current_path()
    local cap_hist = "test_cap_hist.txt"
    local cap_arch = cap_hist .. ".archive.jsonl"
    sess_mod.set_paths(cap_hist)
    local line = json.encode({role = "user", content = string.rep("x", 500)})
    local f = io.open(cap_arch, "w")
    for i = 1, 2100 do f:write(line, "\n") end
    f:close()
    local fs0 = io.open(cap_arch, "r")
    local size0 = fs0:seek("end") or 0
    fs0:close()
    hook.cap_archive()
    local f2 = io.open(cap_arch, "r")
    local size1 = f2:seek("end") or 0
    f2:seek("set", 0)  -- seek("end") 后读必空——回开头再读首行
    local first = f2:read("*l") or ""
    f2:close()
    local ok_j = pcall(json.decode, first)
    test("cap_archive: 超限截断（size 减半）",
      size0 > 1000000 and size1 < size0 / 2 + 600,
      "size0=" .. tostring(size0) .. " size1=" .. tostring(size1))
    test("cap_archive: 首行完整 JSON（行对齐）", ok_j and first:sub(1, 1) == "{",
      "first=" .. first:sub(1, 30))
    -- 未超限不截断
    local f3 = io.open(cap_arch, "w")
    f3:write(line, "\n")
    f3:close()
    hook.cap_archive()
    local f4 = io.open(cap_arch, "r")
    local size2 = f4:seek("end") or 0
    f4:close()
    test("cap_archive: 未超限不截断", size2 >= #line,
      "size2=" .. tostring(size2))
    os.remove(cap_arch)
    os.remove(cap_hist)
    sess_mod.set_paths(saved_path)
  end
end

-- ════════════════════════════════════════════════════════════════
print(string.format("RESULT: %d pass, %d fail", pass, fail))
if not _IN_RUN_TESTS then
  os.exit(fail > 0 and 1 or 0)
end
return pass, fail
