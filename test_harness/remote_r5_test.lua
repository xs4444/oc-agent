-- ═══════════════════════════════════════════════════════════════
-- remote_r5_test.lua — v0.3.125r5 远控扩展单测（op=lua + 大结果分页）
--
-- 独立文件原因: run_tests.lua 主函数已贴近 Lua 5.x 的 200 局部变量
-- 上限，新测试组拆到本文件（独立 main 函数 = 独立预算）。
--
-- 覆盖:
--   op=lua : 无 code 拒绝 / return 值 / 运行错误 / 语法错误 / 无返回值
--   分页   : >64KB 进缓存 / fetch 首块/续块/越界 / 单槽替换 / TTL 过期
--            / >256KB held 封顶 / 小结果不进缓存
--
-- 运行（test_harness/ 目录内）:
--   lua5.3 remote_r5_test.lua
-- ═══════════════════════════════════════════════════════════════

package.path = "./?.lua;" .. (package.path or "")
package.path = "../src/?.lua;" .. package.path

if not os.sleep then os.sleep = function() end end

local oc_mock = require("oc_mock")
package.loaded["component"] = oc_mock.component
package.loaded["computer"] = oc_mock.computer
package.loaded["filesystem"] = oc_mock.filesystem
package.loaded["shell"] = oc_mock.shell
package.loaded["internet"] = oc_mock.internet
package.loaded["serialization"] = oc_mock.serialization
package.loaded["event"] = oc_mock.event
package.loaded["thread"] = oc_mock.thread

_TEST_MODE = true

local pass, fail = 0, 0
local function test(label, cond, detail)
  if cond then
    pass = pass + 1
    print("  PASS  " .. label)
  else
    fail = fail + 1
    print("  FAIL  " .. label .. (detail and (" — " .. tostring(detail)) or ""))
  end
end

local ok_mod, remote = pcall(require, "agent.remote")
test("module loads", ok_mod and type(remote) == "table", tostring(remote))
if ok_mod then
  local int = remote._internal
  test("_internal exposed under _TEST_MODE",
    type(int) == "table" and type(int.execute_op) == "function"
      and type(int.report) == "function" and type(int.set_url_token) == "function",
    "missing hooks")
  if int then
    -- ── op=lua（服务器下发 Lua 脚本，借鉴 RemoteOC 裸 Lua 模式）──
    local s, e = int.execute_op({op = "lua"})
    test("lua op: 无 code 拒绝", e == true and tostring(s):find("args.code") ~= nil, tostring(s))
    s, e = int.execute_op({op = "lua", args = {code = "return 6*7"}})
    test("lua op: return 值即结果", e == false and s == "42", tostring(s))
    s, e = int.execute_op({op = "lua", args = {code = 'error("boom")'}})
    test("lua op: 运行错误 is_err", e == true and tostring(s):find("boom") ~= nil, tostring(s))
    s, e = int.execute_op({op = "lua", args = {code = "local x ="}})
    test("lua op: 语法错误 is_err", e == true and tostring(s):find("load failed") ~= nil, tostring(s))
    s, e = int.execute_op({op = "lua", args = {code = "print(1)"}})
    test("lua op: 无返回值占位", e == false and s == "(no return value)", tostring(s))

    -- ── 大结果分页（report >64KB → 缓存 256KB + fetch 按 offset 续取）──
    -- mock internet 只对 chat/completions 类 URL 应答 → report "成功"
    -- 不进 pending 队列
    int.set_url_token("http://mock/chat/completions", "t")
    local st = int._state
    local big = string.rep("A", 70000)
    int.report("rtest1", big, false)
    local rc = st.result_cache
    test("paged: >64KB 进缓存（rid/total/held）",
      rc ~= nil and type(rc.rid) == "string"
        and rc.total == 70000 and rc.held == 70000 and #rc.text == 70000,
      tostring(rc and rc.total))
    if rc then
      local f1, fe1 = int.execute_op({op = "fetch", args = {rid = rc.rid, offset = 0}})
      test("paged: fetch offset 0 = 首块 64KB",
        fe1 == false and f1 == big:sub(1, 65536), tostring(#tostring(f1)))
      local f2, fe2 = int.execute_op({op = "fetch", args = {rid = rc.rid, offset = 65536}})
      test("paged: fetch 续块 = 余 4464",
        fe2 == false and f2 == big:sub(65537), tostring(#tostring(f2)))
      local f3, fe3 = int.execute_op({op = "fetch", args = {rid = rc.rid, offset = 70000}})
      test("paged: offset == held 拒绝",
        fe3 == true and tostring(f3):find("out of range") ~= nil, tostring(f3))
      -- 单槽替换: 新大结果顶掉旧的
      int.report("rtest2", string.rep("B", 70000), false)
      local rc2 = st.result_cache
      test("paged: 单槽替换 rid 递增",
        rc2 ~= nil and rc2.rid ~= rc.rid, tostring(rc2 and rc2.rid))
      local f4, fe4 = int.execute_op({op = "fetch", args = {rid = rc.rid, offset = 0}})
      test("paged: 旧 rid → unknown or replaced",
        fe4 == true and tostring(f4):find("unknown or replaced") ~= nil, tostring(f4))
      -- TTL 过期 → 清槽
      rc2.ts = -1000000000
      local f5, fe5 = int.execute_op({op = "fetch", args = {rid = rc2.rid, offset = 0}})
      test("paged: 过期 → 清槽并报 expired",
        fe5 == true and tostring(f5):find("expired") ~= nil and st.result_cache == nil,
        tostring(f5))
    end
    -- 超 256KB → held 封顶（4MB 机内存安全优先）
    int.report("rtest3", string.rep("C", 300000), false)
    local rc3 = st.result_cache
    test("paged: >256KB held 封顶 262144",
      rc3 ~= nil and rc3.held == 262144 and rc3.total == 300000 and #rc3.text == 262144,
      tostring(rc3 and rc3.held))
    -- 小结果不进缓存
    st.result_cache = nil
    int.report("rtest4", "small", false)
    test("paged: 小结果不进缓存", st.result_cache == nil, "cache touched")
  end
end

print(string.format("═══════════════════════════════════════"))
print(string.format("REMOTE R5: %d pass, %d fail out of %d tests",
  pass, fail, pass + fail))
print(string.format("═══════════════════════════════════════"))
os.exit(fail == 0 and 0 or 1)
