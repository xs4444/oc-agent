-- ═══════════════════════════════════════════════════════════════
-- shell_timeout_test.lua — ocvm 真机 shell_execute 超时验证
--
-- 在真实 OpenOS 上验证 shell_execute 的超时保护：
--   1. 生成阻塞脚本（sleep 999，会 yield 的阻塞命令）
--   2. shell_execute 带 timeout 参数执行 → 应超时返回错误，不卡死
--   3. agent 恢复：后续工具调用正常
--   4. 正常命令仍可执行（对比组）
--   5. 记录超时耗时
--
-- ⚠️ 平台限制说明：纯 CPU 死循环（while true do end 永不 yield）在
-- OpenOS 协作式调度下会冻结整个机器（真实 OC 同样如此，需重启恢复），
-- 任何 Lua 层超时都无法中断它。本测试用 `sleep`（真实 yield 阻塞）验证
-- 可中断路径——这覆盖了 LLM 最常触发的危险场景（挂起命令）。
--
-- 用法: lua /mnt/<short>/shell_timeout_test.lua /mnt/<short>
-- 结果: 写入 /mnt/<short>/shell_timeout_test_result.txt
-- ═══════════════════════════════════════════════════════════════

local base = ({...})[1] or "/mnt"

local function log(...)
  print(...)
  local f = io.open(base .. "/shell_timeout_test_result.txt", "a")
  if f then f:write(table.concat({...}, " ") .. "\n"); f:close() end
end

io.open(base .. "/shell_timeout_test_result.txt", "w"):close()

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

-- ── 加载 agent（单文件形态，随 ocvm_test.py 上传到挂载根）────────
_TEST_MODE = true
local ok_load, load_err = pcall(dofile, base .. "/agent.lua")
check("load agent", ok_load, load_err)
check("agent_test hooks", ok_load and type(agent_test) == "table")
if not ok_load then
  log("RESULT: " .. PASS .. " pass, " .. FAIL .. " fail")
  return
end

-- shell_execute 工具直接经全局 execute_tool 调用（与主循环同路径）
local function shell(cmd, timeout)
  local ok, res = pcall(execute_tool, "shell_execute", require("agent.json").encode({command = cmd, timeout = timeout}))
  if ok then return res end
  return "Error: " .. tostring(res)
end

-- ── 1. 生成阻塞脚本（会 yield 的挂起命令，可被超时中断）─────────
local hang_path = base .. "/hang.lua"
local lf = io.open(hang_path, "w")
lf:write("os.sleep(999)\n")
lf:close()
local lf2 = io.open(hang_path, "r")
check("hang script written", lf2 ~= nil)
if lf2 then lf2:close() end

-- ── 2. 阻塞命令执行（timeout=3）──────────────────────────────────
-- 计时用 computer.uptime()（墙钟时间；os.clock 是 CPU 时间，sleep 期间不走）
local function uptime()
  local c = require("computer")
  return c.uptime()
end
local t0 = uptime()
local res_inf = shell("lua " .. hang_path, 3)
local elapsed = uptime() - t0
log("HANG command returned after " .. string.format("%.1f", elapsed) .. "s: " .. tostring(res_inf):sub(1, 120))
check("blocking command returns (not hung)", res_inf ~= nil)
check("returns timeout error message", type(res_inf) == "string" and res_inf:find("timeout") ~= nil, res_inf)
check("elapsed near timeout budget (2.5-8s)", elapsed >= 2.5 and elapsed <= 8, string.format("%.1f", elapsed))

-- ── 3. agent 恢复能力 ───────────────────────────────────────────
local res_calc = shell("echo calc-after-timeout", 5)
check("agent functional after timeout", type(res_calc) == "string" and res_calc ~= "", res_calc)

-- ── 4. 正常命令对照 ─────────────────────────────────────────────
-- 注：shell_execute 经 io.popen 捕获 stdout+stderr（不再只返回
-- true/false 退出状态），因此断言返回内容包含命令输出。
local t1 = uptime()
local res_ok = shell("echo hello-normal-command", 5)
local elapsed_ok = uptime() - t1
check("normal command returns quickly", type(res_ok) == "string" and res_ok:find("hello%-normal%-command") ~= nil and elapsed_ok < 5, tostring(res_ok) .. " (" .. string.format("%.1f", elapsed_ok) .. "s)")

-- ── 5. 无 timeout 参数默认值（快速命令不受影响）─────────────────
local res_def = shell("echo no-timeout-arg", nil)
check("default timeout path works", type(res_def) == "string" and res_def:find("no%-timeout%-arg") ~= nil, res_def)

-- 清理
os.remove(hang_path)

log("")
log("RESULT: " .. PASS .. " pass, " .. FAIL .. " fail")
