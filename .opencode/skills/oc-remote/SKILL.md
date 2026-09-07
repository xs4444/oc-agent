---
name: oc-remote
description: 远控 OC 真机（GTNH 服务器玩家计算机）与 ocvm 测试 VM 的远程通道全量操作手册。Triggers on "远控", "远程控制", "真机", "remote", "oc-remote", "公网通道", "frp 隧道", "real_machine_probe", "remote_server"。涵盖控制服务器（systemd + SakuraFrp 隧道）、CLI 全部 op、探针/电池测试、真机环境特征与 21 坑清单（含磁盘图/世界 ticking/容量写满语义/宿主 CPU 看门狗/
LLM 无 chunk 挂起/OC internet 4xx 异常语义）。
---

# OC 真机远程控制（oc-remote）

架构：真机 agent（v0.3.125 的 `agent/remote.lua` 守护，long-poll）↔ 控制服务器
（本机 systemd 用户服务）↔ 公网入口（SakuraFrp 隧道）。agent 只能主动外联，
世界必须 ticking。真机=GTNH 多人服务器上的玩家 OC 计算机，**玩家无文件/SSH 访问**，
此通道是唯一读写执行通道。

## 端点与凭据

| 项 | 值 |
|---|---|
| 公网端点 | `https://<server-endpoint>`（真实证书，无需 `-k`；国内节点 http 必 501，必须 https） |
| token | **43 字符，勿写进本仓库**（公开 GitHub）。位置：`~/.oc-remote-token.txt`、`~/.oc-remote-token.env`（OC_REMOTE_TOKEN）、工作区 `.oc-remote-token`（gitignored） |
| 控制服务器 | systemd 用户服务 `oc-remote-server`（Linger=yes，bind 127.0.0.1:8765，hold 12s，带 `--allow-emoji`） |
| frpc | docker 容器 `ocremote`（`--network=host --restart=always`，<frp-service>/frpc，隧道 id **<tunnel-id>**，node85 <frp-service>） |
| 隧道 API | `api.<frp-service>/v4`，Bearer key 见 sakurafrp-tunnel 技能/本机 `~/.frp` 配置；隧道配置变更走技能 `sakurafrp-tunnel` |

管理：
```bash
systemctl --user restart oc-remote-server   # / status / daemon-reload
journalctl --user -u oc-remote-server -n 50
docker logs ocremote --tail 20             # frpc 状态
```
`--allow-emoji` 是给**真机**（Java unicode 正确）开的；打 ocvm 目标时必须去掉
（ocvm C++ `unicode.cpp` 上游 bug 遇 4 字节字符原生崩溃）。开关 = 改 unit
ExecStart → daemon-reload → restart。

## 客户端 CLI（本机执行）

```bash
cd <repo-root>/aiProjects/mieAgent
TOK=$(cat .oc-remote-token)
BASE=https://<server-endpoint>
python3 tools/remote_server.py client --base $BASE --token "$TOK" \
  --status            # 在线/队列/hold/uptime/recent 20
  --ping | --exec 'ls /' | --lua 'return 1+1' \
  | --read PATH | --write PATH CONTENT | --list PATH
  # --timeout N 适用 exec/lua（默认 60s；服务器拒收多行 exec 与 413≈99.9KB）
```
批量：`python3 tools/real_machine_probe.py --base $BASE --token "$TOK" [--with-stress]`
（25 项真机体检）；`python3 test_harness/remote_battery_test.py --base $BASE --token "$TOK"`
（10 场景，含分页/并发/热重载）；`python3 test_harness/remote_pit_test.py`（39 用例，
仅本地 ocvm 用，默认 base 是 127.0.0.1:8765）。

## 真机环境特征（v0.3.125 实测，2026-09）

- 4MB / OpenOS 1.8.9；config `/home/agent_config.txt`（writable base=/home），
  model 字段 nil（纯远控无 LLM 回合）；/tmp 与 /home 均可写
- **OC Lua 无 `collectgarbage` 全局**（GC 宿主管理：Java 常开）；**无全局 `computer`**
  （要 `require("computer")`）；OC 1.7.10 component API **无 getType**
