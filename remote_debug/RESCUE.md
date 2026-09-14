# 救援运行手册（RESCUE）

2026-09-14 起。目标：在**不重启机器人**的前提下，为当前卡死状态建立冗余
通道，再外科式解卡，最后补 autostart。所有步骤分阶段、带显式闸门；任一门
未过即停，交人工重启。

> **⚠️ 全文规则（务必遵守）**：绝不在 console **前台**启动长驻守护
> （`remote_debug.lua` / `remote_host.lua`）；一律经 detached 线程启动器
> （`start_all.lua` / `start_rh2.lua`）或 rc 服务拉起。后果一句话：**前台起
> 守护 = console 被占用到重启**（OpenOS 无 `&` 后台符，守护主循环永不返回）。
> 注意：在 console 跑 `start_all.lua` / `start_rh2.lua` 本身**没问题**（它们
> 立即返回）——规则只针对直接前台跑长驻守护。

## ⚠️ 已知缺陷与硬约束（2026-09-14 发现，必读）

以下三条缺陷经「源码阅读 + 真机实验」双重确认（ground truth），勿重新踩坑。

### 缺陷 1（高）— start_all.lua 存活探针恒 false（已修）

原 `probe_alive` 向**本机地址**发 modem ping 等 pong，但机器收不到自己的
send（源码 `Network.scala:168-172` `reachableNodes` 过滤 `node != reference`，
`send()` `:377-379` 只投递给可达目标；真机实测 `self_SEND_received=false`、
`self_BROADCAST_received=false`）。故探针恒 false，`start_daemon` 永不返回
`"skipped (alive)"`，幂等性只剩 per-process 注册表 `_G.__remoted_threads` →
**跨进程重跑**（rc 服务 + 手动 console，或两次 console）必起第二个同端口
守护 → 重复帧 → 协议损坏。

**修法**（start_all.lua；不是删探针，而是换成跨进程安全守卫）：标记文件
`/home/.remoted_lock_<port>` 记录启动时 `computer.uptime()`（uptime 重启归零，
「存储值 > 当前值」= stale 可安全回收，「存储值 <= 当前值」= fresh）。端口
`isOpen` 是组件状态（`NetworkCard.openPorts`，守护死亡不清端口）：
`isOpen==false` 证明无守护在听，`isOpen==true` 不证明有活守护（可能已崩）。
决策表（每守护）：

- `--force` 标志 → 启动（操作员显式强制，自担重复风险）
- 标记 fresh → 跳过（本启动已起守护，假定存活）
- 标记 stale/缺失 + 端口关 → 启动（无活守护，写新标记）
- 标记 stale/缺失 + 端口开 → 保守跳过（异常：端口开却无 fresh 标记，避免重复帧）

强制重启：删标记文件（端口关时生效）或 `lua /home/start_all.lua --force`
（端口开时也强制启动；仅在你确认无活守护时使用）。

### 缺陷 2（高，Phase 1 桥）— 双 v6 实例临时文件路径冲突（文档约束）

`remote_host.lua`（v6）的临时文件路径由「发送方地址 + 消息 id」拼成
（`/home/rh_out_<sender>_<id>`、`/home/rh_err_<sender>_<id>`、
`/home/rh_wt_<sender>_<id>`，见 remote_host.lua:189-190/271）。两个 v6 实例
（8100 与 8101）跑在同一台机器、共享 `/home`、看到同一个 `sender`（控制端
游戏机地址），且每个客户端连接各自从 1 编号 op → **两实例对同一 id 生成
完全相同的临时路径**。更糟：每个实例启动时 `startup_cleanup()`
（remote_host.lua:166-173，主循环前 :368 调用）删除**所有** `/home/rh_*`
→ **启动 8101 会删掉 8100 的在飞 exec/write 临时文件，反之亦然**。

**硬约束**：两个 v6 实例并存期间，**不要同时对两者跑 `exec` 或 `write`**
（会互删在飞文件）。Phase 1 的验收测试（交替 **ping**）是安全的，因为 ping
不分配任何临时文件（remote_host.lua:404-405 只回 pong）——**只有 ping 可
交替跑（40/40 闸门），exec/write 必须串行且只对一个实例**。

**为何不改 remote_host.lua**：它是已部署的守护（8100 正在服务），改它会
破坏现有通道。本约束以文档固化（本节）+ `start_rh2.lua` 启动时打印警告。

### 缺陷 3（高）— 死人计划的前台守护启动不可执行（已修）

原死人计划让操作员 reboot 后在 console 依次输入
`lua /mnt/3e9/remote_debug.lua` 再 `lua /home/start_all.lua`。但：
(1) OpenOS shell **无作业控制**（无 `&` 后台符；`full_sh.lua:83-84` 的 `&`
相关代码只是重定向处理）；(2) v5 守护主循环 `while true do ... end`
（`remote_debug.lua:193`）仅在 `"interrupted"` 信号退出（`:251-253`），
实际永不返回；(3) `shell.execute` 把子进程跑到完成（`full_shell.lua:13-14`
→ `process.internal.continue` 循环 `while coroutine.status(co) ~= "dead"`）。
故前台 `lua /mnt/3e9/remote_debug.lua` **永久占用 console**，操作员永远等不到
提示符去敲第二行 → 按原 runbook 执行会把操作员卡死在正是要救援的阻塞态。
（这也解释了当前活体 console 阻塞的根因：前台起 v5 正是阻塞之源。）

