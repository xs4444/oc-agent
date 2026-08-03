# MIE Agent — OpenComputers AI Agent 项目

在 Minecraft GTNH 服务器的 OpenComputers 中运行的单文件 AI 编码 agent。agent 通过 Internet Card 直连 LLM API（OpenAI 兼容），具备文件操作、硬件操控、代码执行与联网搜索能力。

## 核心文件

| 路径 | 说明 |
|------|------|
| `agent.lua` | **唯一需要部署到游戏内的文件**（单文件，含全部功能） |
| `docs/superpowers/specs/2026-07-28-oc-agent-design.md` | 设计文档（superpowers 流程产物） |
| `docs/superpowers/plans/2026-07-28-oc-agent.md` | 实现计划 |

## 功能一览

- **13 个 LLM 工具**：`read_file`（支持 offset/limit 行切片 + tail）/ `write_file` / `edit_file`（精确替换，唯一性检查）/ `append_file`（流式追加，内存恒定）/ `list_directory` / `json_query` / `calc` / `text_ops` / `component_list` / `component_doc` / `component_invoke` / `web_search` / `shell_execute` + **`subagent_call`（14 个）**
- **子代理**：`subagent_call(address, task)` 通过游戏内网卡（modem 组件）把任务委派给其他 OC 计算机上运行的 `agent.lua -- --subagent`——每台子代理拥有独立内存和磁盘，主代理可并行调度；跨机器经 ocvm 双实例实测通过（SUBAGENT_PONG 往返）
- **组件探索闭环**：list → doc → invoke，LLM 可自主发现并操控任意 OC 硬件
- **数据处理工具集**：`json_query`（JSON 点路径提取）/ `calc`（安全数学求值，不执行代码）/ `text_ops`（字符串操作）替代了原 `execute_lua`，无任意代码执行风险
- **文件工具族**：`read_file` 行切片（大文件只读目标区段，带行号；负 offset = tail）+ `edit_file`（精确替换，>20KB 拒绝）+ `append_file`（流式追加，内存与文件大小无关）——先查后改，适配 OC 1MB 内存
- **联网搜索**：默认 HN Algolia（无 key），`/tavily <key>` 升级为通用搜索（含中文）
- **append-only 会话日志**：每条消息 JSON 单行追加（O(新增) 内存，替代整表重写 O(n²)）；启动重放 + 裁剪；旧格式自动迁移
- **自动重试**：网络错误 / 429 / 5xx 自动重试（指数退避，最多 3 次），4xx 不重试
- **对话压缩**：历史超限时自动用 LLM 生成摘要替换旧消息（保留最近 4 条），失败回退裁剪；`/compact` 手动触发
- **会话归档**：`/new` 将当前会话归档到 `/home/sessions/` 并开新会话（配置保留）
- **默认模型**：`deepseek-v4-flash-free`（OpenCode Zen 免费，无需 key）

## 部署（GitHub 自动安装，无需粘贴）

agent.lua 已发布到 GitHub（xs4444/oc-agent），游戏内一条命令安装：

```bash
# 方式 1: jsDelivr CDN（国内可达性好，推荐）
wget https://cdn.jsdelivr.net/gh/xs4444/oc-agent@main/install.lua install.lua

# 方式 2: GitHub raw（需要服务器能访问 GitHub）
wget https://raw.githubusercontent.com/xs4444/oc-agent/main/install.lua install.lua

# 运行安装器（自动下载 agent.lua + 校验；回答 y 配置为子代理）
lua install.lua

# 启动
lua agent.lua                  # 主代理
lua agent.lua -- --subagent    # 子代理（监听 modem 9090）
```

- 安装器自动检测可写目录（/home 只读时用挂载盘），支持 `lua install.lua /mnt/xxx` 指定目录
- 更新：重新运行 install.lua 即覆盖为最新版（jsDelivr CDN 缓存可能延迟，必要时用 commit hash URL）
- 手动方式（备用）：将 `agent.lua` 上传到 OC 计算机（wget / pastebin / 手动复制）

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
├── agent.lua              # 主程序（部署到游戏）
├── README.md
├── docs/                  # 设计文档与实现计划 → docs/README.md
│   └── superpowers/
├── test_harness/          # 测试脚本（本地 + 模拟器内）→ test_harness/README.md
│   ├── oc_mock.lua        # OC API mock（本地 Lua 环境）
│   ├── run_tests.lua      # 本地回归测试（48 项）
│   └── ...                # 能力边界/内存/搜索/端到端测试
├── emulators/             # 第三方 OC 模拟器 → emulators/README.md
│   ├── OCEmu/             # 真实 OC machine.lua 沙箱（Lua 5.2）
│   ├── ocvm/              # C++ 模拟器（Linux，含修复）
│   └── OpenComputersVM/   # JavaFX 模拟器（Windows GUI）
├── wiki/                  # OC wiki 离线镜像 → wiki/README.md
│   ├── raw/               # DokuWiki 原始文本（215 页）
│   ├── markdown/          # Markdown 转换版（32 页）
│   └── reference/         # agent 开发精选 API 参考（35 文件）
├── tools/                 # Windows 辅助脚本 → tools/README.md
├── scripts/               # 一次性工具脚本 → scripts/README.md
├── lua_portable/          # 便携 Lua 5.4（本地测试运行时）→ lua_portable/README.md
├── opencomputers/         # GTNH OpenComputers fork 源码（参考）
└── pi/                    # pi.dev agent 源码（架构参考）
```

## 测试环境（Ubuntu 服务器 192.168.31.75）

游戏外验证链路（均已在真实 OpenOS 1.8.9 中通过）：

```bash
# ocvm（C++，已修复 wget 参数/escape/子进程回收/内存配置）
cd ~/oc-test/ocvm && make lua=lua5.3
tmux new-session -d -s ocvm './ocvm tmp'

# OCEmu（真实 machine.lua 沙箱，已修复 content-type 覆盖）
cd ~/oc-test/OCEmu && DISPLAY=:77 lua5.2 boot.lua
```

测试要点：
- 本地：`lua_portable/bin/lua.exe test_harness/run_tests.lua`（48 项回归）
- 模拟器：部署 `agent.lua` + 测试脚本到 `/mnt/<mount>/`，经 shell 执行
- LLM 端到端：`deepseek-v4-flash` @ opencode-go（备用，需 auth.json 的 key）

## 已知限制

- **上下文受 OC 内存限制**：2 个 T3.5（2MB）下历史预算 50KB（≈12-25K token）。200K 上下文需要 4MB+ 且需给 JSON 编码器加 yield 改造
- **`collectgarbage` 不可用**：无法手动触发 GC，依赖 Lua 自动增量回收（已实测无泄漏）
- **搜索覆盖**：HN Algolia 仅英文技术内容；Tavily 需注册 key
- **公共服务器限制**：OC 网络黑名单/白名单、HTTP 开关可能影响外联