- 内存查询用 `computer.totalMemory()/freeMemory()`（`component.list("memory")()=0`
  两宿主皆空——memory 不在注册表）
- 出口网络通（frp 隧道外）；中文/emoji 全链路无损
- **出口可达性矩阵**（2026-09-07 lua op internet.request 电池实证）：
  | 端点 | 结果 |
  |---|---|
  | `https://github.com`(443) | **~25% 通**（SNI 级黑洞：DNS 正常、SYN 丢包；失败="Connection timed out: connect" ~21s 白等） |
  | `gist.github.com` / `raw.githubusercontent.com` | 0/8 |
  | `api.github.com` | **100% 通**（1.2s） |
  | `cdn.jsdelivr.net`（含 /gh/ 镜像） | ~100% 通（3.4-9.7s，**间歇 "Connection/Read timed out"**=GFW 抖动，分钟级重试可过） |
  | `http://github.com`(80) | 通（650ms） |
  | Cloudflare 系（worldtimeapi/httpbin/time.is） | 服务器出口封（重置/TLS 失败） |
  | 国内（time1.cloud.tencent.com） | TCP 超时 |
  定性=**443 SNI 级过滤**（api.github.com 与 github.com 同 IP 段 140.82.112.0/22 却通→非 IP 封锁）；
  DoH/QUIC 无效（过滤在 SNI 层）。update.lua 走 jsDelivr+api tags 不受影响
- **GitHub 抓取=A 自动改写 + B 取件柜**（v0.3.126r2, commit 4ac3efa）：
  - A: `web_fetch` 内建 `rewrite_github`——raw/gist/issues/pull URL 自动改道
    cdn.jsdelivr.net / api.github.com（结果加 "GFW rewrite: <url>" 前缀）；
    其余 HTML 页面无确定等价物→不改写直连（~25% 通）
  - B: `python3 tools/gh_fetch.py <url> [--name X]`——本机抓取（直连→gh-proxy.com
    镜像→Clash 7897）≤99KB→远控 op=write 推 `/home/cache/<name>`→agent read_file 本地
  - 第三方加速镜像（gh-proxy.com/ghfast.top/ghproxy.net 等 10 家 2026-09-07 预筛）：
    3 家活但**短寿命公共服务 70% 已死**+真机无法安全验证（见坑 22）→不作主力，
    只留作 gh_fetch 的中间 fallback
