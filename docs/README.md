# docs — 设计文档与实现计划

superpowers 工作流（brainstorming → writing-plans → executing-plans）的产物。

## 目录结构

```
docs/
└── superpowers/
    ├── specs/     # 设计文档（brainstorming 产物，实现前经用户审阅）
    └── plans/     # 实现计划（writing-plans 产物，任务级拆分）
```

## 文档索引

| 文件 | 阶段 | 说明 |
|------|------|------|
| `specs/2026-07-28-oc-agent-design.md` | 设计 | OC Agent 完整设计：JSON/HTTP/工具/LLM/REPL 架构、硬件需求、风险 |
| `plans/2026-07-28-oc-agent.md` | 计划 | 7 个任务的实现计划（JSON 编解码 → HTTP → 工具 → LLM → 配置 → REPL → 集成）|

## 与现状的差异

计划/设计文档编写于开发初期，后续迭代引入了文档之外的内容：

- **新增工具**：`component_doc` / `component_invoke` / `web_search`（原计划 6 工具 → 现 9 工具）
- **默认模型**：从 OpenRouter/gpt-4o-mini 改为 OpenCode Zen 免费模型
- **健壮性**：迭代器错误捕获、参数容错、yield 保护、内存三重裁剪（均源于模拟器/真实环境实测发现）
- **安装方式**：从"loot 磁盘"改为手动 wget/pastebin

核心架构（两级循环 + 工具契约 + 动态系统提示）与设计文档一致。
