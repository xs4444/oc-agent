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
 - **离线文档**：`lua docs.lua` 可选下载 GTNH wiki markdown 离线包（纯文本 269 页 ~0.9MB，解压到挂载盘 `/mnt/<x>/doc`，按 docs.json 版本对比跳过重复下载；纯 Lua ustar 解包，不依赖 tar 命令）。**交互引导**：自动识别已安装位置 + 候选盘（容量/系统盘排除），选择安装或卸载；子命令 `status` / `uninstall` / `<路径>` 直接安装
 - **上下文仪表盘**：`/ctx` 显示上次请求真实 tokens（provider 上报 usage）+ 窗口百分比 + ANSI 进度条（绿/黄/红按使用率分级）+ 消息构成估算（system/对话/工具结果）+ 压缩状态；每次 LLM 响应后自动显示一行 `[ctx] 3,558 / 128,000 tokens (2.8%) █░░...`（`ctx_auto=false` 关闭）；窗口大小 `context_window` 可配置（默认 128000）
 - **400 防护**：请求前 token 预算（估算超窗口 80% 自动压缩；压缩失败 LLM 已超限时强制裁剪保留最近）；HTTP 400 仅当估算确实超限（>85%）才裁剪重试，其他原因（reasoning/格式/限流）保留现场报错
 - **reasoning_content 传回**：DeepSeek/Kimi thinking mode 的思考内容随历史完整传回（网关要求，缺失返回 400）；JSON 编码器对全部控制字符转义为 `\u00XX`（裸控制字符 = 非法 JSON → 400）
 - **多行输入**：`/ml` 逐行收集到独立行 `EOF` 合并为一条消息发送（粘贴多行代码不再被逐行误发成多条命令；OC 无 bracketed paste，opencode TUI 多行粘贴的等价物）
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
- 离线文档：更新后 `lua docs.lua` 交互引导安装（选数据盘，自动排除系统盘）；`lua docs.lua status` 查看状态，`uninstall` 卸载

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
/ctx                  -- 上下文使用仪表盘（tokens + 百分比 + 进度条 + 构成）
/ml                   -- 多行输入（粘贴代码：逐行收集到 EOF 行）
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
├── docs.lua               # 离线文档安装器（交互引导选盘/卸载 + 纯 Lua ustar 解包）
├── files.json             # 安装清单（18 个分发文件 + 字节数 + 版本号）
├── docs_pack/             # 离线文档包（oc-docs.tar 910KB + docs.json 元数据，make_docs_pack.py 生成）
├── README.md
├── src/agent/             # 模块化源码（9 核心 + 8 工具模块）
│   ├── init.lua           # 入口（REPL/子代理/命令 /ctx /ml/ask_user 注入/400 防护）
│   ├── chat.lua           # LLM 客户端 + 系统提示（工具清单/上下文管理引导）
│   ├── config.lua         # 配置（context_window/ctx_auto 默认值）
│   ├── debug.lua          # 诊断报告收集 + Gist 上传
│   ├── json.lua           # JSON 编解码（全控制字符转义）
│   ├── tools.lua          # 工具注册表（BUILTIN + 插件扫描）
│   └── tools/             # 工具模块（file/data/component/search/shell/subagent/question）
├── docs/                  # 设计文档与实现计划 → docs/README.md
│   ├── COMPARISON.md      # 与 oc-ai / pi / pi-subagents 三方对比
│   └── superpowers/
├── test_harness/          # 测试脚本（本地 + 模拟器内）→ test_harness/README.md
│   ├── oc_mock.lua        # OC API mock（本地 Lua 环境）
│   ├── run_tests.lua      # 本地回归测试（142 项：JSON/工具/压缩/TOOLS 双向校验/ctx/400 防护/多行输入）
│   ├── danger_test.lua    # 高危场景测试（21 项：自改/坏插件/死循环/磁盘/配置/自删/递归）
│   ├── shell_timeout_test.lua  # ocvm/OCEmu 真机 shell 超时验证
│   ├── reasoning_e2e_test.lua  # reasoning_content 传回真机 e2e（工具链无 400）
│   ├── test_docs_interact.lua  # docs.lua 交互引导全流程（安装/卸载/状态）
│   └── ...                # 子代理/能力边界/内存/搜索/文件工具测试
├── emulators/             # 第三方 OC 模拟器 → emulators/README.md
│   ├── OCEmu/             # 真实 OC machine.lua 沙箱（Lua 5.2）
│   ├── ocvm/              # C++ 模拟器（Linux，含修复）
│   └── OpenComputersVM/   # JavaFX 模拟器（Windows GUI）
├── wiki/                  # OC wiki 离线镜像 → wiki/README.md
│   ├── raw/               # DokuWiki 原始文本（215 页）
│   ├── markdown/          # Markdown 转换版（40+ 页，含 GTNH 指南）
│   └── reference/         # agent 开发精选 API 参考（35 文件）
├── tools/                 # Windows 辅助脚本 → tools/README.md
│   ├── ocvm_test.py       # ocvm 测试驱动（EXTRA_FILES 上传 + 结果自动保存）
│   ├── ssh_ubuntu.py      # Ubuntu 测试服务器一键执行
│   ├── ssh_win.py         # windowsCo 一键执行（密钥认证，--ps 中文路径）
│   └── gist.py            # /debug 报告拉取（list/latest/fetch）
├── scripts/               # 构建与发版脚本 → scripts/README.md
│   ├── build_all.py       # 构建+清单+142 项回归一键
│   ├── release_check.py   # 发版安全检查（版本 bump/清单/字节/语法）
│   ├── watch_release.py   # jsDelivr 索引监控（索引后提示可更新）
│   ├── make_docs_pack.py  # 离线文档包生成（CRLF→LF + ustar）
│   └── build_single.lua / make_manifest.lua
├── lua_portable/          # 便携 Lua 5.4（本地测试运行时）→ lua_portable/README.md
├── repos/                 # 外部源码研究（gitignored）
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
- 本地：`python scripts/build_all.py`（构建+清单+回归一键）或 `lua_portable/bin/lua.exe test_harness/run_tests.lua`（**142 项回归**：JSON 编解码含控制字符转义/工具执行/压缩/TOOLS 双向校验/ctx 仪表盘/400 防护/多行输入收集）+ `danger_test.lua`（21 项高危场景）
- 模拟器：`python tools/ocvm_test.py test_harness/<脚本>.lua` 一键驱动（自动重启 ocvm → 上传 → 探测挂载 → 运行 → 拉取结果，结果自动存 `test_harness/results/`）
- 子代理双实例：`run_subagent_dual.py` 模式（主/子两台 ocvm 组网，modem 互通）
- LLM 端到端：`deepseek-v4-flash` @ opencode-go（备用，需 auth.json 的 key）；`reasoning_e2e_test.lua` / `json_ctrl_e2e_test.lua` 验证工具链无 400
- 发版链路：`build_all.py` → `release_check.py`（全 PASS 才能打 tag）→ `watch_release.py --tag vX.Y.Z`（监控 jsDelivr 索引，索引后服务器 `lua update.lua`）
- 远程诊断：游戏内 `/debug` 上传诊断报告到 Gist（`tools/gist.py latest` 拉取）

## 已知限制

- **上下文受 OC 内存限制**：2 个 T3.5（2MB）下历史预算 50KB（≈12-25K token）。窗口大小在 config 的 `context_window` 配置（默认 128000，按模型实际窗口调整）；`/ctx` 实时查看使用率，超 80% 自动压缩
- **`collectgarbage` 不可用**：无法手动触发 GC，依赖 Lua 自动增量回收（已实测无泄漏）
- **搜索覆盖**：HN Algolia 仅英文技术内容；Tavily 需注册 key
- **公共服务器限制**：OC 网络黑名单/白名单、HTTP 开关可能影响外联
- **无 RTC**：`/debug` 报告时间用 uptime 回退（`os.date` 无 RTC 时返回 1970），接入游戏内时间同步后可显示真实时间