- **磁盘图**（df 实证）：`/`=OpenOS 根盘 4MB（**/home 在此**，余 ~1.8MB）；
  三驱动 `/mnt/857` 4MB 1%、`/mnt/bb7` 4MB 14%（**agent 多文件部署树
  /mnt/bb7/agent/**，入口 agent.lua ~119KB）、`/mnt/9ab` 2MB 41%；
  **`/tmp` 仅 64KB tmpfs**（fork `application.conf:918 tmpSize: 64`）——
  大文件写 /home 或 /mnt，别写 /tmp
- **agent 部署=多文件树**（非单文件）：改代码覆盖对应文件，然后用户游戏内重启 agent。
  上传法（**勿用 write op**——运行中 agent 内存里的 json 可能仍是 %c bug 旧版，
  含 0xB1 字节的长串会被静默损坏）：用 **lua op 长字符串直写**（code 字段
  decode 透明，r7b 实证）：`local f=io.open(P,"w") assert(f) f:write([==[内容]==]) f:close()`
  （内容含 `]==]` 时升级定界符）；**>100KB 线上限制的文件分块**：第 1 块 "w" 模式
  + 后续 "a" 追加（init.lua 119KB=3 块实证；Python 按 str 字符切分，多字节字符使
  字符数<字节数，拼接完整即可）——部署后一律读回 n/sum 校验
- LLM=用户自建 vLLM 端点（`<llm-endpoint>`，模型名
  **`Qwen3.8-27B`**（config 实证），ctx 128K）——与远控通道不同端口互不影响。
  **冷 prefill 可超 2 分钟**（用户 2026-09-07 确认"最长可以允许十五分钟"）：
  config 已设 `response_timeout=900`（代码默认同 900，commit 1e870fb）；
  与 300s 重试预算配合=单次最长 15 分钟、超时不重试；TUI "+Ns" 期间继续滚动，
  Ctrl+C 随时可杀
- **ocvm 测试 VM 的 LLM 端点已过期**（2026-09-07 用户未续费）：mimo-v2.5 @
  `opencode.ai/zen/go`（574 盘 config）——ocvm 上要跑 LLM 回归需先换端点
  （可用同一 vLLM 公网地址），纯远控回归不受影响
- 护栏空闲内存拒绝消息是中文：`空闲内存 X < NB（shell 执行护栏）`
- 错误判定=结构化 is_err（v0.3.125r3+：工具层直接返回布尔，`^Error` 前缀仅回退）——
  合法输出含 "Error:" 不误判
- `update.lua` 升级后**必须重启 agent**（旧进程不带新代码，护栏文案可暴露版本）
- **硬件清单**（components 实证）：eeprom、internet×1、keyboard/gpu/screen/computer、
  filesystem×5、disk_drive×1、**modem×2**；当前**无 GT 组件挂载**（BEC/LSC/energy
  驱动在模组里但没接硬件——接上后 agent 可直接 component.invoke 操作 GT 机器）
- **`date` = 游戏内时间**（MC 世界钟，OSAPI.scala：os.time/os.date 都基于
  machine.worldTime，1976 年那种）。**真实时间=`realtime` 命令**（仓库
  `tools/realtime.lua`→真机 `/home/bin/realtime.lua`，PATH 默认含 /home/bin）：
  `realtime`/`realtime -u`(UTC)，经 timeapi.io https 取宿主侧墙钟（~1.1s，
  真机 Java TLS 对 Let's Encrypt 正常）。出口画像：Cloudflare 系被服务器出口封
  （worldtimeapi/httpbin 连接重置、time.is TLS 握手失败）、国内端点 TCP 超时
  （time1.cloud.tencent.com）、个别域名 DNS 失败。`os.date(fmt, epoch)` 的第二参数
  是**真 UNIX 时间戳格式化器**（1780000000→2026-05-28 精确）——拿到 epoch 可本地格式化
- **`head` 只认 `--lines=N`**：`head -40` 被 shell.parse 拆成短选项 {4,0}→usage 分支
  `print()` 写 TTY（游戏内屏幕）+`os.exit(1)`→管道捕获为空 "(no output)"（坑 17 放大器）。
  真机实证：`ls X` 单独 56 行全捕获、`ls X | head -40` 空、`ls X | head --lines=40` 正常。
  游戏内 agent 曾把此现象误诊为"ls 输出异常"——管道命令空输出先查**下游**命令。
- **`grep` 是 Wobbo 移植=Lua pattern 非 POSIX**（源码 bin/grep.lua 首行自述）：
  无 `\|` 交替、无 `-E`（"unexpected option: E"）；支持 -F -w -x -i -s -v -n -r
  -l -L -H -h -o -q -c --max-count=N --file --label；要交替就跑多次 grep 或 lua 脚本
- **`man` 在非 TTY 下不分页**（检测 io.output().tty 后全量输出）——exec 里安全；
  59 条 man 页在 /usr/man（34KB）。`ps` 给完整线程树（init→agent→守护线程→
  pipe_handler→当前命令，诊断用）；`df`/`lshw`/`du`/`tree`/`grep -r`（Wobbo 移植）
  真机全可用
- **/home 有用户历史调试残留 ~1MB**（diag1-6.lua/.out、e2e、fetch_wiki、gist_list、
  exec_out_*、beemaster/ 279KB=Forestry 蜜蜂自动化套件含 nbt/zzlib 库）——
  非本 agent 产物，只报告勿删；`/` 盘已用 54%（2.1M/4M）

## 坑（全部实证过）

