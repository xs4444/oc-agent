# 游戏内局域网远控协议（remote_debug v5.x → v6 "OC-SSH"）

2026-09-14 起。目标：把"一次一指令"的 ad-hoc modem 协议升级为带完整语义的
远控协议（仿 ssh 的**语义**而非传输层），消灭"信息歧义导致 agent 困惑循环"
这一类 bug。

## 1. 背景：两次事故的实证教训

**事故 A（2026-09-14，会话 162903596.4 尾部 doom-loop）**：主控侧 LLM 探针脚本
用 `pairs(comp)` 迭代 component 表——实测（c114，真机 OpenOS）`pairs(comp)`
返回 22 个 `(方法名=function)` 对而非 `(地址=类型)`（正确 API 是
`component.list()`）→ `table.sort` 比较 function 崩溃 → `io.open("w")` 已创建
空文件但首行写入未执行 → 每轮探针都留空 `/home/probe_out.txt` → 旧 exec 只
重定向 stdout，**崩溃信息（stderr）被协议吞掉** → 主控侧只看到 `EXEC: ok|`
空载荷 → 10 轮困惑循环触发 doom-loop 护栏。

**事故 B（2026-09-14，机器人没电）**：机器人能量耗尽 → 电脑关机（OC 源码
`Machine.scala:213` 无能量时 `crash("gui.Error.NoEnergy")`）→ modem 完全静默 →
主控侧探测（c110）用 `os.clock()`（CPU 时间）做等待 deadline——等回复时线程
挂起、CPU 时间不走 → deadline 永不触发 → 探测线程永久挂起（世界重载前不清）。
**静默本身没有被协议表达**："没电"对主控侧不可见。

结论：裸 request/reply 协议 + 每次由 LLM 现场生成客户端框架代码 = 歧义 bug
反复出现。需要稳定客户端库（结构化结果）+ 完整服务器语义（流分离/显式离线/
分块传输）。

## 2. 硬约束（均有实证，改动前先核对）

| 约束 | 实证来源 |
|---|---|
| 无线 modem 单包 ≤ 8192B，超过 `modem.send` 抛错 | `src/agent/subagent.lua`（v0.3.92 FILE_REPLY_MAX=8192-512） |
| modem 消息可靠、有序、消息制（无需 TCP 重传/排序） | OC modem 语义 + subagent 分块传输真机数日健康 |
| 机器 Lua 5.3，机器人 totalMem=1048576（1MB） | v5.2 `info` 实测（2026-09-14） |
| 主机消失（断电）只能靠超时发现 → **deadline 必须墙钟** `computer.uptime()`；`os.clock()` 是 CPU 时间，等待期间不走 | `src/agent/http.lua` v0.3.88/v0.3.99 注释 + 事故 B（c110 挂起） |
| OC JSON 解析 bug → 纯文本协议 + `\|` 转义 | `remote_debug.lua` v5.0→v5.1 变更史 |
| OpenOS shell 支持 `2> file` / `2>&1`（io-to-io 复制） | `loot/openos/lib/core/full_sh.lua:42,86-98` |
| `shell.execute` 只返回 `(ok, err)`，无真 exit code | OC shell API |
| OC API 漂移：`fs.delete`→`fs.remove`；`robot.direction()` 新版不存在；`pairs(comp)`≠组件迭代 | 本次真机实测（c114）+ `full_filesystem.lua:241` |
| 共享内存小（机器人 1MB / 主控曾 2MB OOM）→ 服务器缓冲必须小 | 第四次 OOM（gist 59379f） |
| `lua` 包装器对任何 `os.exit()` 向 stderr 打 `terminated` | `loot/openos/bin/lua.lua:23-26` |

## 3. 阶段计划

- **Phase 0（已完成 2026-09-14）**：`remote_debug.lua` v5.2 语义修复——
  exec 失败走 err 信封（旧 `ok|Error: nil`）；空载荷永不出现（`ok|(no output)`
  / `ok|(empty file)`）；`write`/`delete` 加 `remote: ` 前缀；exec 追加
  `2>&1` 捕获 stderr；`fs.remove or fs.delete` 跨版本。+ 主控 agent
  `http.get` 一等导出（v0.3.127）。
- **Phase 1（本文档交付）**：主控侧 `remote_client/remote_client.lua` 客户端
  库——包装现有 v5.2 一次性协议，提供结构化结果（`{ok, code, out, err,
  offline, truncated}`）+ 全墙钟超时 + 显式 `offline`。机器人侧不动（继续
  跑 v5.2）。**LLM 以后只写 `h:exec(...)`，不再现场发明 modem 框架代码。**
- **Phase 2**：`remote_host.lua` 服务器（v6 协议）——消息 ID 多路复用、
  流式 exec（out/err 分块）、分块文件传输 + 校验、keepalive、auth token。
  客户端获得真"ssh 化"体验（流式输出、大文件传输）。
- **Phase 3（可选）**：subagent 协议（9090/9091/9092，`src/agent/subagent.lua`）
  收编进 v6 channel，消掉两套并行 modem 协议。

## 4. v6 协议规范（Phase 2 目标，先定稿防返工）

- **端口 8100**（8001=v5.x 保留兼容；9090/9091/9092=subagent）。
- **信封**：纯文本 `v6|<id>|<op>|<payload...>`；`id` = 客户端单调递增整数；
  **每条回复回显 id**（客户端按 id 分流，多路复用的基础）；`|` 转义规则同
  v5.2 write（`\\`、`\|`）。