**修法**：死人计划改为**只跑一条** `lua /home/start_all.lua`（它把 v5+v6 各
作为 `thread.create(fn):detach()` 线程拉起后立即返回，不占 console）。
**全文规则**：绝不在 console 前台启动长驻守护（`remote_debug.lua` /
`remote_host.lua`）；一律经 detached 启动器（`start_all.lua`）或 rc 服务。
后果一句话：前台起守护 = console 被占用到重启。

## 当前活体风险状态（2026-09-14 实测）

- **仅端口 8100（v6）可用**；8001（v5）已死（0/40 回复）。
- **console 阻塞**：shell 卡在 v5 handler 内（`shell.execute` 等 v5 回复，
  v5 已死 → 永不返回）。
- **无 autostart**：`/home/.shrc` 是空文件，v6 重启后不自动起。若 v6 死，
  远控通道全失，**须人工重启机器人**才能恢复。
- 卡死机制（docs §8-13/14）：某 helper 进程 `thread.create(dofile
  remote_host.lua)` 后退出，teardown 在 `join` 里永久阻塞（线程未 detach）；
  该进程的 `waitForDeath` 无过滤 `event.pull` 充当机器唯一原生泵，消费并丢弃
  8001 流量（无 v5 handler 匹配），v5 死、v6 活。

## Phase 1 — 加冗余（8101）

**目标**：在动任何解卡动作前，先有第二个可用 v6 通道。

1. 部署 `start_rh2.lua` 到机器人 `/home/start_rh2.lua`（软盘摆渡或
   `tools/remote_server.py --lua` 写入 + 回读校验）。
2. 运行 `lua /home/start_rh2.lua`（经 8100 exec 或 console；`start_rh2.lua`
   立即返回，console 跑无妨——全文规则只针对直接前台跑长驻守护）。
3. **功能验证**（绝不看横幅，docs §8-14）：交替对 8100 和 8101 各发 40 次
   ping，**两者都必须 40/40 应答**。交替 ping 是安全的（ping 不分配临时文件，
   见上「缺陷 2」硬约束）；此阶段**勿**对两实例跑 exec/write。

**闸门**：若 8101 不能证明存活（<40/40），**停**——不做任何解卡，交人工
重启机器人。

## Phase 2 — 外科式解卡（仅 Phase 1 绿后）

**目标**：让卡死的 creator 进程 teardown 完成，`shell.execute` 返回，v5 的
8001 循环恢复，console 解锁。

两个候选方案（分析识别）：

- **(i) kill 旧 v6 守护线程句柄**：找到 creator 进程持有的 v6 线程句柄，
  `t:kill()`。线程死 → creator 的 `join` 返回 → teardown 完成。
- **(ii) 伪造 creator 进程的退出结果**：让 `waitForDeath` 的 `proc_ok` 判
  真（`mt.attached.data.result` 非 table 或 `result[1]` 真），使
  `ready_to_die` 成立，`waitForDeath` 退出。

**显式警告**：两个方案**都必然杀掉当前 8100 守护**（v6 线程是 creator 的
句柄，kill 它 = 杀 8100）。故 8101 冗余必须先存在（Phase 1 闸门）。

**预期收益**：creator teardown 完成 → `shell.execute` 返回 → v5 的 8001
循环恢复（8001 复活）**且** console 解锁。

## 死人计划（R10）— 人工兜底

若救援误触发（8100/8101 全失、console 仍阻塞），操作员在机器人 console
输入：

```
reboot
```

重启后（console 可用），**只跑这一条**（它把 v5+v6 各作为 detached 线程
拉起后立即返回，不占 console）：

```
lua /home/start_all.lua
```

这一条**取代**旧的两条命令序列（`lua /mnt/3e9/remote_debug.lua` +
`lua /home/start_all.lua`）。原因：OpenOS shell 无作业控制（无 `&` 后台符），
而 v5 守护主循环 `while true do`（`remote_debug.lua:193`）仅在 `"interrupted"`
退出、`shell.execute` 把子进程跑到完成（`full_shell.lua:13-14`）→ 前台
`lua /mnt/3e9/remote_debug.lua` 会**永久占用 console**，操作员永远等不到提示符
去敲第二行（见上「缺陷 3」）。

**最后手段变体**（仅当 `/home/start_all.lua` 丢失，如 `/home` 损坏但软盘幸存）：
前台 `lua /mnt/3e9/remote_debug.lua` 仍能恢复 8001（v5），但**明确警告**：这会
**阻塞 console 直到重启**（前台守护永不返回）——是权衡，不是免费动作。若
`start_all.lua` 已按 Phase 4 部署到软盘，**从软盘跑它**（`lua /mnt/3e9/start_all.lua`）
是更好的兜底（detached 起 v5+v6，不占 console）。

## Phase 4 — autostart

1. 安装 rc 服务：把 `rc.d_remoted.lua` 的内容装到 `/etc/rc.d/remoted.lua`，
   `rc remoted enable`（启用前字节级备份 `/etc/rc.cfg`）。
2. **软盘补件**：软盘 `/mnt/3e9/` 当前只有 `remote_debug.lua`（v5.2.2），
   **没有** `remote_host.lua`（v6）。须把 `start_all.lua` 和一份
   `remote_host.lua` 也放到软盘，使冷恢复不依赖 `/home` 存活。

## 未验证项（勿断言为事实）

- **无人输入机器人的 shell 输入等待是否真的 park 一个原生 pull**（那个
  parked pull 正是 thread 守护依赖的泵，docs §8-16）。若 shell 不 park
  原生 pull，thread 守护的唤醒注册无人服务 → 守护生来即死。此环未验证，
  Phase 1 的功能验证（40/40 ping）是最终判据。

## 仓库规则

推真机的任何文件必须同时提交本仓库（AGENTS.md）——`update.lua` 下次 tag
更新会覆盖未提交改动。
