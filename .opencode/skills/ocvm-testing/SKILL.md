---
name: ocvm-testing
description: ocvm 模拟器测试（本机 ~/oc-test/ocvm，<ocvm-host>）。Triggers on "ocvm", "ocvm 测试", "modular 测试", "模拟器测试", "VM 测试", "remote_pit", "remote_battery"。涵盖 VM 启动/部署/远控 E2E 全流程、test_harness 远程套件（39 用例+10 场景电池）、legacy SSH 驱动 tools/ocvm_test.py 的 EXTRA_FILES 语法与 modular 测试。
---

# ocvm 模拟器测试（本机）

> ocvm 是 OpenComputers 的 C++ 模拟器。**本机（<ocvm-host>，用户 <user>）就是测试服务器**
> ——旧文档里的"<ocvm-host> 远程 + 密码 <password> + `cd "<local-dir>"`"全部过时作废。
> VM 在 `~/oc-test/ocvm` 原地运行（**二进制不可 relocate**，拷到新目录第二次 boot 卡死，
> 见 `patches/README.md`）。总内存 4MB（真机 4MB），数据盘目录 `tmp_t/<uuid>/`。

## 环境要点

```bash
cd ~/oc-test/ocvm
# tmp_t/client.cfg 必须保持（改后 grep 复核——曾被冲回）:
#   allowGC=true            # 上游默认 false → 长跑瞬态 OOM（write_90k FAIL 根因）
#   maxTcpConnections=16    # 上游默认 4，远控 long-poll 会触顶
#   内存 4194304 / system.timeout 120
```

- 杀 VM 用 `pkill -x ocvm`（`-f` 会匹配自己的 shell 命令行自杀——已三度复发）
- tmux 会话惯例 `ocvm_t`：`tmux kill-session -t ocvm_t; tmux new-session -d -s ocvm_t './ocvm tmp_t'`
- **磁盘**：`tmp_t/client.cfg` 存在时盘目录固定 UUID（当前 574e8f95-…，挂载 `/mnt/574`）；
  盘目录不存在时每次 boot 新建。挂载短名=目录名前 3 hex，boot 后 `ls /mnt` 确认再部署。
  宿主侧直接读写：`~/oc-test/ocvm/tmp_t/<uuid>/`（VM 内路径即该树）。

## 标准 E2E 跑法（远控通道，当前主力）

不再用 TUI 交互驱动——agent 自带 `remote.lua` 守护，全部经控制服务器验证：

```bash
cd <repo-root>/aiProjects/mieAgent
# 1. 服务器（真机目标带 --allow-emoji；ocvm 目标去掉，否则 4 字节字符无保护）
python3 tools/remote_server.py serve --bind 127.0.0.1 --port 8765 --hold 12 --token <tok>
# 2. boot VM → 部署 agent.lua（scripts/build_single.lua 构建）+ agent_config.txt
#    config 必须含 remote_url=http://127.0.0.1:8765 + remote_token + mem_exec_min_free=200000
#    （4MB 机空闲 ~317KB < 默认 500KB 护栏，不降会全拒 exec）
# 3. 交互式首跑（tmux send-keys）: lua /mnt/<盘>/agent.lua + 3 次 Enter 跳 setup
#    → 守护自启（config 有 url+token 即自启；或 TUI 内 /remote on）
# 4. 验证:
python3 test_harness/remote_pit_test.py        # 39 用例（本地 127.0.0.1 默认）
python3 test_harness/remote_battery_test.py --base http://127.0.0.1:8765 --token <tok>  # 10 场景
python3 tools/remote_server.py client --base http://127.0.0.1:8765 --token <tok> --ping
```

基线（r6b+ 构建，GC on）：39 用例 **41 PASS/0 FAIL/9 OBSERVE**、电池 **10/10**。
OBSERVE 9 是信息型（lua -e 无支持/输出泄漏/二进制读等已知行为），FAIL 才是回归。
完整 op 手册、真机差异、10 条坑 → 见 `oc-remote` skill。

## legacy SSH 驱动（tools/ocvm_test.py，仍能跑但少用）

驱动走 paramiko SSH，环境变量必须非空（本机可指 localhost）：

