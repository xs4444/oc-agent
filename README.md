# MIE Agent — OpenComputers AI Agent 项目

在 Minecraft GTNH 服务器的 OpenComputers 中运行的单文件 AI 编码 agent。agent 通过 Internet Card 直连 LLM API（OpenAI 兼容），具备文件操作、硬件操控、代码执行与联网搜索能力。

## 核心文件

| 路径 | 说明 |
|------|------|
| `agent.lua` | **唯一需要部署到游戏内的文件**（单文件，含全部功能） |
| `docs/superpowers/specs/2026-07-28-oc-agent-design.md` | 设计文档（superpowers 流程产物） |
| `docs/superpowers/plans/2026-07-28-oc-agent.md` | 实现计划 |

## 功能一览

- **15 个 LLM 工具**：`read_file`（支持 offset/limit 行切片 + tail）/ `write_file` / `edit_file`（精确替换，唯一性检查）/ `append_file`（流式追加，内存恒定）/ `list_directory` / `json_query` / `calc` / `text_ops` / `component_list` / `component_doc` / `component_invoke` / `web_search` / `shell_execute` / `subagent_call` + **`ask_user`（对话中向用户提问，选项编号或自定义输入）**
- **子代理**：`subagent_call(address, task, role?, session?, context?, timeout?)` 通过游戏内网卡（modem 组件）把任务委派给其他 OC 计算机上运行的 `agent.lua -- --subagent`——每台子代理拥有独立内存和磁盘，主代理可并行调度；跨机器经 ocvm 双实例实测通过（SUBAGENT_PONG 往返）
- **子代理会话复用**：`session` 参数延续子代理对话（同 id 恢复磁盘上的会话历史，省略则全新会话）；busy 状态机防止同会话并发（对齐 opencode 的 Active/Reusable 会话模型）
- **组件探索闭环**：list → doc → invoke，LLM 可自主发现并操控任意 OC 硬件
- **数据处理工具集**：`json_query`（JSON 点路径提取）/ `calc`（安全数学求值，不执行代码）/ `text_ops`（字符串操作）替代了原 `execute_lua`，无任意代码执行风险
- **文件工具族**：`read_file` 行切片（大文件只读目标区段，带行号；负 offset = tail）+ `edit_file`（精确替换，>20KB 拒绝）+ `append_file`（流式追加，内存与文件大小无关）——先查后改，适配 OC 1MB 内存
- **联网搜索**：默认 HN Algolia（无 key），`/tavily <key>` 升级为通用搜索（含中文）
- **shell_execute 增强**：`io.popen` 捕获 stdout+stderr（不再只返回 true/false）+ 线程超时保护（默认 60s，死循环/挂起命令自动 kill）
- **append-only 会话日志**：每条消息 JSON 单行追加（O(新增) 内存，替代整表重写 O(n²)）；启动重放 + 裁剪；旧格式自动迁移
- **自动重试**：网络错误 / 429 / 5xx 自动重试（指数退避，最多 3 次），4xx 不重试
- **对话压缩**：历史超限时自动用 LLM 生成摘要替换旧消息（保留最近 4 条），失败回退裁剪；`/compact` 手动触发
- **会话归档**：`/new` 将当前会话归档到 `/home/sessions/` 并开新会话（配置保留）
- **诊断上报**：`/debug` 收集版本+脱敏配置+最近历史 → 本地文件 + 可选上传 GitHub Gist（`/gist-token <token>` 配置，scope: gist）
 - **增量更新**：`lua update.lua` 只下载有变动的文件（按 files.json 字节对比跳过），版本号带时间戳可区分
 - **离线文档**：`lua docs.lua` 可选下载 GTNH wiki markdown 离线包（纯文本 269 页 ~0.9MB，解压到挂载盘 `/mnt/<x>/doc`，按 docs.json 版本对比跳过重复下载；纯 Lua ustar 解包，不依赖 tar 命令）
 - **默认模型**：`deepseek-v4-flash-free`（OpenCode Zen 免费，无需 key）

## 部署（GitHub 自动安装，无需粘贴）

agent.lua 已发布到 GitHub（xs4444/oc-agent），游戏内一条命令安装：

```bash
# 首次安装：下载 update.lua（一次即可，之后它自动更新自己）
wget https://cdn.jsdelivr.net/gh/xs4444/oc-agent@master/update.lua update.lua
lua update.lua

# 以后每次更新：
lua update.lua
```

- update.lua 通过 jsDelivr data API 查询最新发布 tag（如 `@v0.3.0`），用**不可变 tag URL** 下载，不受 `@master` CDN 缓存延迟影响
- 安装器自动检测可写目录（/home 只读时用挂载盘），支持 `lua install.lua /mnt/xxx <ref>` 指定目录与版本
- 安装后创建 PATH 启动器 `/home/bin/agent`（OpenOS 默认 PATH 含 /home/bin），任意目录直接 `agent` 启动
- 手动方式（备用）：`wget https://cdn.jsdelivr.net/gh/xs4444/oc-agent@v0.3.0/install.lua install.lua` 后 `lua install.lua`

> 首次引导直接回车接受默认（免费模型，无需 API key）；`/home` 只读时配置自动写入挂载盘。

```lua
-- 游戏内命令
/model <model>        -- 切换模型
/key <api_key>        -- 设置 API key（留空用免费模型）
/url <endpoint>       -- 切换 API 端点
/tavily <key>         -- 启用 Tavily 通用搜索
/new                  -- 归档当前会话到 /home/sessions/ 并开新会话
/compact              -- 手动压缩对话（LLM 摘要 + 保留最近 4 条）
/reset                -- 清空对话历史（不归档）
/hist                 -- 查看当前会话消息数
/version              -- 显示已安装 agent 版本
/tools                -- 列出全部工具及说明
/debug                -- 生成诊断报告（本地 + 可选上传 Gist）
/gist-token <token>   -- 保存 GitHub token（scope: gist）供 /debug 上传
/help                 -- 全部命令说明
/exit                 -- 退出
```

