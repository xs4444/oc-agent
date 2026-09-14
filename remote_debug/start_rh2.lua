-- start_rh2.lua — 救援桥 (部署到机器人 /home/start_rh2.lua)
-- 在端口 8101 上拉起第二个临时 v6 实例, 供当前卡死状态存在时建立冗余,
-- 以便在高风险解卡前先有备份通道。
--
-- 为什么用替换而非编辑 remote_host.lua:
--   remote_host.lua 是已部署的 v6 服务器 (端口 8100), 编辑它会破坏现有
--   8100 通道。本脚本读入源码, 仅把端口常量 PORT = 8100 替换为
--   PORT = 8101 (恰好一次), 加载为独立 chunk 在 detached 线程里运行。
--
-- 为什么断言替换恰好一次:
--   若替换 0 次 (模式不存在), 第二个实例仍跑在 8100 → 与现有 8100 守护
--   同端口 → 重复帧 → 协议损坏。若替换 >1 次 (模式多处出现), 说明源码
--   结构已变, 盲目替换会引入不可预测行为。两种情况都必须大声报错,
--   绝不静默继续。
--
-- 线程体 pcall 包裹: 未处理错误 = 静默死通道 (docs §8-15)。
-- detach(): 创建者可退出且线程存活到重启 (docs §8-14)。
--
-- ⚠️ 临时文件冲突警告 (详见 RESCUE.md「缺陷 2」):
--   v6 临时文件路径由「发送方地址 + 消息 id」拼成 (/home/rh_out|err|wt_
--   <sender>_<id>, remote_host.lua:189-190/271)。8100 与 8101 两实例共享
--   /home、看到同一 sender → 对同一 id 生成相同临时路径。且本实例启动时
--   startup_cleanup() (remote_host.lua:166-173) 删除所有 /home/rh_* →
--   启动 8101 会删掉 8100 的在飞 exec/write 临时文件。故两实例并存期间
--   勿同时对两者跑 exec/write (只有 ping 可交替, ping 不分配临时文件)。

local event = require("event")
local thread = require("thread")

local V6_PATH = "/home/remote_host.lua"

-- 读入 v6 源码
local f = io.open(V6_PATH, "r")
if not f then
  event.onError("start_rh2: cannot open " .. V6_PATH)
  return
end
local src = f:read("*a")
f:close()

-- 替换 PORT = 8100 → PORT = 8101, 断言恰好一次
local new_src, count = src:gsub("PORT%s*=%s*8100", "PORT = 8101")
if count ~= 1 then
  event.onError("start_rh2: PORT substitution count=" .. count
    .. " (expected 1); aborting to avoid duplicate frames on 8100")
  return
end

-- 加载替换后的源码为独立 chunk
local chunk, load_err = load(new_src, "=remote_host@8101")
if not chunk then
  event.onError("start_rh2: load failed: " .. tostring(load_err))
  return
end

-- 在 detached 线程里运行, pcall 包裹
local t = thread.create(function()
  local ok, err = pcall(chunk)
  if not ok then
    event.onError("start_rh2: v6@8101 failed: " .. tostring(err))
  end
end)
t:detach()

print("start_rh2: WARNING: 8101 startup_cleanup 将删除所有 /home/rh_* (含 8100 在飞 exec/write 临时文件); 两实例并存期间勿同时对两者跑 exec/write (详见 RESCUE.md 缺陷 2)")
print("start_rh2: v6@8101 started")
return
