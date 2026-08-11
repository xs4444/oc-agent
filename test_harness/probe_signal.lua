-- probe_signal.lua — 验证 ocvm 上 pushSignal("interrupted") → event.pull 链路
-- 用法: lua /mnt/<short>/probe_signal.lua /mnt/<short>
-- 背景: probe_interrupt2 实证 1100 次 event.pull 拉不到 interrupted;
--       probe_interrupt3 挂起（os.clock 基准 bug）无法区分事件链路是否通。
-- 本 probe 绕过 os.sleep 补丁（用原版），直接 event.pull(3, "interrupted")
-- 阻塞等待 + timer 0.5s pushSignal("interrupted")——纯验证 pushSignal→pull。
-- 判定:
--   sig=interrupted → 链路通（挂起纯粹是 os.clock 基准 bug）
--   sig=nil (timeout) → pushSignal→pull 链路在 ocvm 有问题
local base = ({...})[1] or "/mnt"
local out = base .. "/probe_signal_result.txt"
local f = io.open(out, "w")
local function log(s)
  if f then f:write(s .. "\n"); f:flush() end
  print(s)
end

local ok_c, computer = pcall(require, "computer")
local ok_e, event = pcall(require, "event")
if not (ok_c and ok_e) then log("FATAL: computer/event missing"); return end

local up0 = computer.uptime()
log("uptime start: " .. string.format("%.1f", up0))

-- 0.5s 后 push interrupted
local timer_id = event.timer(0.5, function()
  log("[timer] pushing interrupted at uptime=" .. string.format("%.1f", computer.uptime()))
  computer.pushSignal("interrupted")
end)

-- 阻塞最多 3s 等 interrupted（原版 event.pull，不经 os.sleep 补丁）
log("calling event.pull(3, \"interrupted\")...")
local t0 = os.clock()
local sig = {event.pull(3, "interrupted")}
local dt = os.clock() - t0
log("pull returned: " .. tostring(sig[1]) .. " after " .. string.format("%.2f", dt) .. "s uptime=" .. string.format("%.1f", computer.uptime()))

if sig[1] == "interrupted" then
  log("RESULT: SIGNAL_LINK_WORKS — pushSignal→pull 链路正常")
else
  log("RESULT: SIGNAL_LINK_FAILED — pushSignal→pull 链路有问题（interrupted 不可达）")
end

event.cancel(timer_id)
if f then f:close() end
log("probe done")