```bash
export OCVM_HOST=<ocvm-host> OCVM_USER=<user> OCVM_PASS=<本机密码或留参>
python3 tools/ocvm_test.py test_harness/<test>.lua
```

流程：重启 VM（tmux ocvm_t）→ 上传 agent.lua + 测试脚本到所有挂载盘 →
find_agent_mount（touch 实证可写盘）→ run_script（dofile agent.lua + 钩子）→
wait_result 轮询 VM 内 `test_harness/results/<test>_result.txt`（host 侧看
`tmp_t/<uuid>/test_harness/results/`）。

### EXTRA_FILES 映射语法

逗号分隔，`path=newname` 映射：

| 用法 | 效果 |
|------|------|
| `EXTRA_FILES=oc-docs.tar` | 单文件上传到挂载根 |
| `EXTRA_FILES=src/agent=agent` | 目录递归上传，内容落 `<mount>/agent/` |
| `EXTRA_FILES=src/agent/init.lua=agent/agent.lua` | 文件映射，入口以 agent.lua 部署名 |

实现要点（踩过的坑，改 ocvm_test.py 前必读）：main() 解析 `path=newname` 时
**先拆 = 再 exists()** 校验（整串 exists 必 False）；upload() 用**整串**判定 `=`
（Windows basename 会被 `\` 截断漏判）；文件映射目标含子路径时**同时查 `/` 和 `\`**
（反斜杠分支曾把文件传回挂载根覆盖单文件 agent.lua）。

### modular 测试（多文件 require 链 + 插件自举）

验证开发态 `src/agent/` 目录结构在真实 OpenOS 中可 require：

```bash
EXTRA_FILES="src/agent=agent,src/agent/init.lua=agent/agent.lua" \
  OCVM_HOST=<ocvm-host> OCVM_USER=<user> OCVM_PASS=<...> \
  python3 tools/ocvm_test.py test_harness/modular_ocvm_test.lua
```

断言 TOOLS **11 项**（v0.3.124 从 19 精简：file 3/read+search+write 系、component 3 删、
data 3 删、其余 5）+ require 链 + json roundtrip + 插件自举闭环。

## 其他工具

- `tools/ocvm_dialog.py` 交互式多轮对话（屏幕检测轮次：Ready 状态栏 + "> " 提示符 +
  [compact] 标记——history 在 VM 内 tmpfs，host 轮询不到）
- `tools/ocvm_relocate_test.py` / `ocvm_relocate_e2e.py` 迁移流程
  （e2e 的 PASS 判断曾匹配 "/mnt/" 即过——真实验证要对比迁移前后 /relocate 显示的数据目录）
- `tools/ocvm_dual_test.py` 双实例 modem 互联（explorer 文件代理）：每实例 modem 连
  `HostAddress:SystemPort`（默认 127.0.0.1:56000），同 system port 即同网（星型 hub）；
  挂载盘 host 路径 `tmp_t/<uuid>/`
- `tools/ocvm_install_test.py` install.lua 自举
- `tools/ssh_ubuntu.py` 默认 IP 仍是 **<ocvm-host>（过时**，真机 <ocvm-host>）——
  用 `UBUNTU_HOST=<ocvm-host> python3 tools/ssh_ubuntu.py ...` 覆盖

## 排查备忘

- config 位置每 boot 漂移（writable base 探测）：读活 config 用
  `lua` op `require("agent.config").config_path`，别在宿主侧找
- 测试 config 不能带 `return` 前缀（`serialization.unserialize = load("return "..data)`
  带前缀变 `return return {...}` 语法错 → 弹 First Run Setup）
- 首跑 setup 3 问（默认 deepseek-v4-flash-free / opencode zen），空回车走默认
- VM 冻结（TUI 无回显 + CPU 高）= 死循环/守护活跃 /exit → `pkill -x ocvm` + 重启
- 真机（非 ocvm）测试/远控 → `oc-remote` skill；ocvm 定位=真机 Lua 层回归沙箱
  （OpenOS 1.8.9 同款；VM 宿主层 C++(ocvm) vs Java(GTNH) 结论不可互推）
