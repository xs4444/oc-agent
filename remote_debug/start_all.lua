-- start_all.lua — 冷启动入口 (部署到机器人 /home/start_all.lua)
-- 拉起 v6 守护 (/home/remote_host.lua, 端口 8100) 作为一个 detached 线程。
--
-- v6-only (2026-09-14): v5 一次性协议 (remote_debug.lua / 端口 8001) 已废弃
--   —— 它是 v6 的严格子集 (ops ping/info/exec/read/write/delete ⊂ v6 的同 6 个
--   + auth/write_chunk/cancel), 能力更弱 (exec 7680B 截断 / 无流分离 / 无 cancel
--   / write ≤6000B / 无消息 ID), 且与 v6 同机同 modem 同 VM 同事件队列,
--   **不构成独立冗余** —— 实测两者一起被同一个楔子弄死。
--   保留它反而制造问题: 同机两个"原生 puller"互抢事件 (winner-take-all,
--   实测 8001 收 0/40 而 8100 收 40/40)。故整体退役, 只留 v6。
--   详见 docs/REMOTE_PROTOCOL.md §8 与 remote_debug/RESCUE.md。
--
-- 为什么必须 detach (docs/REMOTE_PROTOCOL.md §8-14):
--   thread.create 出的线程是创建者进程的句柄; 创建者退出时 teardown 会
--   join 每个句柄 (lib/thread.lua:121 self.close = self.join, timeout
--   math.huge) → 线程还活着时创建者永远退不出。detach() 把句柄重挂到
--   不朽的根 /init.lua 进程 (lib/thread.lua:102-104 → attach(init_thread)),
--   创建者可正常退出且线程存活到重启。
--   detach() 还为 handler 路由: thread.create 给每个线程自己的私有
--   handler 集 (lib/thread.lua:206-207); detach() 重挂到 init 进程, 其
--   data.handlers 就是共享 ROOT 表 (thread.lua:297)。不 detach 的守护
--   唤醒注册进瞬态私有集 → 守护生来即死却仍打印健康启动横幅。
--   故验证必须功能化 (ping/exec), 绝不看横幅。
--
-- 线程体必须 pcall 包裹: 未处理错误 = 静默死通道 (不拖垮整机, 记入
-- /tmp/event.log, docs §8-15)。
--
-- 幂等性 (跨进程安全):
--   标记文件 /home/.remoted_lock_<port> 记录启动时的 computer.uptime()。
--   uptime 重启归零, 故「存储值 > 当前值」证明标记来自上一次启动 (stale,
--   可安全回收); 「存储值 <= 当前值」证明标记来自本次启动 (fresh, 本启动
--   已起过守护 → 跳过)。
--   端口 isOpen 是组件状态 (NetworkCard.openPorts): 守护进程死亡不清端口,
--   故 isOpen==true 不证明有活守护 (可能已崩), 但 isOpen==false 证明无
--   守护在听。
--   (曾用「向本机地址发自测 ping」做探针 —— 恒 false: 机器收不到自己的
--    modem send, Network.scala:168-172 reachableNodes 过滤 node != reference,
--    真机实测 self_SEND_received=false。已弃用。)
--   决策表:
--     --force 标志               → 启动 (操作员显式强制, 自担重复风险)
--     标记 fresh                 → 跳过 (本启动已起守护, 假定存活)
--     标记 stale/缺失 + 端口关   → 启动 (无活守护, 写新标记)
--     标记 stale/缺失 + 端口开   → 跳过 (异常: 端口开却无 fresh 标记, 保守)
--   强制重启: 删标记文件 (端口关时生效) 或 `lua start_all.lua --force`
--   (端口开时也强制启动; 仅在你确认无活守护时使用)。
--
-- 注意: 不要用「只改本脚本的 V6_PORT」来起第二个实例 —— 被加载的
--   remote_host.lua 内部硬编码自己的 PORT (remote_host.lua:51),
--   那样会在原端口上多起一个同端口守护 (重复帧 → 协议损坏)。
--   要起备用实例须替换被加载脚本的端口常量 (见 start_rh2.lua)。

local component = require("component")
local event = require("event")
local thread = require("thread")
local computer = require("computer")

-- 路径常量
local V6_PATH = "/home/remote_host.lua"
local V6_PORT = 8100

-- 找 modem
local modemAddr
for addr, ctype in pairs(component.list()) do
  if ctype == "modem" then
    modemAddr = addr
    break
  end
end
if not modemAddr then
  event.onError("start_all: no modem found")
  return
end

-- 注册表: 线程句柄 (per-process; stop() 和重入用)
_G.__remoted_threads = _G.__remoted_threads or {}

-- 标记文件: /home/.remoted_lock_<port>, 内容为启动时的 computer.uptime()
local function marker_path(port)
  return "/home/.remoted_lock_" .. port
end

-- 读标记: 返回存储的 uptime (number); 无标记/不可解析 → nil
local function read_marker(port)
  local f = io.open(marker_path(port), "r")
  if not f then return nil end
  local content = f:read("*a")
  f:close()
  return tonumber(content)
end

-- 写标记: 记录当前 uptime; 失败记 event.onError (不阻塞, 不重试)
local function write_marker(port)
  local f = io.open(marker_path(port), "w")
  if not f then
    event.onError("start_all: cannot write marker " .. marker_path(port))
    return false
  end
  f:write(string.format("%.6f", computer.uptime()))
  f:close()
  return true
end

-- 端口是否已开 (组件状态; 守护死亡不清端口)
local function is_port_open(port)
  local ok, res = pcall(component.invoke, modemAddr, "isOpen", port)
  return ok and res
end

-- 幂等性决策: 返回 (是否启动, 原因)。
-- 保守原则: 端口已开且无 fresh 标记时, 宁可跳过也不冒同端口重复帧风险。
local function decide_start(port, force)
  if force then
    return true, "forced via --force"
  end
  local stored = read_marker(port)
  if stored and stored <= computer.uptime() then
    -- fresh: 本启动已起过守护 → 跳过 (假定存活)
    return false, "marker fresh: daemon started this boot"
  end
  if not is_port_open(port) then
    -- 端口关 → 无活守护 (证明) → 启动
    return true, "port closed: no live daemon"
  end
  -- 端口开但无 fresh 标记 (stale 或缺失) → 异常, 保守跳过
  return false, "port open but no fresh marker: conservative skip"
end

-- 启动 v6 守护为 detached 线程, pcall 包裹。
-- 幂等性: 标记文件 + 端口状态 (跨进程安全)。
local function start_daemon(port, force)
  -- 注册表命中 (本进程已启动) → 跳过
  if _G.__remoted_threads.v6 then
    return "skipped (registry: already started this process)"
  end
  -- 幂等性守卫
  local do_start, reason = decide_start(port, force)
  if not do_start then
    return "skipped (" .. reason .. ")"
  end
  -- 启动守护 (线程体 pcall 包裹, 错误走 event.onError)
  local t = thread.create(function()
    local ok, err = pcall(dofile, V6_PATH)
    if not ok then
      event.onError("start_all: v6 failed: " .. tostring(err))
    end
  end)
  t:detach()
  _G.__remoted_threads.v6 = t
  -- 写标记 (记录本次启动的 uptime, 供后续进程判断)
  write_marker(port)
  return "started (" .. reason .. ")"
end

-- --force 标志: 操作员显式强制启动 (端口开时也启动, 自担重复风险)
local args = {...}
local force = false
for _, a in ipairs(args) do
  if a == "--force" or a == "force" then
    force = true
  end
end

local v6_status = start_daemon(V6_PORT, force)

print("start_all: v6=" .. v6_status)
return
