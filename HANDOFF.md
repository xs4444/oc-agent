# HANDOFF — 远控协议项目交接（v6-only 单守护，已上线验收）

> 交接时点：2026-09-14 深夜。**v5 一次性协议已整体退役**，项目现为
> **v6-only 单守护**架构，真机验收通过（e2e 11/11，重启后自动恢复）。
> 本文档写给**下一个会话/代理**：读完即可继续，无需回溯历史会话。

## 1. 项目一句话

游戏端（主控机）远控游戏内机器人：从"一次性 HTTP 调试命令"演进为
**类 ssh 的远控协议栈**。**当前只有一代协议 v6.0**，跑在端口 8100，
带消息 ID 多路复用、流式 exec（out/err 分离）、分块文件传输（≤1MB）、
cancel、auth。设计文档：`docs/REMOTE_PROTOCOL.md`（§8 有 32 条实证坑位）。

## 2. 现状快照（交接时点已验证）

### 2.1 设备侧

| 项 | 状态 |
|---|---|
| 机器人（modem `84f13777-676d-4c8d-b608-6f5f1346b602`，computer id `491dbf5e-82d7-4611-a303-4a844589457c`） | 在线。**v6 守护（8100）在线**，由 rc 服务在启动时自动拉起。端口 8001 **已退役**（无守护） |
| 机器人 `/home/remote_host.lua` | ✓ 16381B，v6 服务器（与仓库逐字节一致） |
| 机器人 `/home/start_all.lua` | ✓ 7012B，冷启动（把 v6 起为 detached 线程后立即返回） |
| 机器人 `/etc/rc.d/remoted.lua` | ✓ 2110B，rc 服务（`rc.cfg` → `enabled = {"remoted"}`） |
| 机器人 `/home/.shrc` | ✓ 内容 `lua /home/start_all.lua`（二级保险；仅交互 shell 会 source） |
| 机器人软盘 `3e9` | `remote_host.lua`(16381B) + `start_all.lua`(7012B)。**v5 `remote_debug.lua` 已删除** |
| 游戏机 `/home/remote_client.lua` | ✓ 20550B，**v6-only v1.2**（旧版备份 `/home/remote_client.lua.v0327.bak`） |
| 游戏机 `/home/e2e_v6.lua` | ✓ 11 场景 e2e 套件 |
| v6 e2e | **11/11 ALL GREEN**（ping/info/exec/大输出/管道/失败附 err/小文件/50KB/删除/离线/cancel） |

### 2.2 仓库侧（`/home/hcj/aiProjects/mieAgent`）

- v5 相关文件**已删除**：`remote_debug/remote_debug.lua`（v5 服务器）、
  `remote_debug/listen.lua`（早期探针）。
- 新增/改动：`remote_debug/remote_host.lua`（v6 服务器）、
  `remote_debug/start_all.lua`（v6-only 冷启动）、
  `remote_debug/start_rh2.lua`（8101 备用实例桥）、
  `remote_debug/rc.d_remoted.lua`（rc 服务草案）、
  `remote_debug/RESCUE.md`（救援手册）、
  `remote_client/remote_client.lua`（v6-only，759→565 行）、
  `remote_client/e2e_v6.lua`、`remote_client/e2e_t11.lua`、
  `docs/REMOTE_PROTOCOL.md`（§8: 12→32 条）。

## 3. 文件地图

| 路径 | 角色 |
|---|---|
| `remote_debug/remote_host.lua` | **唯一守护**（端口 8100）：多路复用、流式 exec out/err、分块 read/write、cancel、auth、启动清理 `rh_*` |
| `remote_debug/start_all.lua` | 冷启动入口：把 v6 起为 `thread.create(fn):detach()` 线程后**立即返回**；幂等用标记文件 `/home/.remoted_lock_<port>` + 端口状态 |
| `remote_debug/start_rh2.lua` | 备用实例桥：读 `remote_host.lua`，把 `PORT 8100→8101` **替换恰好一次**（断言 count==1）再在 detached 线程跑。用于热升级前的验证 |
| `remote_debug/rc.d_remoted.lua` | rc 服务草案（装到 `/etc/rc.d/remoted.lua`）：`start()` 必须尽快返回 |
| `remote_debug/RESCUE.md` | 分阶段救援手册（含三条已修缺陷记录） |
| `remote_client/remote_client.lua` | 主控侧客户端库 **v6-only**（`h:exec/read/write/delete/ping/info/cancel`） |
| `tools/remote_server.py` | 本机→游戏机命令通道（base 用 `OC_REMOTE_BASE` 环境变量或 `--base` 传入，见下） |
| `tools/oc_deploy.py` | **推游戏机文件**（分块→校验→原子替换）。**勿用 write op** |
| `.oc-remote-token` | 远控 token |
| `repos/opencomputers/` | OC 源码（设计取证用） |

