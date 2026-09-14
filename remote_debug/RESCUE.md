# 救援运行手册（RESCUE）

2026-09-14 起（v5 废弃后更新为单守护现实）。目标：在 v6 单守护 + rc 服务
autostart 的架构下，明确"远控通道全失"时的恢复路径。所有步骤分阶段、带显式
闸门；任一门未过即停，交人工重启。

> **⚠️ 全文规则（务必遵守）**：绝不在 console **前台**启动长驻守护
> （`remote_host.lua`）；一律经 detached 线程启动器（`start_all.lua` /
> `start_rh2.lua`）或 rc 服务拉起。后果一句话：**前台起守护 = console 被占用
> 到重启**（OpenOS 无 `&` 后台符，守护主循环永不返回）。
> 注意：在 console 跑 `start_all.lua` / `start_rh2.lua` 本身**没问题**（它们
> 立即返回）——规则只针对直接前台跑长驻守护。

## 当前活体风险状态（v5 废弃后，2026-09-14）

- **单守护**：仅端口 8100（v6 `remote_host.lua`）在跑；8001（v5）已废弃，
  `remote_debug.lua` 已从仓库删除（软盘副本同步删除）。
- **autostart**：rc 服务 `/etc/rc.d/remoted.lua`（`rc remoted enable`，配置
  `/etc/rc.cfg`）以 detached 线程拉起 v6；`/home/.shrc`（含
  `lua /home/start_all.lua`）为二级保险。两者经标记文件
  （`/home/.remoted_lock_<port>`）幂等。
- **活体风险**：若 v6 守护挂掉**且** autostart 也坏了（rc 服务未启用 /
  `start_all.lua` 丢失），远控通道全失，**须人工重启机器人**才能恢复。
  真机验证：远程重启（`computer.shutdown(true)`）后 v6 通道自动恢复，e2e 11/11。

## 死人计划（人工兜底）

若 v6 守护挂掉且 autostart 失效（远控通道全失、console 仍可用），操作员在
机器人 console 输入：

```
reboot
```

重启后（console 可用），**只跑这一条**（它把 v6 作为 detached 线程拉起后
立即返回，不占 console）：

```
lua /home/start_all.lua
```

**为何只跑一条**：OpenOS shell 无作业控制（无 `&` 后台符），而 v6 守护主循环
`while true do`（`remote_host.lua`）永不返回、`shell.execute` 把子进程跑到完成
（`full_shell.lua:13-14`）→ 前台 `lua /home/remote_host.lua` 会**永久占用
console**，操作员永远等不到提示符。`start_all.lua` 用 `thread.create(fn):detach()`
拉起 v6 后立即返回，故安全。

**最后手段变体**（仅当 `/home/start_all.lua` 丢失，如 `/home` 损坏但软盘幸存）：
从软盘跑它（`lua /mnt/3e9/start_all.lua`）是更好的兜底（detached 起 v6，不占
console）。若软盘也无 `start_all.lua`，前台 `lua /home/remote_host.lua` 仍能恢复
8100，但**明确警告**：这会**阻塞 console 直到重启**（前台守护永不返回）——是
权衡，不是免费动作。

## ⚠️ 已知缺陷与硬约束（2026-09-14 发现，历史保留，必读）

以下三条缺陷经「源码阅读 + 真机实验」双重确认（ground truth），勿重新踩坑。
（v5 废弃后，缺陷 2 的双实例场景仅适用于可选的 `start_rh2.lua` 8101 验证路径。）

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

### 缺陷 2（高，仅适用 start_rh2.lua 8101 验证路径）— 双 v6 实例临时文件路径冲突（文档约束）

`remote_host.lua`（v6）的临时文件路径由「发送方地址 + 消息 id」拼成
（`/home/rh_out_<sender>_<id>`、`/home/rh_err_<sender>_<id>`、
`/home/rh_wt_<sender>_<id>`，见 remote_host.lua:189-190/271）。两个 v6 实例
（8100 与 8101）跑在同一台机器、共享 `/home`、看到同一个 `sender`（控制端
游戏机地址），且每个客户端连接各自从 1 编号 op → **两实例对同一 id 生成
完全相同的临时路径**。更糟：每个实例启动时 `startup_cleanup()`
（remote_host.lua:166-173，主循环前 :368 调用）删除**所有** `/home/rh_*`
→ **启动 8101 会删掉 8100 的在飞 exec/write 临时文件，反之亦然**。

**硬约束**：两个 v6 实例并存期间，**不要同时对两者跑 `exec` 或 `write`**
（会互删在飞文件）。**只有 `ping` 可交替跑**（ping 不分配任何临时文件，
remote_host.lua:404-405 只回 pong），exec/write 必须串行且只对一个实例。

**v5 废弃后的适用范围**：单守护（仅 8100）下无此问题。此约束**仅**适用于
可选的 `start_rh2.lua` 8101 验证路径（热切换/升级前验证第二实例）。

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

**修法**：死人计划改为**只跑一条** `lua /home/start_all.lua`（它把 v6 作为
`thread.create(fn):detach()` 线程拉起后立即返回，不占 console）。
**全文规则**：绝不在 console 前台启动长驻守护（`remote_host.lua`）；一律经
detached 启动器（`start_all.lua`）或 rc 服务。
后果一句话：前台起守护 = console 被占用到重启。

## 未验证项（勿断言为事实）

- **无人输入机器人的 shell 输入等待是否真的 park 一个原生 pull**（那个
  parked pull 正是 thread 守护依赖的泵，docs §8-16）。若 shell 不 park
  原生 pull，thread 守护的唤醒注册无人服务 → 守护生来即死。此环未验证，
  功能验证（ping 40/40）是最终判据。

## 仓库规则

推真机的任何文件必须同时提交本仓库（AGENTS.md）——`update.lua` 下次 tag
更新会覆盖未提交改动。
