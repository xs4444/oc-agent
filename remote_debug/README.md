# 无线远程调试（agent 自制）

在**目标 bot**（有 modem 的机器）上运行的纯文本 modem 调试程序，主控机通过 modem 端口 `8001` 发 `op|param1|param2` 指令（`ping`/`info`/`exec`/`read`/`write`/`delete`），接收返回。刻意用纯文本协议（避免 OC 的 JSON 解析 bug）。

**关键修复**：modem_message 事件参数顺序——`sig[3]`=远程地址、`sig[4]`=端口、`sig[6]`=数据。旧版误用 `b==port`（b 实为远程地址）→ 永远不回复。

| 文件 | 用途 |
|------|------|
| `remote_debug.lua` | 主程序（v5.1，端口 8001，REPLY_MAX=7680B） |
| `listen.lua` | 简化 PING/PONG 监听（同端口，验证 modem 收发） |

来源：真机 3e9 盘 `/mnt/3e9/`（2026-09 拉入仓库）。