## 4. 设备访问（照抄即可）

```bash
cd /home/hcj/aiProjects/mieAgent
# 内网穿透地址属敏感信息，不入库：用环境变量传入（实际地址问用户/见本地笔记）
export OC_REMOTE_BASE="https://<你的内网穿透域名>:<端口>"

# 在机器人上跑 Lua（经游戏机中转；大文件用 tools/pull_session_hex.py）
python3 tools/remote_server.py client --base "$OC_REMOTE_BASE" \
  --token "$(cat .oc-remote-token)" --lua '<lua 代码>' --wait N
# 推文件到游戏机（脚本会分块+校验+原子替换，自动备份）
python3 tools/oc_deploy.py <本地文件> /home/<远端路径> \
  --base "$OC_REMOTE_BASE" --token "$(cat .oc-remote-token)"
# v6 e2e 复跑（在游戏机上执行 e2e_v6.lua）
python3 tools/remote_server.py client --base "$OC_REMOTE_BASE" \
  --token "$(cat .oc-remote-token)" \
  --lua 'local f=assert(loadfile("/home/e2e_v6.lua")) return f()' --wait 280
```

> **脱敏约定**：内网穿透域名/端口**不写进任何入库文件**。
> `tools/oc_deploy.py` 与 `tools/pull_session_hex.py` 的 `--base` 默认值均为
> `os.environ.get("OC_REMOTE_BASE", "")`（空则须显式传参），
> 与 `.oc-remote-token` 一样受 `.gitignore` 保护。

**注意两个机器的区别**：`--lua` 在**游戏机**上执行；`h:exec(...)` 在**机器人**上执行。
`h:write(path, ...)` 写的是**机器人**的文件系统——不要把游戏机要的文件推错机器。

## 5. 架构要点（为什么是这个样子）

- **唯一守护**：v6（8100）。不再有 v5。**原因**：v5 是 v6 的严格子集且更弱
  （exec 7680B 截断、无流分离、无 cancel、write ≤6000B、无消息 ID），
  且与 v6 同机/同 modem/同 VM/同事件队列——**无独立故障域，不构成冗余**
  （真机实证两者被同一个 wedge 一起弄死）。
- **守护必须以 detached 线程运行**：`thread.create(fn):detach()`。
  理由有二：① 线程是创建者进程的句柄，创建者退出时会 `join` 它
  （`lib/thread.lua:121`，超时 `math.huge`）→ 不 detach 则创建者**永久阻塞**
  （本项目的真实事故根因）；② `detach()` 把线程重挂到 init 进程，
  使唤醒 handler 路由进**共享 ROOT 表**——否则守护"生来即死却仍打印健康横幅"。
- **事件模型**：全机单信号队列，靠 `dequeue()` 分发 → **原生 puller 之间
  winner-take-all**（不是 ~50/50）；而 `thread.create` 线程是**注册消费者**
  （先消费后广播），**不饿死兄弟线程**。
- **autostart = rc 服务**（`/etc/rc.d/remoted.lua`），每次启动恰好一次、
  headless 安全。`.shrc` 只作二级保险（仅交互 shell source）。
- **泵**：无人打字也有泵——`boot/03_io.lua:14` 强制 `stdin.tty=true`，
  `tty.lua:10` `blink=true`，故 shell 读输入时 `cursor.lua:246` 以
  `pullSignal(.5)` 持续 park 原生 pull（2Hz）。

## 6. 关键坑（写代码前必读，详见 `docs/REMOTE_PROTOCOL.md` §8）

