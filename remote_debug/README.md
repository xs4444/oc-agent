# 无线远程调试（agent 自制）

在**目标 bot**（有 modem 的机器）上运行的纯文本 modem 远控程序（v6 "OC-SSH"
协议），主控机通过 modem 端口 `8100` 发 `v6|<id>|<op>|<payload>` 指令
（`ping`/`info`/`exec`/`read`/`write`/`delete`/`cancel`/`auth`/`write_chunk`），
接收返回。刻意用纯文本协议（避免 OC 的 JSON 解析 bug）。v5（端口 8001）已于
2026-09-14 废弃（见 `docs/REMOTE_PROTOCOL.md` 状态节）。

**关键修复**：modem_message 事件参数顺序——`sig[3]`=远程地址、`sig[4]`=端口、
`sig[6]`=数据。旧版误用 `b==port`（b 实为远程地址）→ 永远不回复。

| 文件 | 用途 |
|------|------|
| `remote_host.lua` | v6 服务器（端口 8100，消息 ID 多路复用、流式 exec、分块读写、cancel） |
| `start_all.lua` | 冷启动入口：以 `thread.create(fn):detach()` 拉起 v6 守护（幂等，标记文件守卫） |
| `start_rh2.lua` | 可选验证桥：替换端口常量在 8101 起第二 v6 实例（热切换/升级前验证） |
| `rc.d_remoted.lua` | rc 服务内容（安装为 `/etc/rc.d/remoted.lua`，`rc remoted enable` 启用 autostart） |
| `RESCUE.md` | 救援运行手册（远控通道全失时的恢复路径） |
| `listen.lua` | 简化 PING/PONG 监听（验证 modem 收发） |

来源：真机 3e9 盘 `/mnt/3e9/`（2026-09 拉入仓库）；v6 服务器与启动器为
2026-09-14 新增。
