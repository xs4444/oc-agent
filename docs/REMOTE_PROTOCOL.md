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

**事故 B 的源码全链路（2026-09-14 补钉，`repos/opencomputers` 实证）**：
1. OC 网络层**确实会广播对端停机**：`Machine.tryClose()`（`Machine.scala:581/935`）
   → `node.sendToReachable("computer.stopped")`。
2. 但接收端 `NetworkCard.onMessage`（`NetworkCard.scala:142`）对
   `computer.stopped`/`computer.started` 只做内部 `openPorts.clear()`，
   **不转成 Lua 可见信号**——只有 `network.message` 包经
   `WakeMessageAware.receivePacket` → `computer.signal("modem_message", ...)`
   才会到 `event.pull()`。**即：agent 的 Lua 永远看不到 `computer.stopped`，
   掉电在协议层只能靠超时发现。**
3. 机器人侧**没有预报警通道**：本版本 Lua 无 `computer.onCrash` 钩子
   （全树 grep 空）；`robot.level()`（`robot/lib/robot.lua:13`）是
   **experience 组件的经验等级**，不是电量——机器人方法表无任何能量 API。
   掉电瞬间整机（含 remote_debug 守护）一起死，连"再见"消息都发不出。
4. 结论：**"静默"至少四种含义**（没电/超距/世界暂停/守护崩溃），keepalive
   是协议层必需品而非优化项（§4）——平台信号不可见，必须自建心跳。

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
| 掉电广播 `computer.stopped` 对 Lua 不可见 → 离线只能靠协议层心跳/超时 | `Machine.scala:581/935` `sendToReachable("computer.stopped")` 被 `NetworkCard.scala:142` 内部消费（仅 `openPorts.clear()`）；`robot.level()`=经验等级非电量；本版本无 `computer.onCrash` 钩子 |

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
- **Phase 2（已完成 2026-09-14）**：`remote_host.lua` 服务器（v6 协议）——消息 ID 多路复用、
  流式 exec（out/err 分块）、分块文件传输 + 校验、keepalive、auth token。
  客户端获得真"ssh 化"体验（流式输出、大文件传输）。
  v6.0 已实现、已部署、真机验收通过（PASS 11/11，§4）。
- **Phase 3（可选）**：subagent 协议（9090/9091/9092，`src/agent/subagent.lua`）
  收编进 v6 channel，消掉两套并行 modem 协议。

## 4. v6 协议规范（v6.0 已实现 + 真机验收通过）

状态（真机，2026-09-14）：v6.0 已实现（`remote_debug/remote_host.lua`，
16164 字节，与部署的 `/home/remote_host.lua` 逐字节一致）、已部署、已验收——
`/home/e2e_v6.lua` 报告 `PASS 11/11 | ALL GREEN`（T1 ping、T2 info pd=6.0、
T3 exec 简单、T4 exec 大输出、T5 exec 管道、T6 exec 失败、T7 write+read 小、
T8 write+read 大（50KB）、T9 delete、T10 offline、T11 cancel）。以下规范与
实现一致；唯一偏差是 `info` 的 `oc=` 字段（见下）。

- **端口 8100**（8001=v5.x 保留兼容；9090/9091/9092=subagent）。
- **信封**：纯文本 `v6|<id>|<op>|<payload...>`；`id` = 客户端单调递增整数；
  **每条回复回显 id**（客户端按 id 分流，多路复用的基础）；`|` 转义规则同
  v5.2 write（`\\`、`\|`）。
- **ops**：
  - `ping` → `v6|id|pong|ok`
  - `info` → `v6|id|info|ok|id=..|uptime=..|freeMem=..|totalMem=..|components=..|pd=6.0`
    （实际实现 `remote_debug/remote_host.lua:353-365` `get_info_payload()`，
    止于 `pd=6.0`，**无 `oc=` 字段**：`require("opencomputers")` 真机不可用
    （`oc_require=false`），`oc=<version>` 未实现）
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
  - `cancel|<id>` → 服务器杀掉指定 id 的 exec 线程（thread.kill）+ 清理
    临时文件，回 `v6|<id>|cancel|ok|cancelled`（对照 ssh `signal` 通道
    请求 + `exit-signal` 帧，`session.c:2350`——Phase 1 无 cancel，超时
    的 exec 会占住机器人单核继续跑）