## 子代理部署（多台 OC 组网）

```bash
# 每台子代理机器（需网络卡/无线网卡，与主代理同网络）：
# 安装器回答 y 自动写 subagent=true 配置，然后：
lua agent.lua -- --subagent          # 监听 modem 端口 9090
# 或在 config 里加 subagent=true，然后直接 lua agent.lua

# 主代理机器：运行时 LLM 通过 component_list(filter="modem") 发现子代理地址，
# 然后 subagent_call(address, task, role?, session?, context?, timeout?) 委派任务。
# session 参数延续子代理的对话记录（同 id = 复用上下文，省略 = 新会话）。
# 子代理收到后用自己的内存/磁盘/算力处理（完整 agent 循环），结果回传。
```

## 目录结构

每个子目录含独立 `README.md` 说明用途与用法。

```
├── agent.lua              # 主程序（构建产物，单文件含全部模块）
├── install.lua            # 安装器（多文件安装 + 增量更新 + PATH 集成）
├── update.lua             # 一键更新（查最新 tag → 增量更新，永不需更新自身）
├── files.json             # 安装清单（16 个模块路径 + 字节数 + 版本号）
├── README.md
├── src/agent/             # 模块化源码（9 核心 + 7 工具模块）
│   ├── init.lua           # 入口（REPL/子代理/命令/ask_user 注入）
│   ├── chat.lua           # LLM 客户端 + 系统提示（含 OpenOS 命令引导）
│   ├── debug.lua          # 诊断报告收集 + Gist 上传
│   ├── tools.lua          # 工具注册表（BUILTIN + 插件扫描）
│   └── tools/             # 工具模块（file/data/component/search/shell/subagent/question）
├── docs/                  # 设计文档与实现计划 → docs/README.md
│   ├── COMPARISON.md      # 与 oc-ai / pi / pi-subagents 三方对比
│   └── superpowers/
├── test_harness/          # 测试脚本（本地 + 模拟器内）→ test_harness/README.md
│   ├── oc_mock.lua        # OC API mock（本地 Lua 环境）
│   ├── run_tests.lua      # 本地回归测试（117 项）
│   ├── danger_test.lua    # 高危场景测试（21 项：自改/坏插件/死循环/磁盘/配置/自删/递归）
│   ├── shell_timeout_test.lua  # ocvm/OCEmu 真机 shell 超时验证
│   └── ...                # 子代理/能力边界/内存/搜索/文件工具测试
├── emulators/             # 第三方 OC 模拟器 → emulators/README.md
│   ├── OCEmu/             # 真实 OC machine.lua 沙箱（Lua 5.2）
│   ├── ocvm/              # C++ 模拟器（Linux，含修复）
│   └── OpenComputersVM/   # JavaFX 模拟器（Windows GUI）
├── wiki/                  # OC wiki 离线镜像 → wiki/README.md
│   ├── raw/               # DokuWiki 原始文本（215 页）
│   ├── markdown/          # Markdown 转换版（40+ 页，含 GTNH 指南）
│   └── reference/         # agent 开发精选 API 参考（35 文件）
├── tools/                 # Windows 辅助脚本（截图/按键/ocvm 测试驱动）→ tools/README.md
├── scripts/               # 构建脚本（build_single/make_manifest）+ 一次性工具 → scripts/README.md
├── lua_portable/          # 便携 Lua 5.4（本地测试运行时）→ lua_portable/README.md
├── opencomputers/         # GTNH OpenComputers fork 源码（参考）
├── oc-ai/                 # DonChong2000/oc-ai 源码（参考）
├── pi/                    # pi.dev agent 源码（架构参考）
└── pi-subagents/          # nicobailon/pi-subagents 源码（子代理参考）
```

## 测试环境（内网 Ubuntu 测试服务器）

游戏外验证链路（均已在真实 OpenOS 1.8.9 中通过）：

```bash
# ocvm（C++，已修复 wget 参数/escape/子进程回收/内存配置）
cd ~/oc-test/ocvm && make lua=lua5.3
tmux new-session -d -s ocvm './ocvm tmp'

# OCEmu（真实 machine.lua 沙箱，已修复 content-type 覆盖）
cd ~/oc-test/OCEmu && DISPLAY=:77 lua5.2 boot.lua
```

测试要点：
- 本地：`lua_portable/bin/lua.exe test_harness/run_tests.lua`（117 项回归）+ `danger_test.lua`（21 项高危场景）
- 模拟器：`python tools/ocvm_test.py test_harness/<脚本>.lua` 一键驱动（自动重启 ocvm → 上传 → 探测挂载 → 运行 → 拉取结果）
- 子代理双实例：`run_subagent_dual.py` 模式（主/子两台 ocvm 组网，modem 互通）
- LLM 端到端：`deepseek-v4-flash` @ opencode-go（备用，需 auth.json 的 key）
- 远程诊断：游戏内 `/debug` 上传诊断报告到 Gist，供远程排查

## 已知限制

- **上下文受 OC 内存限制**：2 个 T3.5（2MB）下历史预算 50KB（≈12-25K token）。200K 上下文需要 4MB+ 且需给 JSON 编码器加 yield 改造
- **`collectgarbage` 不可用**：无法手动触发 GC，依赖 Lua 自动增量回收（已实测无泄漏）
- **搜索覆盖**：HN Algolia 仅英文技术内容；Tavily 需注册 key
- **公共服务器限制**：OC 网络黑名单/白名单、HTTP 开关可能影响外联
