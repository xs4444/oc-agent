-- selftest_test.lua — 本地 smoke 验证 selftest 框架（真实自检在实机跑）
-- 运行: lua test_harness/selftest_test.lua
-- 预期（mock 环境）:
--   env/json/fs/session/config/tools/mem → PASS（mock 覆盖的模块逻辑）
--   net → FAIL（mock internet 无法处理 api.github.com/zen——真实网络
--         只在实机验证; FAIL 且快速返回即正确行为）
--   interrupt → FAIL（mock event.timer 不触发回调——真实事件时序只在
--         实机验证; 测试等满 2s 返回即正确行为，不挂起）
-- 本文件验证: 框架能跑完、结果格式对、无崩溃挂起。
-- 实机 /selftest 的 PASS/FAIL 才是真机行为的最终裁决。
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

-- 加载被测模块（模拟 init.lua 的 require 路径）
local agent_path = arg and arg[1] or "../src/agent/init.lua"
local ok, err = pcall(dofile, agent_path)
if not ok then print("AGENT LOAD FAILED: " .. tostring(err)); os.exit(1) end

local selftest = require("agent.selftest")
print("running selftest.run()...")
local t0 = os.clock()
local report = selftest.run()
print("selftest.run() returned after " .. string.format("%.1fs", os.clock() - t0))
print("──────────────────────────────")
print(report)
print("──────────────────────────────")
-- 断言: 报告含 RESULT 行 + 9 项
local n_pass = report:match("RESULT: (%d+)/9 pass")
local has_result = report:find("RESULT:", 1, true) ~= nil
print("has RESULT line: " .. tostring(has_result))
if has_result then
  print("pass count: " .. tostring(n_pass))
  print("(mock 预期: 6-7 pass — net/interrupt 应 FAIL 且快速返回)")
end
if not has_result then
  print("SMOKE FAIL: no RESULT line")
  os.exit(1)
end
print("SMOKE OK: framework ran, RESULT line present")