- **`computer.sleep` 是 nil**，但 **`os.sleep(n)` 可用**且是墙钟 + `event.pull`
  实现（`boot/02_os.lua:25-31`）——等待用 `os.sleep(n)`，别手写循环。
- **绝不在 console 前台启动长驻守护**：OpenOS 无作业控制（无 `&`），守护主循环
  永不返回，`shell.execute` 跑到子进程结束 → **console 被占死到重启**。
  一律经 `start_all.lua` 或 rc 拉起。
- **勿只改调用方端口变量起第二实例**——被加载脚本硬编码自己的 `PORT`，
  那样会在**同端口**多起一个实例（重复帧，实测单 ping 收 2 条回复）。
  要换端口必须替换**被加载脚本**的端口常量（`start_rh2.lua` 的做法）。
- **两实例并存时不可同时跑 exec/write**：二者共享 `/home` 与同一 sender，
  `rh_out|err|wt_<sender>_<id>` 路径相同，且各自 `startup_cleanup()` 启动时
  删除**所有** `/home/rh_*` → 互删在飞文件。**只可交替 ping**（ping 不落临时文件）。
- **`computer.shutdown(true)` 是远程重启杠杆**（`boot.lua:15-22` →
  `machine.lua:1408`）——可脱困被占死的 console，**前提是 autostart 已就位**，
  否则重启后无通道、须人工 console 介入。
- `filesystem.spaceTotal`/`spaceUsed`/`move` 不存在；`fs.copy/rename/exists/get` 存在。
- **lua 脚本崩溃 ≠ shell.execute 失败**：`lua` 包装器内 pcall → shell 层 `code=0`，
  崩溃行只在输出文本里。**code=0 ≠ 脚本成功**。
- OpenOS `lua` 包装器**不支持 `-e`**：内联代码须先写文件再 `lua <path>`。

## 7. 恢复流程（机器人失联时）

1. `h:ping()`（8100）`offline=true` → 机器人掉电/暂停/超距/守护崩。
2. 用户侧：充电/确认世界运行/靠近 modem 范围。
3. **人工 console**（机器人屏幕键盘）：
   ```
   reboot
   ```
   重启后（若 autostart 完好，其实不需要手动）：
   ```
   lua /home/start_all.lua
   ```
   **只跑这一条**——它把 v6 起为 detached 线程后立即返回，不占 console。
   （软盘也有 `start_all.lua` 与 `remote_host.lua`，冷恢复不依赖 `/home` 存活。）
4. 文件不丢：磁盘与软盘均有 v6 服务器。

## 8. 待办 / 可继续的方向

1. **提交本次改动**（若尚未提交）：v5 删除 + v6-only 客户端 + 文档。见 `git status`。
2. **软盘摆渡验证**：机器人软盘 `3e9` 现为 `remote_host.lua` + `start_all.lua`，
   已删 v5。若机器人 `/home` 丢失，可从软盘恢复（`lua /mnt/3e9/start_all.lua`）。
   注意软盘上的 `start_all.lua` 指向 `/home/remote_host.lua`——`/home` 丢失时需
   先拷回，或临时改路径。**此路径尚未真机演练过**。
3. **`start_rh2.lua`（8101 热升级桥）尚未在真机演练**——需要时按 `RESCUE.md`
   的闸门走（只交替 ping，验证双 40/40 后再动 8100）。
4. **可选**：`docs/REMOTE_PROTOCOL.md` §3 的 Phase 3（把 subagent 协议
   9090/9091/9092 收编进 v6）仍未做。

## 9. 用户偏好/约定（继承自历史会话）

- 垂类断言须标来源（源码/git/真机/记忆），无版本语境视为未验证。
- 真机实测与文档冲突 → 以实测为准并更新文档。
- clone 参考仓库遇 IP 封禁 → 直接问用户（勿自行找镜像/代理）。
- 推真机的文件必须同时提交本仓库（`update.lua` 下次 tag 更新会覆盖未提交改动）。
- 大动作（协议变更、部署、重启）先给用户方案再执行；用户逐阶段批准制。
- **项目仍在开发中，无需为兼容性保留旧接口**（owner 2026-09-14 明确）。
