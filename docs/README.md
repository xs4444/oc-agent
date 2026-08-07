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

- **新增工具**：`component_doc` / `component_invoke` / `web_search` / `json_query` / `calc` / `text_ops` / `edit_file` / `append_file` / `subagent_call` / `ask_user`（原计划 6 工具 → 现 15 工具）
- **移除 execute_lua**：任意代码执行被数据处理工具集替代（安全 + 防 OOM）
- **子代理**：modem 组网跨机器委派 + session 会话复用（参考 opencode 会话模型与 pi-subagents 角色设计）
- **文件工具族**：read 行切片（offset/limit/tail）+ edit_file + append_file（内存恒定流式追加）
- **默认模型**：从 OpenRouter/gpt-4o-mini 改为 OpenCode Zen 免费模型
- **健壮性**：迭代器错误捕获、参数容错、yield 保护、内存三重裁剪、HTTP 自动重试（均源于模拟器/真实环境实测发现）
- **持久化**：append-only JSONL 会话日志（替代整表重写）+ anchored summary 增量压缩 + 会话归档
- **安装方式**：从"loot 磁盘"改为 GitHub 自动安装（update.lua 一键更新 → 查 jsDelivr data API 最新 tag → 不可变 tag URL 下载；install.lua 多文件安装 + 增量更新 + PATH 启动器）
- **工具调用性能优化**：deps 表模块级缓存（每次调用省去 2 次 require + 1 次表构造），LuaJ 环境下性能回归接近旧版 upvalue 直调
- **推理过程显示**：支持 DeepSeek 模型的 `reasoning_content` 字段，思考链先于回答打印
- **弱模型容错**：nil 保护 + pcall 包裹工具调用，格式错误的 tool_calls 不崩溃
- **shell_execute 输出捕获 + 超时**：io.popen 捕获 stdout+stderr（原来只返回退出状态布尔）；thread + waitForAll 超时保护（默认 60s，挂起命令自动 kill；ocvm/OCEmu 双模拟器真机验证 9/9）
- **提问工具 ask_user**：仿 opencode question——对话中向用户提问（选项编号/自定义输入），REPL 阻塞等待，subagent 自动禁用
- **诊断上报 /debug**：收集版本+脱敏配置+最近 30 条历史 → 本地文件 + GitHub Gist 上传（`/gist-token` 配置，gist scope；token 完全遮蔽）
- **高危场景测试**：danger_test.lua 21 项（自我修改/坏插件/死循环/磁盘写满/配置损坏/删除自身/递归调用），本地安全模拟验证 agent 鲁棒性
- **已知平台限制**：纯 CPU 死循环（永不 yield）在 OpenOS 协作式调度下饿死主线程，任何 Lua 层超时无法中断——真实 OC 有机器级看门狗（computer.timeout，默认 5s）兜底，ocvm 模拟器无此机制
- **上下文仪表盘 /ctx**：显示 provider 上报的真实 tokens + 窗口百分比 + ANSI 进度条（绿/黄/红分级）+ 消息构成估算 + 压缩状态；每次响应后自动显示 `[ctx]` 一行（`ctx_auto=false` 可关）；`context_window` 配置（默认 128000）
- **400 防护**：请求前 token 预算（超 80% 窗口自动压缩；压缩失败 LLM 已超限时强制裁剪保留最近）+ HTTP 400 条件重试（仅估算真超限才裁剪，其他原因保留现场）——修复"工具结果/上下文累积 → 400 死循环"
- **reasoning_content 传回**：DeepSeek/Kimi thinking mode 的思考内容随历史完整传回（网关要求缺失即 400，官方 issue 机制）；此前只打印不存历史导致工具链延续 400
- **JSON 控制字符转义**：全控制字符（\x00-\x1f、\x7f）转义为 \u00XX——裸控制字符产出非法 JSON，服务端 400（实测 0.7% 上下文时的 400 即此因）
- **多行输入 /ml**：逐行收集到 EOF 合并为一条消息（粘贴多行代码场景；OC 无 bracketed paste，ocvm 精简 OpenOS 无 term.paste 处理，逐行最稳）
- **离线文档 docs.lua**：GTNH wiki markdown 可选下载（纯 Lua ustar 解包，零依赖）；交互引导安装（候选盘容量/系统盘排除）+ 卸载 + status；docs.json 版本对比跳过重复下载；v0.3.3 起纳入分发清单（update.lua 自动更新）
- **发版自动化**：build_all.py（构建+清单+163 项回归）→ release_check.py（版本 bump/清单/字节/语法检查）→ watch_release.py（jsDelivr 索引监控）——杜绝 v0.3.2 类"版本未 bump 服务器嗅探不到"事故
- **前缀缓存计费优化**：system prompt 静态化（进程内 memoize，字节稳定）+ uptime/freeMemory/组件列表移入请求尾部 runtime 块 → 前缀缓存命中（讯飞 kimi k2.6 实测 2432/2669 = 91%）；`/ctx`/`[ctx]` 显示缓存命中率（兼容 DeepSeek 与 OpenAI 新格式 usage 字段）；trim_history/force_trim 保留首条消息锚定缓存前缀；http 重试改为 opencode 风格指数退避（总预算 1 小时，测试环境 60s）

核心架构（两级循环 + 工具契约 + 动态系统提示）与设计文档一致。
