---
name: oc-remote
description: 远控 OC 真机（GTNH 服务器玩家计算机）与 ocvm 测试 VM 的远程通道全量操作手册。Triggers on "远控", "远程控制", "真机", "remote", "oc-remote", "公网通道", "frp 隧道", "real_machine_probe", "remote_server"。涵盖控制服务器（systemd + SakuraFrp 隧道）、CLI 全部 op、探针/电池测试、真机环境特征与坑清单。
---

# OC 真机远程控制（oc-remote）

架构：真机 agent（v0.3.125 的 `agent/remote.lua` 守护，long-poll）↔ 控制服务器
（本机 systemd 用户服务）↔ 公网入口（SakuraFrp 隧道）。agent 只能主动外联，
世界必须 ticking。真机=GTNH 多人服务器上的玩家 OC 计算机，**玩家无文件/SSH 访问**，
此通道是唯一读写执行通道。

## 端点与凭据

| 项 | 值 |
|---|---|
| 公网端点 | `https://mc.u628580.nyat.app:37057`（真实证书，无需 `-k`；国内节点 http 必 501，必须 https） |
| token | **43 字符，勿写进本仓库**（公开 GitHub）。位置：`~/.oc-remote-token.txt`、`~/.oc-remote-token.env`（OC_REMOTE_TOKEN）、工作区 `.oc-remote-token`（gitignored） |
| 控制服务器 | systemd 用户服务 `oc-remote-server`（Linger=yes，bind 127.0.0.1:8765，hold 12s，带 `--allow-emoji`） |
| frpc | docker 容器 `ocremote`（`--network=host --restart=always`，natfrp.com/frpc，隧道 id **29038327**，node85 frp-use.com） |
| 隧道 API | `api.natfrp.com/v4`，Bearer key 见 sakurafrp-tunnel 技能/本机 `~/.frp` 配置；隧道配置变更走技能 `sakurafrp-tunnel` |

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
cd /home/hcj/aiProjects/mieAgent
TOK=$(cat .oc-remote-token)
BASE=https://mc.u628580.nyat.app:37057
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
/remote url https://mc.u628580.nyat.app:37057
/remote token <token>            -- 注意：换 token 后需 /remote off + on 重连才生效
/remote on                       -- 自启前提：config 里 url+token 齐备（重启 agent 自动起）
```
服务器失联时先 `systemctl --user status oc-remote-server` + `docker ps | grep ocremote`，
`/status` 的 `last_poll_age` 区分"服务器死"（offline）与"真机离线"。

## 版本锚定

通道协议 v0.3.125（r2b/r3/r4/r5/r6/r6b/r6d 全含：看门狗/deadline 注入/结构化 is_err/
fetch 分页 64KB 分块 + 256KB 封顶/report 重试/413/400 多行拒收/429 队列满/
lost 判定/ensure_ascii=False/HTTP/1.1）。agent.lua 单文件构建
（scripts/build_single.lua，21 preload）；发版走 Clash 7897 代理 push + tag。
