-- rc.d_remoted.lua — DRAFT 内容, 安装为机器人 /etc/rc.d/remoted.lua
-- (仓库文件名故意用 rc.d_remoted.lua, 避免被误认为仓库可执行物)
--
-- 启用方法:
--   rc remoted enable
-- 性质:
--   - 每次启动恰好跑一次 (区别于 .shrc/autorun, docs §8-16)
--   - headless 安全 (无 shell/gpu/screen/keyboard 也起)
--   - start() 在单一 init 进程内执行, 必须尽快返回
-- 启用前务必字节级备份 /etc/rc.cfg (rc enable 会改写它)。
--
-- start()/stop() 契约 (与 start_all.lua 一致):
--   start_all.lua 把线程句柄存进 _G.__remoted_threads; stop() 读该表
--   并 kill 每个句柄。限制: stop() 仅在与 start() 同进程时有效 (同 _G);
--   若 stop() 在新进程运行 (如 shell 里 rc remoted stop, 而 start() 在
--   启动时于 init 进程跑过), 则 _G 不同, 注册表不可见, 守护停不掉 →
--   需重启机器人。

function start()
  -- start() 在单一 init 进程内执行, 必须尽快返回。
  -- 阻塞循环会卡住启动、shell 重生循环和所有其他进程 (docs §8-16)。
  -- 故 dofile start_all.lua (它把守护起为 detached 线程后立即返回),
  -- 然后立即返回。此处绝不 event.pull 循环。
  local fs = require("filesystem")
  if fs.exists("/home/start_all.lua") then
    dofile("/home/start_all.lua")
  else
    print("remoted: /home/start_all.lua not found; skipping")
  end
  return
end

function stop()
  -- stop() 通过 _G.__remoted_threads 里的线程句柄 kill 守护。
  -- 限制: 仅在与 start() 同进程时有效 (同 _G)。若 stop() 在新进程
  -- 运行 (如 shell 里 rc remoted stop, 而 start() 在启动时于 init
  -- 进程跑过), 则 _G 不同, 注册表不可见, 守护停不掉 → 需重启机器人。
  local threads = _G.__remoted_threads
  if threads then
    for name, t in pairs(threads) do
      pcall(t.kill, t)
    end
    _G.__remoted_threads = nil
    print("remoted: stop() killed daemons")
  else
    print("remoted: stop() — no registry (different process?); reboot to stop daemons")
  end
  return
end
