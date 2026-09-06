---
name: oc-remote
description: 远控 OC 真机（GTNH 服务器玩家计算机）与 ocvm 测试 VM 的远程通道全量操作手册。Triggers on "远控", "远程控制", "真机", "remote", "oc-remote", "公网通道", "frp 隧道", "real_machine_probe", "remote_server"。涵盖控制服务器（systemd + SakuraFrp 隧道）、CLI 全部 op、探针/电池测试、真机环境特征与 12 坑清单（含磁盘图/世界 ticking/容量写满语义）。
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
- **磁盘图**（df 实证）：`/`=OpenOS 根盘 4MB（**/home 在此**，余 ~1.8MB）；
  三驱动 `/mnt/857` 4MB 1%、`/mnt/bb7` 4MB 14%（**agent 多文件部署树
  /mnt/bb7/agent/**，入口 agent.lua ~119KB）、`/mnt/9ab` 2MB 41%；
  **`/tmp` 仅 64KB tmpfs**（fork `application.conf:918 tmpSize: 64`）——
  大文件写 /home 或 /mnt，别写 /tmp
- **agent 部署=多文件树**（非单文件）：改代码只需覆盖对应文件（tools/file.lua、
  remote.lua 等单个都 <100KB，write op 直达），然后用户游戏内重启 agent
- LLM=用户自建 vLLM 端点（`<llm-endpoint>`，Qwen3.8-27B-INT4，
  ctx 128K）——与远控通道不同端口互不影响
- 护栏空闲内存拒绝消息是中文：`空闲内存 X < NB（shell 执行护栏）`
- 错误判定=结构化 is_err（v0.3.125r3+：工具层直接返回布尔，`^Error` 前缀仅回退）——
  合法输出含 "Error:" 不误判
- `update.lua` 升级后**必须重启 agent**（旧进程不带新代码，护栏文案可暴露版本）

## 坑（全部实证过）

1. **同 token 双守护抢队列**：服务器单 token 单队列，两守护同 token 时命令随机被任一抢走。
   同时在线=一机一 token，或先 `/remote off` 另一台。测试 VM 惯例：真机调试期守护 OFF。
2. **OC 协作式调度**：lua op 里无 `os.sleep` 的紧循环（`while true do end`）**冻结整台
   机器**（timer/轮询全停，唯一恢复=重启 VM）。lua op 看门狗只在 sleep 点生效
   （deadline 注入：sleep 提前终止报 "deadline exceeded"）。远程派 lua 前确认脚本有 sleep。
   **注意 lua timeout=t 实际 t+30s 才杀**（deadline=now+min(t,600)+30，+30 是 exec
   兜底余量对 lua 属语义缺陷；真机实证 timeout=3 → 33.9s 报 "deadline exceeded after
   33s"）。
11. **世界 ticking=通道命脉**：玩家下线/走远/区块卸载→计算机停转→守护**静默停轮询**
    （真机实证一次 ~12 分钟空白），区块重载后自动恢复。`/status` 的 online 在
    last_poll_age>45s 才翻 false；离线期间命令滞留队列（≤16），恢复后 FIFO 执行。
12. **容量写满谎报成功=r7 前真 bug**：fork 的 Capacity 层（server/fs/Capacity.scala
    CountingOutputHandle.write）空间不足时 f:write 返回 (nil,"not enough space")
    **不抛错**；write_file/append_file/edit_file 原不检查返回值→谎报 "Written to"
    静默丢数据（90KB→0 字节实证）。r7 已修（三写点检查返回值）；未升级版本上
    大文件写后**必须回读校验**。
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

通道协议 v0.3.125r7（r2b/r3/r4/r5/r6/r6b/r6d/r7 全含：看门狗/deadline 注入/结构化 is_err/
fetch 分页 64KB 分块 + 256KB 封顶/report 重试/413/400 多行拒收/429 队列满/
lost 判定/ensure_ascii=False/HTTP/1.1）。agent.lua 单文件构建
（scripts/build_single.lua，21 preload）；发版走 Clash 7897 代理 push + tag。
