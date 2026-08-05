# docs — 设计文档与实现计划

superpowers 工作流（brainstorming → writing-plans → executing-plans）的产物 + 横向对比。

## 目录结构

```
docs/
├── COMPARISON.md        # 与 oc-ai / pi / pi-subagents 的横向对比（含子代理能力对比）
└── superpowers/
    ├── specs/     # 设计文档（brainstorming 产物，实现前经用户审阅）
    └── plans/     # 实现计划（writing-plans 产物，任务级拆分）
```

## 文档索引

| 文件 | 阶段 | 说明 |
|------|------|------|
| `COMPARISON.md` | 对比 | agent.lua vs oc-ai（OC SDK）vs pi（TS harness）vs pi-subagents（子代理参考）|
| `specs/2026-07-28-oc-agent-design.md` | 设计 | OC Agent 完整设计：JSON/HTTP/工具/LLM/REPL 架构、硬件需求、风险 |
| `superpowers/plans/2026-07-28-oc-agent.md` | 计划 | 7 个任务的实现计划（JSON 编解码 → HTTP → 工具 → LLM → 配置 → REPL → 集成）|
| `superpowers/plans/2026-08-03-modular-split.md` | 计划 | 模块化拆分（4 阶段）：工具插件化 → 基础设施模块 → 核心装配 → 自举扩展验证 |

## 与现状的差异

计划/设计文档编写于开发初期，后续迭代引入了文档之外的内容：

- **新增工具**：`component_doc` / `component_invoke` / `web_search` / `json_query` / `calc` / `text_ops` / `edit_file` / `append_file` / `subagent_call`（原计划 6 工具 → 现 14 工具）
- **移除 execute_lua**：任意代码执行被数据处理工具集替代（安全 + 防 OOM）
- **子代理**：modem 组网跨机器委派 + session 会话复用（参考 opencode 会话模型与 pi-subagents 角色设计）
- **文件工具族**：read 行切片（offset/limit/tail）+ edit_file + append_file（内存恒定流式追加）
- **默认模型**：从 OpenRouter/gpt-4o-mini 改为 OpenCode Zen 免费模型
- **健壮性**：迭代器错误捕获、参数容错、yield 保护、内存三重裁剪、HTTP 自动重试（均源于模拟器/真实环境实测发现）
- **持久化**：append-only JSONL 会话日志（替代整表重写）+ anchored summary 增量压缩 + 会话归档
- **安装方式**：从"loot 磁盘"改为 GitHub 自动安装（install.lua 引导器，jsDelivr CDN + GitHub raw 双源）
- **工具调用性能优化**：deps 表模块级缓存（每次调用省去 2 次 require + 1 次表构造），LuaJ 环境下性能回归接近旧版 upvalue 直调
- **推理过程显示**：支持 DeepSeek 模型的 `reasoning_content` 字段，思考链先于回答打印
- **弱模型容错**：nil 保护 + pcall 包裹工具调用，格式错误的 tool_calls 不崩溃

核心架构（两级循环 + 工具契约 + 动态系统提示）与设计文档一致。
