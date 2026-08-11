-- probe_interrupt.lua — 验证 http 迭代器等待期中断补丁是否生效
-- 用法: lua /mnt/<short>/probe_interrupt.lua /mnt/<short> <api_key> <model> <api_url>
-- 流程: 装 os.sleep 补丁 → event.timer(2s) 注入 interrupted → 真实 chat 请求
-- → 观察返回 err（"interrupted" = 补丁生效; 正常返回/超时 = 迭代器等待期
-- 补丁没机会跑——等待不让出 os.sleep，Ctrl+C 无法中断根因实证）。
local base = ({...})[1] or "/mnt"
local api_key = ({...})[2] or "free"
local model = ({...})[3] or "deepseek-v4-flash-free"
local api_url = ({...})[4] or "https://opencode.ai/zen/v1/chat/completions"

local out = base .. "/probe_interrupt_result.txt"
local f = io.open(out, "w")
local function log(s)
  if f then f:write(s .. "\n"); f:flush() end
  print(s)
end

package.path = base .. "/?.lua;" .. (package.path or "")
_TEST_MODE = true
-- agent.lua 在挂载根（/mnt/<mount>/agent.lua），不在 agent/ 子目录
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

-- 装中断补丁（agent.interrupt.install）
local ok_int, interrupt = pcall(require, "agent.interrupt")
if not ok_int then log("FATAL: no agent.interrupt: " .. tostring(interrupt)); return end
interrupt.install()
log("interrupt patch installed: os.sleep replaced=" .. tostring(os.sleep ~= nil))

-- 2 秒后注入 interrupted（模拟 Ctrl+C——event.timer 异步，不阻塞请求）
local ok_e, event = pcall(require, "event")
if not ok_e then log("FATAL: no event lib"); return end
local ok_c, computer = pcall(require, "computer")
if not ok_c then log("FATAL: no computer lib"); return end
-- uptime() 与 event.timer 同基准（墙钟），os.clock() 是 CPU 时间——分开记录
-- 才能判定 interrupted 注入是否落在 chat 请求窗口内
local up0 = computer.uptime()
log("uptime start: " .. string.format("%.1f", up0))
local timer_id = event.timer(2, function()
  log("[timer] injecting interrupted at uptime=" .. string.format("%.1f", computer.uptime()) .. " cpu=" .. string.format("%.1f", os.clock()))
  computer.pushSignal("interrupted")
end)
log("timer scheduled id=" .. tostring(timer_id))

-- 真实 chat 请求（与 chat2_test 同款）
local chat = agent_test.chat
local config = {api_key = api_key, model = model, api_url = api_url, context_window = 128000}
local messages = {{role = "user", content = "Reply with exactly: INTERRUPT_PROBE_DONE"}}

log("calling chat (model should think 5-15s)...")
local up_before = computer.uptime()
local t0 = os.clock()
local resp = chat(messages, config)
local dt = os.clock() - t0
local up_after = computer.uptime()
log("chat returned after " .. string.format("%.1fs cpu", dt) .. " uptime window [" .. string.format("%.1f", up_before) .. "," .. string.format("%.1f", up_after) .. "]")
log("chat err=" .. tostring(resp and resp.error))
log("chat content=" .. tostring(resp and resp.content):sub(1, 50))
if resp and resp.error and tostring(resp.error):find("interrupted", 1, true) then
  log("RESULT: INTERRUPT_PATCH_WORKS (err=interrupted)")
elseif resp and resp.error then
  log("RESULT: PATCH_NOT_TRIGGERED (err=" .. tostring(resp.error):sub(1, 80) .. ")")
else
  log("RESULT: REQUEST_COMPLETED_BEFORE_INTERRUPT or patch not triggered (content returned)")
end
log("interrupt flag after: " .. tostring(interrupt.poll()))

event.cancel(timer_id)
if f then f:close() end
log("probe done")
