-- probe_clock.lua — 决定性验证 os.clock() 在 ocvm 的语义
-- 用法: lua /mnt/<short>/probe_clock.lua /mnt/<short>
-- 背景: agent.interrupt 补丁 os.sleep 用 os.clock() 做超时基准
--   (deadline = os.clock()+t)。若 os.clock() 是 CPU 时间（空闲几乎不走),
--   os.sleep(t>0) 永不超时 → while true 死循环挂起。
-- 验证: (1) 原版 os.sleep(2) 前后 uptime 与 clock 增量
--       (2) 忙循环 1s 时 clock 是否前进
local base = ({...})[1] or "/mnt"
local out = base .. "/probe_clock_result.txt"
local f = io.open(out, "w")
local function log(s)
  if f then f:write(s .. "\n"); f:flush() end
  print(s)
end

local ok_c, computer = pcall(require, "computer")
if not ok_c then log("FATAL: no computer"); return end

local up0 = computer.uptime()
local c0 = os.clock()
log("start: uptime=" .. string.format("%.3f", up0) .. " clock=" .. string.format("%.3f", c0))

-- (1) 原版 os.sleep(2)（未装补丁）——墙钟 2s
os.sleep(2)
local up1 = computer.uptime()
local c1 = os.clock()
log("after sleep(2): uptime=" .. string.format("%.3f", up1) .. " clock=" .. string.format("%.3f", c1))
log("dt: uptime=" .. string.format("%.3f", up1 - up0) .. " clock=" .. string.format("%.3f", c1 - c0))

-- (2) 忙循环 1s（clock 驱动）——clock 是否随 busy 前进
local t0 = os.clock()
while os.clock() - t0 < 1 do end
log("after busy 1s: uptime=" .. string.format("%.3f", computer.uptime()) .. " clock=" .. string.format("%.3f", os.clock()))
log("dt busy: uptime=" .. string.format("%.3f", computer.uptime() - up1) .. " clock=" .. string.format("%.3f", os.clock() - c1))

if f then f:close() end
log("probe done")