- **并发上限**：同时 4 个文件传输（1MB RAM 约束）。
- **auth（v6.1）**：连接后首条 `v6|0|auth|<token>`；token 存服务器文件头部
  常量（空=关闭，启动时打印告警）。当前协议零认证——modem 覆盖范围内任何
  机器都能发 exec，v6.1 前按可信域使用。
- **keepalive（必需品，非优化项）**：客户端空闲期每 10s 发 ping；连续 3 次无回复
  → `h.alive=false`，后续 op 直接返回 `{ok=false, offline=true,
  err="REMOTE_OFFLINE"}`（不再干等超时）。服务器侧无需动作（事件循环等消息
  即可）。**必须自建的原因**（事故 B 源码链路，§1）：OC 的
  `computer.stopped` 网络广播被 `NetworkCard.onMessage` 内部消费
  （`openPorts.clear()`），Lua 侧不可见；机器人又无电量 API / onCrash 钩子
  可预报警——"没电"对 agent 只能表现为静默，心跳是唯一的显式离线判据。
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
h:info()  → {ok=true, info="id=..|uptime=..|..|pd=<版本>", pd=<版本?>}
          -- pd 由 v5.2.2+ 服务器提供 (协议版本); 客户端缓存供管道守卫用
h:exec(cmd, timeout_s?) → {ok=true, code=0, out=..., truncated=false}
                        | {ok=false, code=1, err=...}
                        | {ok=false, offline=true, err="REMOTE_OFFLINE (no reply within Ns)"}
          -- cmd 含 shell 管道 '|': 仅 pd≥5.2.1 放行, 否则显式报错
