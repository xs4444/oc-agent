-- probe_pullmulti.lua — 决定性对比: 单过滤 vs 多过滤 event.pull 捕获 interrupted
-- 用法: lua /mnt/<short>/probe_pullmulti.lua /mnt/<short>
-- 背景: probe_signal 实证单过滤 event.pull(3,"interrupted") 能捕获 pushSignal。
--       probe_interrupt3 里补丁 os.sleep 的 event.pull(wait,"timer","interrupted",
--       "modem_message") 多过滤却捕获不到（flag=false, LINK_FAILED）。
-- 本 probe: 两种 pull 各自配 timer 0.5s push, 分别测是否捕获 interrupted。
-- 判定:
--   A 单过滤 OK + B 多过滤 FAIL → OC/ocvm event.pull 多过滤有 bug → 补丁
--     需换 pull 策略（无过滤 pull + 自判类型）
--   A/B 都 OK → 补丁实现另有问题（probe_interrupt3 时序/引用）
--   A/B 都 FAIL → pushSignal→pull 链路在测试条件下有问题
local base = ({...})[1] or "/mnt"
local out = base .. "/probe_pullmulti_result.txt"
local f = io.open(out, "w")
local function log(s)
  if f then f:write(s .. "\n"); f:flush() end
  print(s)
end

local ok_c, computer = pcall(require, "computer")
local ok_e, event = pcall(require, "event")
if not (ok_c and ok_e) then log("FATAL: computer/event missing"); return end

-- A) 单过滤对照（probe_signal 已证 OK, 这里复测确认环境一致）
local t1 = event.timer(0.5, function()
  computer.pushSignal("interrupted")
end)
log("A: pull(3, \"interrupted\") waiting...")
local a = {event.pull(3, "interrupted")}
log("A got: " .. tostring(a[1]))
event.cancel(t1)

-- B) 多过滤（补丁同款: timer/interrupted/modem_message）
local t2 = event.timer(0.5, function()
  computer.pushSignal("interrupted")
end)
log("B: pull(3, \"timer\", \"interrupted\", \"modem_message\") waiting...")
local b = {event.pull(3, "timer", "interrupted", "modem_message")}
log("B got: " .. tostring(b[1]))
event.cancel(t2)

-- C) 无过滤 + 自判（补丁潜在替代方案）
local t3 = event.timer(0.5, function()
  computer.pushSignal("interrupted")
end)
log("C: pull(3) unfiltered waiting...")
local c = {event.pull(3)}
log("C got: " .. tostring(c[1]))
event.cancel(t3)

if a[1] == "interrupted" and b[1] == "interrupted" and c[1] == "interrupted" then
  log("RESULT: ALL_FILTERS_WORK — 多过滤正常, 补丁实现另有问题")
elseif a[1] == "interrupted" and b[1] ~= "interrupted" then
  log("RESULT: MULTI_FILTER_BROKEN — 单过滤 OK 但多过滤 FAIL → 补丁需换 pull 策略")
elseif a[1] ~= "interrupted" then
  log("RESULT: SIGNAL_LINK_BROKEN — 单过滤都 FAIL → pushSignal→pull 链路问题")
else
  log("RESULT: UNEXPECTED — a=" .. tostring(a[1]) .. " b=" .. tostring(b[1]) .. " c=" .. tostring(c[1]))
end

if f then f:close() end
log("probe done")