1. **同 token 双守护抢队列**：服务器单 token 单队列，两守护同 token 时命令随机被任一抢走。
   同时在线=一机一 token，或先 `/remote off` 另一台。测试 VM 惯例：真机调试期守护 OFF。
2. **OC 协作式调度**：lua op 里无 `os.sleep` 的紧循环（`while true do end`）**冻结整台
   机器**（ocvm：timer/轮询全停，唯一恢复=重启 VM）。lua op 看门狗只在 sleep 点生效
   （deadline 注入：sleep 提前终止报 "deadline exceeded"）。远程派 lua 前确认脚本有 sleep。
   **注意 lua timeout=t 实际 t+30s 才杀**（deadline=now+min(t,600)+30，+30 是 exec
   兜底余量对 lua 属语义缺陷；真机实证 timeout=3 → 33.9s 报 "deadline exceeded after
   33s"）。**真机差异**：紧循环不会冻到永远——宿主 CPU 看门狗 ~5s 杀进程（见坑 13）；
   但 lua op 的脚本跑在**守护线程内**，被杀≈守护进程死=通道掉线直到用户重启 agent
   （未实测，按最坏打算；exec 路径的子进程被杀无此风险）。
11. **世界 ticking=通道命脉**：玩家下线/走远/区块卸载→计算机停转→守护**静默停轮询**
    （真机实证一次 ~12 分钟空白），区块重载后自动恢复。`/status` 的 online 在
    last_poll_age>45s 才翻 false；离线期间命令滞留队列（≤16），恢复后 FIFO 执行。
12. **容量写满谎报成功=r7 前真 bug**：fork 的 Capacity 层（server/fs/Capacity.scala
    CountingOutputHandle.write）空间不足时 f:write 返回 (nil,"not enough space")
    **不抛错**；write_file/append_file/edit_file 原不检查返回值→谎报 "Written to"
    静默丢数据（90KB→0 字节实证）。r7 已修（三写点检查返回值）；未升级版本上
    大文件写后**必须回读校验**。
 13. **宿主 CPU 看门狗（真机特有，ocvm 无）**：Lua 进程**不让出调度器 ~4-5s**（世界
    时间）→ 宿主**静默杀进程**（无 Lua 错误、pcall 抓不到、文件写到一半即止）。
    实证边界：2s 循环存活；纯算术 120M@3.8s 存活、150M@4.7s 被杀；50×200KB gsub 循环
    中途死。**I/O 密集安全**（fs 组件读=让出点：grep -rc "" /home 扫 1.7MB 16.6s 完成
    无杀无冻结）。杀进程后**世界再卡 ~10s**（tick 停摆、事件不流动：popen EOF 送不到、
    守护停轮询、整个 exec 链延迟——4.5s 死的脚本 wall 17s 才回结果），卡完自动恢复
    （机器/守护存活，期间滞留命令 FIFO 补执行）。规则：CPU 密集脚本每 ≤4s 插
    `os.sleep(0)` 或拆分；长命令优先 I/O 密集形态。
 14. **`luac`/`luaj` 是编译器不是解释器**：`luaj/luac file.lua` 编译字节码后退出、
    **不执行脚本**（/usr/bin 不存在，三命令=OC 宿主内建，which 搜 PATH 搜不到）。
    唯一的解释器是 `lua`（bin/lua.lua wrapper，pcall 同进程跑脚本）。对照实验若
    "多个解释器结果一致"，先查输出文件 mtime——很可能读到的是第一个运行留下的
    陈旧文件。
 15. **exec 超时杀丢部分输出**（r7 候选）：被 shell_execute 超时杀时，超时消息只带
    命令名，管道已捕获的部分输出被丢弃（dmesg 实证："Press 'Ctrl-C' to exit" 前言被
    捕获但未出现在结果里）。交互式命令（dmesg/edit/less/裸 lua REPL）要么带超时
    预期丢输出，要么别用。
 16. **`which a; which b` 链在第一个失败处 return**（which.lua `return 1`）——
    批量 which 要分开跑。
 17. **`print()` 写 TTY 不写管道**（真机实证）：OpenOS 进程的 print/io.write 默认写
     `io.output()`=机器终端（游戏内屏幕），popen 捕获管道只收 **`io.stdout`/`io.stderr`**
     ——用户态命令脚本输出必须 `io.stdout:write(...)`（cat/echo 都是这么写的）；
     `os.exit(1)` 不丢缓冲输出（rt2/rt3 探针实证，宿主补 "terminated" 尾巴）。
     这也是坑 6 "lua 脚本 print 泄漏 TUI" 的根因。
 18. **shell.parse 把 `-u` 解析成短选项**（options.u），不是位置参数——
     命令脚本读开关用 `local args, options = shell.parse(...)` 后查 `options.u`，
     查 `args[1]=="-u"` 永远 nil。
