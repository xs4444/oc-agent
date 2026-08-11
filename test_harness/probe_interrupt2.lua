-- probe_interrupt2.lua — 决定性中断诊断：补丁内日志 + 短 timer
-- 用法: lua /mnt/<short>/probe_interrupt2.lua /mnt/<short> <api_key> <model> <api_url>
-- 目的: 上次探针（probe_interrupt）结论不决定性——注入点 23.4 在窗口内但
-- flag=false，无法区分 (a) 补丁 os.sleep 未被调用（迭代器窗口已过/不走补丁）
-- vs (b) 补丁被调用但事件未到达（pushSignal 队列问题）。
-- 本探针: 补丁 os.sleep 内部每次调用打印 (uptime, wait, 拉到的事件名)，
-- timer 1s 注入 interrupted。日志直接揭示补丁是否运行、事件是否被消费。
local base = ({...})[1] or "/mnt"
local api_key = ({...})[2] or "free"
local model = ({...})[3] or "deepseek-v4-flash-free"
local api_url = ({...})[4] or "https://opencode.ai/zen/v1/chat/completions"

local out = base .. "/probe_interrupt2_result.txt"
local f = io.open(out, "w")
local function log(s)
  if f then f:write(s .. "\n"); f:flush() end
  print(s)
end

package.path = base .. "/?.lua;" .. (package.path or "")
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

local ok_int, interrupt = pcall(require, "agent.interrupt")
if not ok_int then log("FATAL: no agent.interrupt: " .. tostring(interrupt)); return end

-- require 必须先于 os.sleep 包装（包装回调里用 computer.uptime()/event.pull）
local ok_e, event = pcall(require, "event")
local ok_c, computer = pcall(require, "computer")
if not (ok_e and ok_c) then log("FATAL: event/computer missing"); return end

-- 打日志的 os.sleep 包装: 记录每次补丁调用
local orig_sleep = os.sleep
os.sleep = function(t)
  local up = computer.uptime()
  local sig = {event.pull(t and math.min(0.1, t) or 0.1, "timer", "interrupted", "modem_message")}
  log(string.format("  [patch] sleep(%.2f) at uptime=%.1f got=%s", t or 0, up, tostring(sig[1])))
  if sig[1] == "interrupted" then
    log("  [patch] INTERRUPTED CAPTURED")
    interrupt.set()
  elseif sig[1] == "modem_message" then
    local h = interrupt.forward
    if h then pcall(h, sig) end
  end
end
log("instrumented os.sleep active (interrupt.install NOT called — direct wrap)")

-- 1s 后注入 interrupted（chat 思考期，迭代器循环窗口内）
local up0 = computer.uptime()
log("uptime start: " .. string.format("%.1f", up0))
local timer_id = event.timer(1, function()
  log("[timer] injecting interrupted at uptime=" .. string.format("%.1f", computer.uptime()))
  computer.pushSignal("interrupted")
end)
log("timer scheduled id=" .. tostring(timer_id) .. " (1s)")

local chat = agent_test.chat
local config = {api_key = api_key, model = model, api_url = api_url, context_window = 128000}
local messages = {{role = "user", content = "Reply with exactly: INTERRUPT_PROBE2_DONE. Take your time, be thorough."}}

log("calling chat...")
local up_before = computer.uptime()
local t0 = os.clock()
local resp = chat(messages, config)
local dt = os.clock() - t0
local up_after = computer.uptime()
log("chat returned after " .. string.format("%.1fs cpu", dt) .. " uptime window [" .. string.format("%.1f", up_before) .. "," .. string.format("%.1f", up_after) .. "]")
log("chat err=" .. tostring(resp and resp.error))
log("chat content=" .. tostring(resp and resp.content):sub(1, 50))
log("interrupt flag after: " .. tostring(interrupt.poll()))
log("RESULT: " .. (interrupt.poll() and "INTERRUPT_CAPTURED" or (resp and resp.error and tostring(resp.error):find("interrupted", 1, true) and "INTERRUPT_PATCH_WORKS" or "PATCH_NOT_TRIGGERED")))

event.cancel(timer_id)
if f then f:close() end
log("probe done")