h:read(path) → {ok=true, content=..., size=n} | {ok=false, err="cannot open .."} | offline
h:write(path, content) → {ok=true, bytes=n}   -- v5.2 一次性写 ≤6000B；更大报"用 v6"
h:delete(path) → {ok=true} | {ok=false, err=...}
h:close()
```

规则：所有等待 = `event.pull(0.25)` 循环 + `computer.uptime()` deadline
（**禁用 `os.clock()`**）；无回复 → `offline=true`（显式，不是 nil）；
回复尾部 `...[TRUNCATED]`（v5.2 REPLY_MAX 标记）→ `truncated=true`。
超时后的下一个 op 先排空 2s 内滞留的旧回复（`drain_stale`——一次性协议
无消息 ID，迟到的旧回复会被误配给新 op；ssh 用通道 ID 序号根治，v6
同理）。

## 6. Phase 1 已知限制（2026-09-14 对照 OpenSSH 源码逐条核对）

核对基准：`repos/openssh-portable`（openssh/openssh-portable 浅克隆，
2026-09-14）。

| Phase 1 行为 | ssh 对应（源码位置） | 结论 |
|---|---|---|
| exec 终态 `code=0|1` | `session.c:2344` `exit-status` 通道请求（u32 exit code）；信号终止走独立 `exit-signal` 帧（`session.c:2350`，含信号名/coredump/备注） | ✓ 正确简化：OC 无真 exit code/信号，0/1 + err 终帧覆盖 exit-status 与 exit-signal 两帧的语义。**注意**：`lua` 脚本崩溃被包装器内吞 → `code=0` 且崩溃行在 `out` 里（§8-12）——code 只是 shell 层信号，脚本成败看输出文本 |
| exec 失败附已捕获输出（v5.2.2 服务器，待软盘摆渡） | ssh 流数据先于 exit-status 帧到达（`session.c:2344` 之前的 channel data 帧） | ✓ `err\|exec failed: <err> \| output: <2>&1 捕获内容>`，客户端透传为 `r.err`——此前失败只回 `exec failed: nil`，崩溃行被丢弃 |
| 无回复 → 显式 `offline=true` | `serverloop.c:112` `client_alive_check()`：alive 超时次数 > `client_alive_count_max` → 断连；探测=全局请求 `keepalive@openssh.com`（server→client 方向） | ✓ 语义一致；方向相反（client→server）——OC 里两台机器都可能断电，需要的方向恰是客户端探服务器 |
| `truncated=true`（服务器 7680B 截断） | ssh 全量流式，无截断 | OC 8192B 单包约束下的文档化扩展 |
| write ≤6000B + 服务端解码校验 | scp/sarchive：按文件 size 校验（`scp.c` 进度/汇总按 `st_size` 计） | ✓ 同构（先声明 size、收满才落盘；坏载荷 → `err|decode failed`） |
| 串行 request/response（无多路复用） | `channels.c` 单连接多通道（window/maxpack 按通道独立） | 已知限制 → v6 消息 ID（已实现，§4） |
| 运行中 exec 无 cancel | `signal` 通道请求 + `exit-signal`（`session.c:2350`） | 已知限制 → v6 `cancel|<id>`（§4）；Phase 1 超时的 exec 继续占机器人单核 |
| 零认证 | `auth2.c` 恒认证 | 已知限制 → v6.1 auth token（当前按可信域使用，§4 已注） |
| 迟到旧回复可能错配新 op | 通道 ID + 序号 | Phase 1 缓解：`drain_stale`（超时后下个 op 前排空 2s）；超 grace 仍会错配 → v6 根治 |
| exec 输出合流（`2>&1`） | ssh stdout/stderr 双流独立传回 | Phase 1 目的是捕获崩溃信息（v5.2.1 `2>&1`）；真流分离 = v6 `2> file` 双文件 |
| 大输出截断而非流式回传 | ssh 边产生边传（窗口流控） | v6 `exec_chunk*` 流式（§4） |

## 7. 端口与部署

| 端口 | 用途 |
|---|---|
| 8001 | remote_debug v5.x（一次性 op 协议） |
| 8100 | v6 remote_host（已实现 + 真机验收，§4） |
| 9090/9091/9092 | subagent（任务/回复/文件代理，Phase 3 收编） |

部署路径：机器人侧文件走软盘摆渡（机器人无 modem 写自身能力之外的通道）；
主控侧文件可直接经 `tools/remote_server.py --lua` 写入（hex 分块 + 回读校验 +
现场 `loadfile`）。推真机的文件必须提交本仓库（AGENTS.md）。

实际部署状态（真机，2026-09-14）：v6 服务器在机器人 `/home/remote_host.lua`
（16164 字节，与本仓库 `remote_debug/remote_host.lua` 逐字节一致），**不在软盘**；
软盘 `/mnt/3e9/remote_debug.lua` 是 v5.2.2（已验证），`/mnt/3e9/remote_host.lua`
不存在。

## 8. OC 实测坑清单（append-only，写探针/客户端代码前过一遍）

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
10. 掉电 = 永久静默，且**平台不给 Lua 看**：`computer.stopped` 广播被
    `NetworkCard` 内部消费（`openPorts.clear()`）；`robot.level()` 是经验
    等级不是电量；无 `computer.onCrash` 钩子。远端死活只能靠协议层
    keepalive/墙钟超时判（§1 事故 B 源码链路）。
11. OpenOS `lua` 包装器**不支持 `-e`**（`bin/lua.lua:9` 恒把 `args[1]` 当
    文件名）——内联代码须先写脚本文件再 `lua <path>`。
12. **`lua` 脚本崩溃 ≠ shell.execute 失败**：包装器内部 pcall + 崩溃行打
    stderr + `os.exit(false)`（`bin/lua.lua:23-27`），shell 层仍回
    `ok2=true` → exec `code=0`。**code=0 ≠ 脚本成功；输出文本里的崩溃行
    （如 "attempt to compare table with function"）才是真相**（2026-09-14
    真机实测：复现 pairs(comp)+table.sort 事故 → code=0 + out 带崩溃行 +
    空残留文件，三要素与事故 A 完全一致）。v5.2.2 的 2>&1 + 附输出正是
    为此存在——v5.0/v5.1 丢弃 stderr 时该崩溃行根本到不了主控侧。
13. **事件抢占：抢的是"原生 puller"，不是"第二个事件循环"**（真机 + 源码，2026-09-14）：
    机器级信号队列是单队列（`Machine.scala:372` `popSignal()` 做 `signals.dequeue()`），
    一个信号只被一个消费者取出。多个**原生** `event.pull`（普通进程：v5 守护、
    前台 `lua`）互相抢占 → **winner-take-all，非 ~50/50**（实测 port-8001 守护
    0/40、port-8100 守护 40/40，两端口同时 `isOpen=true`）。
    **`thread.create` 出的线程是"注册消费者"而非原生 puller**：其 `event.pull`
    是注册进 handlers 表的一次性唤醒处理器（`lib/thread.lua:209-218` `mt.register`），
    由执行原生 pull 的一方代为服务；分发"先消费后广播"（`lib/event.lua:54` 唯一
    消费，`event.lua:57-79` 同一 event_data 触发所有匹配 handler）→ **两个 thread
    守护互不饿死，各自都收到事件**（官方文档：注册 handler "unaffected by signal
    robbers"）。
    实测 0/40 的精确机制：卡死的 `start_rh.lua` 停在 `waitForDeath` 的无过滤
    `event.pull(deadline-uptime)`（`lib/thread.lua:41`），充当机器唯一原生泵 →
    消费并丢弃 8001 流量（无 v5 handler 匹配），**同时仍分发 ROOT handler 表**
    ——这正是 v6 thread 守护仍 40/40 的原因（v5 死 v6 活，非"两者对称竞争"）。
    端口不隔离信号队列：`openPorts` 是组件字段（`NetworkCard.scala:39`，机器级
    非进程级），端口只是接收过滤器（`NetworkCard.scala:150-158`）；`close()` 无参
    关全部端口，重启后端口清空须由守护重开——但两个 thread 守护在不同端口仍
    共存（注册消费者）。
14. **`thread.create` 出的守护不随创建者进程退出而存活**（真机 + 源码，2026-09-14）：
    父进程在 `join` 里永久阻塞（`lib/thread.lua:121` `self.close = self.join`；
    timeout `math.huge` 见 `thread.lua:13,94-96`；teardown 循环 `lib/process.lua:140-145`）
    ——创建者线程存活时父进程无法退出。故 v6 重启后消失（实测：重启后 port 8100
    CLOSED `isOpen(8100)=false` 而 8001 开且健康——v6 根本没在跑）。
    **修法 `t:detach()`**（`lib/thread.lua:102-104` → `attach(init_thread)`）：把句柄
    重挂到不朽的根 `/init.lua` 进程（`init.lua:17-26`），父进程可退出且线程存活到
    重启。
    **关键细节：`detach()` 不仅为创建者存活，更为 handler 路由**——`thread.create`
    给每个线程自己的私有 handler 集（`lib/thread.lua:206-207`
    `mt.process.data.handlers = {}`）；`detach()` 把 `mt.attached` 重挂到 init 进程，
    其 `data.handlers` **就是**共享 ROOT 表（`thread.lua:297`）。故由"本身是线程的
    创建者"spawn 的守护若**不 detach**，其唤醒注册进瞬态私有集 → **守护生来即死
    却仍打印健康启动横幅**。验证必须功能化（ping/exec），绝不看横幅。
15. **守护线程未处理错误 = 静默死通道**（源码，2026-09-14）：线程体里的未处理
    错误不会拖垮 init 进程或整机——`os.exit` 在 OpenOS 是纯 Lua 错误
    （`lib/core/full_filesystem.lua:349-350` `error({reason="terminated", code=code}, 0)`），
    被 pipe/dispatch 路径捕获（`thread.lua:157-192`、`pipe.lua:28-42`），分发器对每个
    回调都 `pcall`（`event.lua:72-74`）→ 记入 `/tmp/event.log`。真实危害是**服务
    停止应答且无明显症状**（静默死通道）。实践：每个线程体都 pcall 包裹；
    `/tmp/event.log` 是事后取证源。
16. **v6 无可用 autostart；正确机制是 rc 服务**（真机 + 源码，2026-09-14）：
    当前 `/home/.shrc` 是空文件，v6 重启后不自动起。本平台正确机制 = **rc 服务**：
    `/etc/rc.d/<name>.lua` 里定义全局 `function start()`，`rc <name> enable` 启用，
    由 `boot/89_rc.lua` 在 `init` 信号驱动 → `/bin/rc.lua`（配置 `/etc/rc.cfg`）。
    关键性质：**每次启动恰好跑一次**（区别于 `.shrc`/autorun）；**headless 安全**
    （无 shell/gpu/screen/keyboard 也起）；`start()` **必须尽快返回**——它在单一
    init 进程内执行，阻塞循环会卡住启动、shell 重生循环和所有其他进程。
    对照 `.shrc`：仅从交互分支 source（`bin/sh.lua:10-18` → `etc/profile.lua:41-43`），
    每次启动可能跑多次——不是可行的启动钩子。
    **未验证一环**：无人输入的机器人上，shell 的输入等待是否真的 park 一个原生
    pull（那个 parked pull 正是 thread 守护依赖的泵）——标记未验证，勿断言。
17. **`computer.sleep` 在机器人和游戏机上都是 NIL**（真机，2026-09-14）：
    `computer.sleep=nil`，`computer.uptime` 是函数。任何等待必须用墙钟循环
    `computer.uptime()` + `event.pull(0.1)`。
18. **`fs.spaceTotal` 在本 OpenOS 构建不存在**（真机，2026-09-14）：调用
    `filesystem.spaceTotal(...)` 抛 `attempt to call a nil value (field 'spaceTotal')`。
    `fs.spaceUsed`、`fs.move` 同样**不存在**（真机实测 `nil`）；存在的是
    `fs.copy`/`fs.rename`/`fs.exists`/`fs.get`。无 `fs.move` → 需流式拷贝
    （`remote_host.lua` 已如此实现）。
19. **`os.sleep` 存在且可用——修正第 17 条的读法**（真机 + 源码，2026-09-14）：
    第 17 条说"任何等待必须用墙钟循环"易被误读为必须手写循环。实测
    `os.sleep(1)` 精确等待 1.00s（`os.sleep_ok=true`）；源码
    `boot/02_os.lua:25-31` 的实现**正是**墙钟 + `event.pull`
    （`local deadline = computer.uptime() + timeout; repeat event.pull(...)
    until computer.uptime() >= deadline`）——即它已经是"让出式墙钟等待"。
    **结论：`computer.sleep` 是 nil，但 `os.sleep` 可用且等价于推荐的墙钟写法**；
    直接 `os.sleep(n)` 即可，不必手写循环。注意它内部走 `event.pull`，
    因此与其它原生 puller 同样存在抢占（第 13 条）。
20. **`computer.shutdown(reboot)` 是远程重启杠杆**（源码 + 真机，2026-09-14）：
    机器人上 `computer.shutdown` 存在（`boot.lua:15-22` 包装 → `machine.lua:1408`
    `coroutine.yield(not not reboot)`）；传真值即**重启**。真机 `component.methods`
    的 computer 全表为 `beep,getDeviceInfo,getProgramLocations,isRunning,start,stop`
    （**无** `stop`/`isRunning` 的 Lua 直通，但 `shutdown` 由 OpenOS 层提供）。
    **用途**：当机器人 console 已被前台守护占死（见第 21 条）而 modem 通道仍活时，
    可经远控触发重启脱困——**前提是机器人已有可用的 autostart**（rc 服务，
    第 16 条），否则重启后无通道，须人工 console 介入。
21. **前台启动常驻守护 = console 被占死到重启**（源码，2026-09-14）：
    OpenOS shell **无作业控制**（无 `&` 后台符，`full_sh.lua`/`sh.lua` 无 job
    control）；守护主循环 `while true do event.pull(0.5) ... end`
    （`remote_debug.lua:193`，仅 `"interrupted"` 退出）**永不返回**；而
    `shell.execute` 把子进程跑到结束（`lib/core/full_shell.lua:13-14`
    → `process.internal.continue`）。
    **故**：在 console 前台跑 `lua /mnt/3e9/remote_debug.lua` 或
    `lua /home/remote_host.lua` 会**永久占住 console**，操作员再也拿不到提示符
    ——这正是当前活体状态 console 阻塞的成因，也是历史恢复流程（交接文档 §8
    的"两条命令"）不可执行的原因。**正确做法**：一律经 detached 线程启动器
    （`remote_debug/start_all.lua`：`thread.create(fn):detach()` 后立即返回）
    或 rc 服务拉起；启动器本身在前台跑是安全的（它立即返回）。