3. **`/exit` 时守护活跃→冻结**（ocvm 非确定复现）：退出前 `/remote off` 并确认 stopped。
4. **exec 多行被拒**（服务器 400）：换行拍平成空格不是两条命令；用 `&&`/`;`。
5. **413 边界**：命令线上 JSON >100000 字节拒收；write content 有效上限 ≈99.9KB
   （120K/200K 用例预期 413 是 PASS 不是 FAIL）。
6. **lua 脚本 print 不可靠**（泄漏到 TUI 或丢失）：要返回值用 `return`，大输出写文件再 read。
7. **`lua -e` 不存在**（/bin/lua.lua 的 args[1] 永远是文件名）：脚本写文件 → `lua x.lua; cat out.txt`。
8. **config 位置每 boot 漂移**（writable base 探测：/tmp 与挂载盘都出现过）：
   热重载/读 config 用 `lua` op `require("agent.config").config_path` 动态查。
9. 服务器侧 `pkill -f "remote_server.py serve"` 会自杀（匹配自己 shell）——用
   `pkill -f "[r]emote_server.py"` 括号技巧或直接 job_kill/systemctl。
10. **ocvm 测试 VM 专属**：`~/oc-test/ocvm/tmp_t/client.cfg` 需 `allowGC=true`
    （上游默认 false→长跑 OOM，改后 grep 复核）；`maxTcpConnections=16`；
    二进制不可 relocate（只在 `~/oc-test/ocvm` 原地跑，见 patches/README.md）；
    盘目录复用固定 UUID（tmp_t/client.cfg 存在时非每 boot 新盘）；挂载短名=`ls /mnt` 查。
 19. **LLM 请求无 chunk 挂起（v0.3.126r1 前真 bug，commit 8b1bfb9 已修）**：vLLM 冷
     prefill 长时间无首 chunk 时，旧 http.lua 的 interrupt/deadline 检查只在 chunk
     循环体内执行（chunk 到达才跑）→ `for chunk in handle` 无限挂起 → 120s 超时
     失效 + Ctrl+C 无法终止 + TUI 定格 "thinking...+0s"（重绘只在主循环跑）。
     源码根因：OpenOS 迭代器无数据等待=`os.sleep(0)`（loot/openos/lib/internet.lua
     :44-59 __call，即 interrupt 补丁版——FLAG 被设置但旧代码无 chunk 时永不 poll）；
     Java read() 轮询后台 ConcurrentLinkedQueue（InternetCard.scala:432，threadPool
     reader 填）数据独立于机器事件队列。修复：chunk 循环移入 thread.create 子线程，
     主循环 os.sleep(0.2) 切片检查 interrupt/deadline→t:kill+handle:close()
     （释放连接槽）；on_wait ~1/s 心跳→TUI tickStatus 让 +Ns 继续滚动。真机实证：
     预置 FLAG→interrupted @0.10s；强制超时→"http read timeout after 3s"×6 重试
     +预算耗尽、后续请求干净。卡住回合的恢复=游戏内重启 OC 电脑。
 20. **OC internet 组件把所有 4xx/5xx 转异常**（getInputStream 二调 re-throw，
     InternetCard.scala）：404→`FileNotFoundException(url)`=**错误消息是裸 URL**，
     其他→"Server returned HTTP response code: NNN for URL"。**响应码永不传给 Lua**
     ——agent 的 429/5xx 重试实际全走 err 字符串路径，code 检查是死代码。排查
     "连接失败"先想 404/429/5xx 而非真断网；vLLM 存活检查 POST /v1/models→405
     =活着（404 裸 URL=模型名不匹配：探针实证 vLLM 服务 model=Qwen3.8-27B，config
     里 Qwen3.8-27B-INT4-AWQ-GPTQ 名字 404——曾误判为通道问题）。
 21. **上传定界符 level-0 `--[[` 不可靠**：长字符串直写用 `--[[` 时实测一次远端
     内容开头多出 1 个 `[`（0x5B，+1 字节 MISMATCH），另一脚本 parse 失败
     （"unexpected symbol near 'local'"，与注释词法歧义相关）；`[==[` 多次上传
     字节级一致。**规则：远控上传一律 `[==[` 及以上**，部署后读回 n/sum/head16
     校验缺一不可。
  22. **native internet 连接等待不受 lua 看门狗管（真机电池烧进程实证）**：
      internet.request 的**连接建立**等待发生在 native 层（Java socket connect，
      ~2min/个失败端点），期间 Lua 不让出→坑 13 的宿主 CPU 看门狗杀 agent 进程
      （c320/c322 两轮镜像电池均：首个 ~21s 等待存活，第二个端点起无 report，
      /status online=False 直至用户重启）。lua op 看门狗只护 Lua sleep 点，护不了
      native 阻塞。**规则：真机网络电池先本机预筛（curl 直连/镜像/Clash 三通道），
      上真机的端点 ≤3 个且逐个发（别一次 10 个）**。
  23. **Lua pattern 的 `-` 是元字符**（`x-` = 0 个或多个 x）：测试断言里
      `r:find("JSDELIVR-FIXTURE-CONTENT")` 会因 `R-`/`E-` 解析成重复量词而**误判
      不匹配**（532 回归里 2 个 web_fetch 用例因此假 FAIL，实际输出正确）；字面量
      匹配用 plain 模式 `r:find(s, 1, true)` 或转义 `%-`。同型隐患：期望"不匹配"的
      断言（==nil）在 pattern 坏了时假通过——写测试时留意。

