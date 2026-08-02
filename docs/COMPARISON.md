# 三方对比：agent.lua vs oc-ai vs pi

本项目（agent.lua）与两个同领域开源项目的横向对比。oc-ai 与 pi 均为 git 克隆的参考源码（`oc-ai/`、`pi/`），不入版本控制。

## 概览

| 维度 | **agent.lua**（本项目） | **oc-ai**（DonChong2000） | **pi**（earendil-works） |
|------|------------------------|---------------------------|--------------------------|
| 定位 | OC 内运行的**独立 AI agent**（单文件部署） | OC 的 **AI SDK + 编码 agent**（`ai` 库 + `oc-code`） | 宿主机的**通用 agent harness**（TS 生态） |
| 语言 | Lua 5.2/5.3（OC 运行时） | Lua 5.2/5.3（OC 运行时） | TypeScript（Bun/Node） |
| 运行环境 | OC 计算机/机器人（游戏内） | OC 计算机/机器人（游戏内） | 桌面/服务器（CLI） |
| 形态 | 单文件 `agent.lua`，`require` 即用 | `lib/ai/*` 多模块库 + `bin/oc-code.lua` TUI | 多包 monorepo（`ai`/`agent`/`coding-agent`/`tui`） |
| 安装 | 手动 wget/pastebin 复制 | OPPM（`oppm install ai` / `oc-code`） | npm / bun install |
| 代码量 | ~900 行（单文件） | 库 + 示例（~数千行） | ~1797 行 agent-loop 核心 + 大量包 |

## 核心循环

| 维度 | agent.lua | oc-ai | pi |
|------|-----------|-------|-----|
| 主循环 | REPL（`/help`、`/model` 等）+ 内部两阶段循环（LLM 调用 → 工具执行 → 再调 LLM） | `generateText` 内建工具循环（`maxSteps` 上限），顶层由用户脚本驱动 | `agentLoop` 独立运行时（`agent-loop.ts`），事件流驱动，支持并行工具批处理 |
| 工具执行 | 顺序执行，结果回填历史 | 顺序执行（多步循环） | 顺序 + **并行批处理**（`executeToolCallsParallel`） |
| 循环终止 | 无 tool_calls 即停 | `maxSteps` 达限即停 | `shouldTerminateToolBatch` 判定 |
| 消息历史 | 持久化到 `/home/agent_history.txt`，串行化格式 | 调用方自行管理 | 状态管理在 agent runtime 内 |

## 工具系统

| 维度 | agent.lua | oc-ai | pi |
|------|-----------|-------|-----|
| 工具数量 | 11（read_file/write_file/list_directory/json_query/calc/text_ops/component_list/component_doc/component_invoke/web_search/shell_execute） | oc-code：7（read_file/write_file/edit_file/list_directory/glob/grep/shell） | 大量（文件/进程/网络/权限/插件…） |
| 工具声明 | 内置表 + 动态系统提示生成 | `ai.tool({...})` 声明式 + execute 回调 | `AgentTool` 类型化定义 |
| 组件感知 | 有（component_list/doc/invoke 三件套，动态生成提示） | 无（纯文件/shell 工具） | 无（OC 外） |
| 容错 | 参数解析 fallback + pcall 包裹 + 结果截断 | JSON decode pcall 包裹 | 工具调用失败标记 + 重试/截断恢复 |

## LLM Provider 支持

| 维度 | agent.lua | oc-ai | pi |
|------|-----------|-------|-----|
| 协议 | OpenAI 兼容（chat/completions） | OpenAI 兼容 + **SSE 流式** | OpenAI/Anthropic/Google/Bedrock 等统一层 |
| 默认端点 | OpenCode Zen 免费模型（无 key） | Vercel AI Gateway | 用户自带 key |
| 结构化输出 | 无（靠提示约束） | `Output.object` + `generateObject`（JSON schema） | 完整 schema 支持 |
| 流式 | 无 | 有（`streamText` + onChunk 回调） | 有（事件流） |

## OC 资源约束适配（本项目特有关注点）

| 约束 | agent.lua 处理 | oc-ai | pi |
|------|----------------|-------|-----|
| 内存（T3.5 = 1MB） | 三重裁剪：历史条数（MAX_HISTORY=20）+ 字节（50KB）+ 工具结果截断（3KB）；实测 2MB 下峰值 ~550KB 无泄漏 | 文档提醒"limited memory, avoid large buffers"，无主动裁剪 | 不适用（宿主机内存充足） |
| HTTP 迭代器 yield | 循环内 yield + pcall 包裹迭代器（防 5s 崩溃） | 同样需注意（OC 约束） | 不适用 |
| json.encode 大 payload | 已知限制：>50KB 不 yield，2MB 下理论 12-25K token | rxi/json.lua（同样不 yield） | 不适用 |

## 可借鉴点（agent.lua 的改进方向）

| 来自 | 可借鉴内容 | 优先级 |
|------|-----------|--------|
| oc-ai | `ai.tool()` 声明式工具注册（替代硬编码表）；SSE 流式输出；结构化输出（`Output.object`） | 中（流式对 OC 有 yield 风险，需实测） |
| oc-ai | `edit_file` 工具（行级编辑，替代整文件 write_file，省 token/内存） | 高 |
| oc-ai | OPPM 打包分发（`oppm register`） | 低（手动安装够用） |
| pi | 并行工具批处理（`executeToolCallsParallel`，当前工具相互独立时提速） | 中（OC 单线程，收益有限，需谨慎） |
| pi | 事件流驱动架构（为 TUI/日志/断点重续做铺垫） | 低（当前 REPL 够用） |
| pi | 工具调用失败恢复（truncated message → 重发或降级） | 中（目前失败即报错回传） |

## 结论

三个项目定位互补：**oc-ai 是 OC 生态内最成熟的 AI 库**（流式/结构化输出/声明式工具），**pi 是宿主机构建通用 agent 的参考架构**（并行工具/事件流/多 provider），**agent.lua 是唯一专为 OC 资源约束设计的单文件 agent**。对比后 agent.lua 已落地：移除 `execute_lua`（任意代码执行）并新增 `json_query`/`calc`/`text_ops` 数据处理工具集、HTTP 自动重试、对话摘要压缩（compaction）、会话归档（`/new`）。剩余改进方向：`edit_file` 行级编辑（省内存）与工具失败恢复机制。