- **ops**：
  - `ping` → `v6|id|pong|ok`
  - `info` → `v6|id|info|ok|id=..|uptime=..|freeMem=..|totalMem=..|components=..|oc=<version>`
    （`require("opencomputers").version()`——把 OC 版本写进 info，API 漂移
    可诊断）
  - `exec|<cmd>` → 服务器跑 `cmd > /home/rh_out_<id> 2> /home/rh_err_<id>`
    （真流分离）→ 若干 `v6|id|exec_chunk|ok|out|<≤7000B>` +
    `v6|id|exec_chunk|ok|err|<≤7000B>` + 终帧
    `v6|id|exec_done|ok|code=<0|1>`（0=shell.execute 成功；OC 无真 exit
    code，语义限 0/1）；异常 → `v6|id|exec_done|err|<reason>`
  - `read|<path>` → `v6|id|file_chunk|ok|<≤7000B>`* +
    `v6|id|file_done|ok|size=<n>`；不存在 → `v6|id|file_done|err|cannot open <path>`
  - `write|<path>|<size>` → 客户端续发 `v6|id|write_chunk|<seq>|<≤7000B>`*；
    服务器写临时文件 `/home/rh_wt_<id>`，收满 size 字节 → rename →
    `v6|id|write_done|ok|remote: <n> bytes written to <path>`；缺口/超时 →
    删临时文件 + `v6|id|write_done|err|write aborted (incomplete)`
  - `delete|<path>` → `v6|id|delete|ok|remote: deleted <path>`
- **并发上限**：同时 4 个文件传输（1MB RAM 约束）。
- **auth（v6.1）**：连接后首条 `v6|0|auth|<token>`；token 存服务器文件头部
  常量（空=关闭，启动时打印告警）。当前协议零认证——modem 覆盖范围内任何
  机器都能发 exec，v6.1 前按可信域使用。
- **keepalive**：客户端空闲期每 10s 发 ping；连续 3 次无回复 → `h.alive=false`，
  后续 op 直接返回 `{ok=false, offline=true, err="REMOTE_OFFLINE"}`（不再干等
  超时）。服务器侧无需动作（事件循环等消息即可）。
- **超时预算（客户端，全墙钟 `computer.uptime()`）**：ping 5s；exec 默认 120s
  （单次调用可覆盖）；文件块间隙 10s（gap=断连，立即 abort，不等总超时）；
  write 总量 300s。

## 5. Phase 1 客户端 API（`remote_client/remote_client.lua`）

服务器兼容 remote_debug v5.2（一次性 op|args → `ok|data`/`err|msg`，
REPLY_MAX=7680B）。部署：主控机 `/home/remote_client.lua`，
`local remote = dofile("/home/remote_client.lua")`。

```lua
local h = remote.connect(remote_addr, {port=8001, op_timeout=30})
h:ping()  → {ok=true} | {ok=false, offline=true}
h:info()  → {ok=true, info="id=..|uptime=..|..."}
h:exec(cmd, timeout_s?) → {ok=true, code=0, out=..., truncated=false}
                        | {ok=false, code=1, err=...}
                        | {ok=false, offline=true, err="REMOTE_OFFLINE (no reply within Ns)"}
h:read(path) → {ok=true, content=..., size=n} | {ok=false, err="cannot open .."} | offline
h:write(path, content) → {ok=true, bytes=n}   -- v5.2 一次性写 ≤6000B；更大报"用 v6"
h:delete(path) → {ok=true} | {ok=false, err=...}
h:close()
```

规则：所有等待 = `event.pull(0.25)` 循环 + `computer.uptime()` deadline
（**禁用 `os.clock()`**）；无回复 → `offline=true`（显式，不是 nil）；
回复尾部 `...[TRUNCATED]`（v5.2 REPLY_MAX 标记）→ `truncated=true`。

## 6. 端口与部署

| 端口 | 用途 |
|---|---|
| 8001 | remote_debug v5.x（一次性 op 协议） |
| 8100 | v6 remote_host（Phase 2） |
| 9090/9091/9092 | subagent（任务/回复/文件代理，Phase 3 收编） |

部署路径：机器人侧文件走软盘摆渡（机器人无 modem 写自身能力之外的通道）；
主控侧文件可直接经 `tools/remote_server.py --lua` 写入（hex 分块 + 回读校验 +
现场 `loadfile`）。推真机的文件必须提交本仓库（AGENTS.md）。

## 7. OC 实测坑清单（append-only，写探针/客户端代码前过一遍）

1. `os.clock()` 做 deadline → 等待期间 CPU 时间不走 → 永不触发。用
   `computer.uptime()`（墙钟）。
2. `fs.delete` 在新版 OpenOS 是 `fs.remove`。写 `fs.remove or fs.delete`。
3. `pairs(comp)` 返回 `(方法名=function)`，不是组件迭代。用 `component.list()`。
4. modem 单包 8192B；大载荷必须分块。
5. JSON 解析有 bug；纯文本 + 转义。
6. `robot.direction()` 新版 OC 不存在。
7. `lua script.lua` 里任何 `os.exit()`（含 0/true）→ stderr 打 `terminated`，
   不是"被杀"。
8. `(no output)` = 命令无输出，不是失败（agent shell 工具约定）。
9. 空回复 ≠ 成功：v5.2 起空载荷有显式标记；v5.0/v5.1 的 `ok|` 空载荷一律
   按"未知"处理。