## 真机部署/恢复配方

```
游戏内（agent TUI）：
lua update.lua v0.3.125          -- 升级（走 tag；回滚=v0.3.124）
-- 重启 agent（TUI /exit 前若守护活跃先 /remote off）
/remote url https://<server-endpoint>
/remote token <token>            -- 注意：换 token 后需 /remote off + on 重连才生效
/remote on                       -- 自启前提：config 里 url+token 齐备（重启 agent 自动起）
```
服务器失联时先 `systemctl --user status oc-remote-server` + `docker ps | grep ocremote`，
`/status` 的 `last_poll_age` 区分"服务器死"（offline）与"真机离线"。

## 版本锚定

通道协议 v0.3.126r1（r2b/r3/r4/r5/r6/r6b/r6d/r7/r7b/web/无chunk防护 全含：看门狗/
deadline 注入/结构化 is_err/fetch 分页 64KB 分块 + 256KB 封顶/report 重试/413/
400 多行拒收/429 队列满/lost 判定/ensure_ascii=False/HTTP/1.1/写失败检查 r7/
json %c 显式类 r7b/web_search Bing+web_fetch/LLM 无 chunk 挂起防护 8b1bfb9/
响应读超时 900s 1e870fb/GitHub GFW 自动改写+gh_fetch 取件柜 4ac3efa）。
agent.lua 单文件构建（scripts/build_single.lua，21 preload）；发版走 Clash 7897
代理 push + tag。

**⚠️ 远端 tag 仍是 v0.3.125（不含 r7/r7b/web 工具/8b1bfb9 修复/900s/A+B 4ac3efa）**——
真机跑的是手动部署的多文件树（/mnt/bb7/agent/，与 master 逐字节同步）；再跑
`update.lua` 会用 tag 载荷覆盖并**回滚**。新 tag v0.3.126 待用户发话。
