# legacy_probes — v5 时代探针脚本的 v6 适配版

真机 `/home` 上遗留的 13 个自研探针脚本（`scan/dirt*/cln*/verify*/e2e/pr/probe_run/big2/placedirt`）。
它们由用户早期编写，**不属于 agent.lua 产物** —— `oc-remote` 技能明确记录"只报告勿删"。

## 为什么需要适配

2026-09-14 v5 一次性协议（端口 8001）整体退役后，这些脚本的**样板层**两处致命失效：

1. 直连 modem 打 **8001** —— 该端口已无人监听（实测 0/10 应答）。
2. deadline 用 **`os.clock()`** —— 线程挂在 `event.pull` 期间 CPU 时间不推进，
   deadline 永不触发（实测：15.25s 墙钟内 `os.clock` 仅走 0.047s）。

两者的业务逻辑（探测机器人物品栏/放置泥土/校验文件）本身没有问题，
坏掉的只是样板层。

## 适配方式

`tools/retrofit_v5_scripts.py` 精确删除**两块**样板并替换为一行 shim 调用：

- 块 A = `local c = require("component")` … `recv_reply` 的 `end`
- 块 B = `local function cmd(...)` … 它的 `end`

**关键**：脚本自己要用的 `local log = io.open(...)` / `local function lg(...)`
恰好夹在 A、B 之间，**必须保留**（早期版本整片删除会把它们误删 → 13 个脚本全崩）。

`v5shim.lua`（部署到真机 `/home/v5shim.lua`）把 `cmd("op|args")` 翻译成 v6 调用，
并把结果还原成 v5 的 `"ok|<data>"` / `"err|<msg>"` 字符串 —— **业务逻辑与解析代码零改动**。

支持的 op（语义逐条对齐 `remote_debug.lua` @b36fdf70 = `_reference_v5_server.lua`）：
`ping` / `info` / `exec|` / `read|` / `write|` / `delete|`。

## 与 v5 的刻意差异

| 项 | v5 | 本适配版 |
|---|---|---|
| 回复长度 | 截断 @7680B + `...[TRUNCATED]` | **不截断**（v6 流式；实测 20KB 完整读回） |
| exec 中间文件 | `/home/exec_out_<time>_<rand>`（会泄漏） | 无（v6 自己流式捕获） |
| exec 失败 | v5.2.2 起附 `\| output: ...` | 同（附已捕获输出） |
| 空输出 / 空文件 | `ok\|(no output)` / `ok\|(empty file)` | 同 |

## 真机验证（2026-09-15）

- shim 全 op 实测：`ping`→`ok|pong`、`info`→含 `pd=6.0`、空输出→`ok|(no output)`、
  空文件→`ok|(empty file)`、20KB 读回完整无截断标记、write/read/delete 往返含中文无损。
- `e2e.lua` 端到端跑通（输出 v5 格式）。
- `dirt.lua` 端到端跑通：写探针 → exec → 读回物品栏，得 `DIRT_SLOTS: 1=1`（功能恢复）。
- 13/13 部署后 `shim=true`、`osclock=false`、字节数与本地一致。
- 部署前已把真机原始版本备份到 `/home/v5legacy_bak/`（13/13，校验零差异）。

## 目录内容

- `*.lua` — 13 个适配版脚本（部署到真机 `/home/<name>.lua`）
- `v5shim.lua` — 兼容层（部署到真机 `/home/v5shim.lua`）
- `_reference_v5_server.lua` — v5.2.2 服务器原文（`git show b36fdf70:remote_debug/remote_debug.lua`），
  作为回复格式的权威依据留档
- 生成工具：`tools/retrofit_v5_scripts.py`

## 还原

真机原始版本在 `/home/v5legacy_bak/`。回滚：
`cp /home/v5legacy_bak/<name>.lua /home/<name>.lua`（注意原始版本依赖 8001，回滚后仍不可用）。
