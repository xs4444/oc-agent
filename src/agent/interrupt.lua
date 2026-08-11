-- ═══════════════════════════════════════════════════════════════
-- agent.interrupt — Ctrl+C 中断支持（v0.3.86）
--
-- 痛点: 非 Ready 状态（chat 请求 / 工具执行 / 重试退避 / subagent
-- 等待）时 Ctrl+C 无效——OpenOS 的 os.sleep 内部 event.pull("timer")
-- 带过滤，interrupted 事件不匹配被丢弃; http 读循环 / wait_modem_message
-- 同理。事件到不了处理代码。
--
-- 方案: 可中断 os.sleep 补丁——无过滤轮询改为多过滤 pull
-- ("timer","interrupted","modem_message")，interrupted 匹配时设置标志
-- 提前返回; modem_message 转发给注册 handler（文件服务——chat 期间
-- explorer 请求实时处理，不排队不丢）。所有阻塞点 yield 后检查标志。
--
-- 阻塞点接入清单:
--   http.lua     读循环每 chunk + 重试退避（yield 后检查 interrupt.poll）
--   subagent.lua wait_modem_message 多过滤 + interrupted 检测
--   init.lua     process_exchange 工具循环 + chat 错误处理
-- ═══════════════════════════════════════════════════════════════

local event = require("event")
local computer = require("computer")

local FLAG = false

local M = {}

M.set = function() FLAG = true end
M.clear = function() FLAG = false end
M.poll = function() return FLAG end

-- 消费式读取: 返回并清除标志（process_exchange 每轮工具循环用）
M.consume = function()
  local v = FLAG
  FLAG = false
  return v
end

-- 注册: sleep 期间收到的 modem_message 转发（main() 注入文件服务 hook）
M.forward = nil

M.installed = false

-- 可中断 os.sleep 补丁（替换 OpenOS 原版）。幂等。
-- 原版内部 event.pull("timer") 单过滤——Ctrl+C 的 interrupted 被丢弃。
-- 多过滤 ("timer","interrupted","modem_message"): interrupted 设标志
-- 提前返回（调用方检测 poll 终止阻塞）; modem_message 转发 handler
-- （文件服务）; timer 忽略（agent 不用 event.timer）。其他事件（key_down
-- 等）仍被丢弃——chat 期间本就不应接受输入，语义合理。
M.install = function()
  if M.installed then return end
  os.sleep = function(t)
    -- 基准用 computer.uptime()（v0.3.88 热修复）: os.clock() 在 OC/ocvm
    -- 是 CPU 时间——空闲不前进，os.sleep(t>0) 的 deadline 永不达到 →
    -- while true 死循环挂起（probe_interrupt3 实证: os.sleep(2) 挂死,
    -- probe_clock 实证: sleep 2s clock 只走 0.024s）。uptime 是墙钟。
    local deadline = computer.uptime() + (t or 0)
    while true do
      -- 先拉事件再检查超时（v0.3.87 修复）: OpenOS internet.request
      -- 迭代器等待数据时调 os.sleep(0)（yield 让出）——原实现先检查
      -- remaining<=0 直接 return，t=0 时从不 event.pull，Ctrl+C 的
      -- interrupted 永远收不到（probe_interrupt 实证: 等待期注入
      -- interrupted 补丁未触发）。改为先 pull(0)（非阻塞让出 + 消费
      -- pending 事件）再检查超时，os.sleep(0) 也能捕获中断。
      local remaining = deadline - computer.uptime()
      local wait = remaining > 0 and math.min(0.1, remaining) or 0
      -- 无过滤 pull + 自判事件名（v0.3.89 修复）: OpenOS 的
      -- event.pull(wait, "a","b","c") 语义是"事件名 match 'a' 且 参数1
      -- =='b' 且 参数2=='c'"（AND 位置匹配），不是匹配多个事件名——
      -- 多过滤用法下 interrupted 事件永远被拒（probe_pullmulti 实证:
      -- 单过滤/无过滤都能收到 interrupted，多过滤 nil）。改用无过滤
      -- pull，非目标事件忽略继续循环。
      local sig = {event.pull(wait)}
      if sig[1] == "interrupted" then
        FLAG = true
        return
      elseif sig[1] == "modem_message" then
        local h = M.forward
        if h then pcall(h, sig) end
      end
      -- 其他事件: 忽略继续循环; 超时（sig[1]==nil）由 remaining 兜底
      if remaining <= 0 then return end
    end
  end
  M.installed = true
end

return M
