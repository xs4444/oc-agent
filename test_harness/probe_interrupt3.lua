-- probe_interrupt3.lua — 干净验证补丁 os.sleep + interrupted 事件链路
-- 用法: lua /mnt/<short>/probe_interrupt3.lua /mnt/<short>
-- 绕过 chat 复杂时序: 装补丁 → timer 0.5s push interrupted → os.sleep(2)
-- 应提前返回（~0.5s）且 flag=true。此测试直接验证 ocvm 上
-- pushSignal→event.pull 链路 + 补丁捕获能力。若通过, 说明 chat 里
-- 失败只是注入时序（响应太快/帧循环节流）; 若失败, 补丁/事件链路在
-- ocvm 真有问题, 需换方案。
local base = ({...})[1] or "/mnt"

local out = base .. "/probe_interrupt3_result.txt"
local f = io.open(out, "w")
local function log(s)
  if f then f:write(s .. "\n"); f:flush() end
  print(s)
end

package.path = base .. "/?.lua;" .. (package.path or "")
local ok_c, computer = pcall(require, "computer")
local ok_e, event = pcall(require, "event")
if not (ok_c and ok_e) then log("FATAL: computer/event missing"); return end

-- agent.interrupt 由 agent.lua 单文件构建在 package.preload 注册，
-- 必须先 dofile agent.lua（_TEST_MODE 跳过 main）才能 require。
_TEST_MODE = true
local agent_path = base .. "/agent.lua"
if not _G.fs or not _G.fs.exists then
  local fs_ok, fs_mod = pcall(require, "filesystem")
  if fs_ok and fs_mod and fs_mod.exists then
    if not fs_mod.exists(agent_path) then
      for item in fs_mod.list("/mnt") do
        local full = "/mnt/" .. item
        if fs_mod.exists(full .. "/agent.lua") then agent_path = full .. "/agent.lua" break end
      end
    end
  end
end
local ok_load, load_err = pcall(dofile, agent_path)
if not ok_load then log("FATAL: agent.lua load: " .. tostring(load_err)); return end
log("agent.lua loaded from " .. agent_path)

-- 装真实补丁（agent.interrupt.install——不包装, 用产品代码）
local ok_int, interrupt = pcall(require, "agent.interrupt")
if not ok_int then log("FATAL: no agent.interrupt: " .. tostring(interrupt)); return end
interrupt.install()
log("patch installed: os.sleep replaced=" .. tostring(os.sleep ~= nil) .. " installed=" .. tostring(interrupt.installed))

-- 1) timer 0.5s push interrupted
local up0 = computer.uptime()
log("uptime start: " .. string.format("%.1f", up0))
local timer_id = event.timer(0.5, function()
  log("[timer] pushing interrupted at uptime=" .. string.format("%.1f", computer.uptime()))
  computer.pushSignal("interrupted")
end)

-- 2) os.sleep(2) 应提前返回
log("calling os.sleep(2)...")
local t0 = os.clock()
os.sleep(2)
local dt = os.clock() - t0
log("os.sleep(2) returned after " .. string.format("%.2f", dt) .. "s cpu (expected ~0.5s if interrupt works)")
log("interrupt flag: " .. tostring(interrupt.poll()))

-- 3) 判定
if interrupt.poll() and dt < 1.5 then
  log("RESULT: PATCH_AND_EVENT_LINK_WORKS — os.sleep early-returned, flag set")
elseif interrupt.poll() then
  log("RESULT: FLAG_SET_BUT_SLEEP_FULL — flag set but sleep waited full duration (dispatch gap)")
else
  log("RESULT: LINK_FAILED — no flag, sleep full duration (pushSignal→pull link broken or patch never pulled)")
end

event.cancel(timer_id)
interrupt.clear()
if f then f:close() end
log("probe done")
