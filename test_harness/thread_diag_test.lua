-- ═══════════════════════════════════════════════════════════════
-- thread_diag_test.lua — ocvm 上 thread 库超时诊断
--
-- 目的：确认 shell_timeout_test 挂死的根因
--   1. require("thread") 是否可用
--   2. thread.create + waitForAll 超时是否生效
--   3. 死循环线程超时后 kill 是否返回
--
-- 用法: lua /mnt/<short>/thread_diag_test.lua /mnt/<short>
-- 结果: 写入 /mnt/<short>/thread_diag_test_result.txt
-- ═══════════════════════════════════════════════════════════════

local base = ({...})[1] or "/mnt"

local function log(...)
  print(...)
  local f = io.open(base .. "/thread_diag_test_result.txt", "a")
  if f then f:write(table.concat({...}, " ") .. "\n"); f:close() end
end

io.open(base .. "/thread_diag_test_result.txt", "w"):close()
log("thread_diag start, uptime=" .. tostring(computer and computer.uptime and computer.uptime()))

-- 1. thread 库可用性
local ok_thread, thread = pcall(require, "thread")
log("require thread: " .. tostring(ok_thread) .. (ok_thread and "" or (" -- " .. tostring(thread))))
if not ok_thread then
  log("RESULT: thread lib unavailable, fallback direct execute is expected")
  return
end

-- 2. 正常线程：sleep 0.5 后结束
log("--- test normal thread ---")
local t_normal = thread.create(function()
  os.sleep(0.5)
  return 42
end)
local wok, werr = thread.waitForAll({t_normal}, 5)
log("waitForAll normal: " .. tostring(wok) .. " / " .. tostring(werr) .. ", status=" .. t_normal:status())

-- 3. 死循环线程 + 超时：waitForAll(2) 应约 2 秒返回
log("--- test spin thread timeout ---")
local t_spin = thread.create(function()
  while true do end
end)
local t0 = os.clock()
local sok, serr = thread.waitForAll({t_spin}, 2)
local elapsed = os.clock() - t0
log("waitForAll spin(2s): ok=" .. tostring(sok) .. " err=" .. tostring(serr) .. " elapsed=" .. string.format("%.2f", elapsed) .. " status=" .. t_spin:status())
-- 超时后 kill
local kok, kerr = pcall(t_spin.kill, t_spin)
log("kill spin thread: " .. tostring(kok) .. " / " .. tostring(kerr) .. ", status after=" .. t_spin:status())

-- 4. agent 主循环恢复能力：超时后还能跑
os.sleep(0.2)
log("still alive after spin timeout, uptime=" .. tostring(computer.uptime()))

-- 5. 通过 shell.execute 执行死循环脚本（模拟 agent 的真实调用路径）
log("--- test shell.execute in thread ---")
local loop_path = base .. "/loop_diag.lua"
local lf = io.open(loop_path, "w")
lf:write("while true do end\n")
lf:close()
local sh = require("shell")
local t_sh = thread.create(function()
  return sh.execute("lua " .. loop_path)
end)
local t1 = os.clock()
local hok, herr = thread.waitForAll({t_sh}, 2)
local elapsed2 = os.clock() - t1
log("waitForAll shell-loop(2s): ok=" .. tostring(hok) .. " err=" .. tostring(herr) .. " elapsed=" .. string.format("%.2f", elapsed2) .. " status=" .. t_sh:status())
local kok2, kerr2 = pcall(t_sh.kill, t_sh)
log("kill shell thread: " .. tostring(kok2) .. " / " .. tostring(kerr2) .. ", status after=" .. t_sh:status())
os.sleep(0.2)
log("alive after shell timeout, uptime=" .. tostring(computer.uptime()))
os.remove(loop_path)

log("")
log("RESULT: done")
