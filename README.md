# MIE Agent — OpenComputers AI Agent 项目

在 Minecraft GTNH 服务器的 OpenComputers 中运行的单文件 AI 编码 agent。agent 通过 Internet Card 直连 LLM API（OpenAI 兼容），具备文件操作、硬件操控、代码执行与联网搜索能力。

## 核心文件

| 路径 | 说明 |
|------|------|
| `agent.lua` | **唯一需要部署到游戏内的文件**（单文件，含全部功能） |
| `docs/superpowers/specs/2026-07-28-oc-agent-design.md` | 设计文档（superpowers 流程产物） |
| `docs/superpowers/plans/2026-07-28-oc-agent.md` | 实现计划 |

## 功能一览

- **9 个 LLM 工具**：`read_file` / `write_file` / `list_directory` / `execute_lua` / `component_list` / `component_doc` / `component_invoke` / `web_search` / `shell_execute`
- **组件探索闭环**：list → doc → invoke，LLM 可自主发现并操控任意 OC 硬件
- **自举扩展**：LLM 通过 `execute_lua` + `write_file` 可创建新 Lua 模块，运行时扩展自身能力
- **联网搜索**：默认 HN Algolia（无 key），`/tavily <key>` 升级为通用搜索（含中文）
- **上下文持久化**：每条消息/工具结果即时保存，崩溃可恢复；50KB 双预算裁剪防内存膨胀
- **默认模型**：`deepseek-v4-flash-free`（OpenCode Zen 免费，无需 key）

## 部署

1. 将 `agent.lua` 上传到 OC 计算机（`wget` / `pastebin get` / 手动复制）
2. 运行 `lua agent.lua`
3. 首次引导直接回车接受默认（免费模型，无需 API key）

```lua
-- 游戏内命令
/model <model>        -- 切换模型
/key <api_key>        -- 设置 API key（留空用免费模型）
/url <endpoint>       -- 切换 API 端点
/tavily <key>         -- 启用 Tavily 通用搜索
/reset                -- 清空对话历史
```

## 目录结构

```
├── agent.lua              # 主程序（部署到游戏）
├── README.md
├── docs/
│   └── superpowers/       # 设计文档与实现计划
│       ├── specs/
│       └── plans/
├── test_harness/          # 测试脚本（本地 + 模拟器内）
│   ├── oc_mock.lua        # OC API mock（本地 Lua 环境）
│   ├── run_tests.lua      # 本地回归测试（48 项）
│   ├── capability_one.lua # LLM 能力边界测试（单任务模式）
│   ├── mem_test.lua       # 内存压力测试
│   ├── search_test.lua    # web_search 工具测试
│   ├── chat_test*.lua     # chat() 端到端测试
│   └── ...                # 其他诊断脚本
├── emulators/             # 第三方 OC 模拟器（游戏外测试环境）
│   ├── OCEmu/             # 真实 OC machine.lua 沙箱（Lua 5.2）
│   ├── ocvm/              # C++ 模拟器（Linux，含修复）
│   └── OpenComputersVM/   # JavaFX 模拟器（Windows GUI）
├── wiki/                  # OC wiki 离线镜像
│   ├── raw/               # DokuWiki 原始文本（215 页）
│   ├── markdown/          # Markdown 转换版（32 页）
│   └── reference/         # agent 开发精选 API 参考（35 文件）
├── tools/                 # Windows 辅助脚本
│   ├── capture_minecraft.py  # 捕获指定游戏窗口截图
│   ├── capture_screen.py     # 全屏截图
│   └── type_to_oc.py         # 向游戏窗口模拟按键
├── scripts/               # 一次性工具脚本
│   ├── doku2md.py         # DokuWiki 转 Markdown
│   └── download_images.py # 批量下载 wiki 图片
├── lua_portable/          # 便携 Lua 5.4（本地测试运行时）
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
