# test_harness — 测试脚本

agent.lua 的测试套件：本地 mock 回归 + 模拟器（ocvm / OCEmu）内验证 + 子代理双实例集成测试。

## 快速开始（本地回归）

```bash
# 需在 test_harness/ 目录内运行（脚本用相对路径加载 ../agent.lua）
../lua_portable/bin/lua.exe -e "package.path = './?.lua;' .. (package.path or '')" run_tests.lua

# 或从仓库根一键（构建 + 清单 + 对产物跑回归）：
python scripts/build_all.py
```

预期输出：`FINAL: 234 pass, 0 fail out of 234 tests`

## 脚本分类

### 本地单元测试（Lua 5.4 + mock，不联网）

| 脚本 | 用途 |
|------|------|
| `oc_mock.lua` | OC API 模拟层（component/computer/filesystem/shell/internet/serialization/**event/modem/thread**），`package.loaded` 注入 `require`；含 chat/completions 端点 mock 与 modem 环路事件队列 |
| `run_tests.lua` | 主回归（**234 项**）：JSON 编解码（含**控制字符 \u00XX 转义**）+ 工具执行 + compaction + **append-only 会话日志** + **子代理协议/会话持久化** + **TOOLS 显式清单双向校验**（18 项，含 search_files/glob）+ **/ctx 仪表盘**（tokens/进度条三色/构成/缓存命中率）+ **400 防护**（预算压缩/强制裁剪）+ **多行输入收集** + **前缀缓存静态性**（system prompt 字节稳定/尾部 runtime 块/首消息锚定）+ **KEEP/REF 标记**（摘要内嵌原文/引用指针/越界/截断）+ **模型驱动压缩**（compact_history 工具/占用注入尾部块/60-80% 不自动压缩）+ **Shell 护栏**（Unix-ism 拒绝/裸 lua REPL）+ **TUI 纯逻辑**（换行/角色色/滚动/补全）+ **工具轮次上限**（触顶收尾/丢弃 tool_calls）+ **reasoning-only 接受/空答重试** + **length 截断防呆** |
| `wire_check.lua` | 本地 mock 捕获 chat() 请求体：核对 tools 数组声明（15 工具在列）+ 系统提示内容（ask_user/离线文档段存在性） |
| `ustar_check.lua` | 离线文档包 ustar 解析器本地验证（269 条目 / 无 CRLF / 关键文件存在） |
| `plugin_test.lua` | 插件注册：临时目录写假模块 → scan_dir 注册 → 调用 → 坏模块跳过（12 项） |
| `danger_test.lua` | **高危场景鲁棒性**（21 项）：自修改/坏插件/死循环/磁盘写满/配置损坏/删除自身/递归调用，全部隔离临时目录安全模拟 |
| `perf_test.lua` | 工具调用性能对比：循环 json_query/calc/text_ops/文件工具 N 次，比较新旧版本耗时 |

### 模拟器内验证（部署到 ocvm / OCEmu 的 /mnt/<mount>/ 后运行）

| 脚本 | 用途 |
|------|------|
| `newfeat_test.lua` | 新工具（json_query/calc/text_ops）+ compaction + chat e2e 综合验证 |
| `filetools_test.lua` | 文件工具族：read 行切片/edit_file/append_file 全路径验证 |
| `chat_test*.lua` | chat() 端到端：`chat_test2.lua` 走 agent_test hooks（验证 tool_calls），`chat_test3.lua` 简版 |
| `search_test.lua` | web_search 工具直接调用（HN Algolia 真实搜索） |
| `mem_test.lua` | 4 轮工具密集对话 + freeMemory 追踪（验证无内存泄漏） |
| `http_test.lua` | internet.request GET/POST 裸测 |
| `vm_test.lua` / `vm_test2.lua` | 早期验证：agent 加载 + JSON + 工具执行 |

### 子代理集成测试（双实例 ocvm 组网）

| 脚本 | 用途 |
|------|------|
| `subagent_test.lua` | 基础往返：主代理发任务 → 子代理 LLM 处理 → 结果回传（SUBAGENT_PONG） |
| `subagent_session_test.lua` | **会话复用**：同 session_id 两次调用延续上下文（密码回忆），fresh 会话隔离 |

运行方式：两台 ocvm 实例共享 system port 56000 即同网络；子代理侧 `lua agent.lua -- --subagent`，主代理侧 `lua subagent_test.lua <base> <子代理modem地址>`（地址在子代理的 `subagent_address.txt`）。

### 能力边界测试（LLM 自主行为评估）

| 脚本 | 用途 |
|------|------|
| `capability_one.lua` | **单任务模式**（推荐）：`lua capability_one.lua <task> <key> <model> <url>`，结果实时 flush 到 `/mnt/*/cap_<task>.txt` |
| `capability_test.lua` | 旧版批量模式（5 任务顺序跑，易超时） |

任务编号：1=基础对话 2=文件读写 3=组件链(list→doc→invoke) 4=execute_lua 计算 5=多组件查询

| `modular_ocvm_test.lua` | **模块化 e2e**：验证多文件 require 链 + 插件自举闭环（写模块→注册→调用→坏模块跳过） | 22 项 |
| `shell_timeout_test.lua` | **shell_execute 超时真机验证**（ocvm/OCEmu，9 项）：挂起命令 3s 超时 kill → agent 恢复 → 正常命令 stdout 捕获断言（io.popen 行为） |
| `ask_user_test.lua` | **ask_user 工具 e2e**：提示词"尝试调用 ask_user 工具"→ 断言 AI 声明调用（deepseek-v4-flash 实测 PASS，question+options 参数正确） |
| `reasoning_e2e_test.lua` | **reasoning_content 传回 e2e**：完整工具链（thinking 输出 + calc 调用 + 第二轮请求带 reasoning_content）→ 无 400（3/3） |
| `json_ctrl_e2e_test.lua` | **JSON 控制字符修复 e2e**：tool 结果含 \x00/\x1b 的合法消息序列 → 真实端点 200（修复前 400） |
| `ctx_display_test.lua` | **/ctx 渲染真机验证**：加载 + ANSI 进度条 + 消息构成输出（无网络依赖） |
| `cache_e2e_test.lua` | **前缀缓存命中真机 e2e**：两次顺序 chat() 请求 → 断言尾部 runtime 消息被端点接受 + 第 2 次请求缓存命中 >0（兼容 DeepSeek/OpenAI 新格式字段；讯飞 kimi k2.6 实测 91% 命中） |
| `tui_smoke_test.lua` | **TUI 真机冒烟**：agent 加载 + tui 模块 + 真实 GPU 渲染（分辨率/单色检测/角色消息/滚动/清理）；ocvm 环境不稳定时以 `gpu_probe.lua`/`cursor_probe.lua` 单独验证 API |
| `test_docs_lua.lua` | **docs.lua 端到端**（注入假网络）：版本对比跳过（tar 只下载一次）+ ustar 解压 269 文件 + version.txt |
| `test_docs_interact.lua` | **docs.lua 交互引导全流程**（10 项）：路径安装/status 检测/交互选盘/交互卸载/卸载后确认 |
| `thread_diag_test.lua` | **协作式调度诊断**：确认纯 CPU 死循环（`while true do end` 永不 yield）在 OpenOS 中饿死主线程，任何 Lua 层超时无法中断（平台限制，真实 OC 同样如此） |

### 插件/自举测试

| 脚本 | 用途 |
|------|------|
| `plugin_test.lua` | **插件注册测试**：临时目录写假模块 → scan_dir 注册 → 调用 → 坏模块跳过（12 项） |

`debug_*.lua`（io/print 行为探查）、`diag_go.lua`（HTTP 原始响应）、`trace*.lua`（逐步追踪）、`test_main.lua`（main() 崩溃捕获）

## 模拟器内运行方式

```bash
# 一键驱动（自动：重启 ocvm → 等 OpenOS 启动 → 上传 agent.lua+脚本 → 探测挂载 → 运行 → 拉取结果）
python ../tools/ocvm_test.py <测试脚本.lua> [脚本参数...]

# 例：
python ../tools/ocvm_test.py search_test.lua
python ../tools/ocvm_test.py newfeat_test.lua
python ../tools/ocvm_test.py filetools_test.lua

# 额外上传文件（docs.lua 安装包、离线文档 tar 等，逗号分隔）：
EXTRA_FILES=../docs.lua,../docs_pack/oc-docs.tar,../docs_pack/docs.json \
  python ../tools/ocvm_test.py test_docs_lua.lua

# 结果自动保存到 test_harness/results/<脚本>_result.txt（屏幕输出 + 本地文件双份）

# 性能对比（本地 mock 环境测相对差异）
../lua_portable/bin/lua.exe -e "package.path = './?.lua;' .. (package.path or '')" perf_test.lua ../old_agent.lua 2>&1 | grep iters
../lua_portable/bin/lua.exe -e "package.path = './?.lua;' .. (package.path or '')" perf_test.lua ../agent.lua 2>&1 | grep iters

# 手动方式（ocvm，挂载名每次重启会变，先 ls /mnt 确认）：
# 在 OpenOS shell 中：
lua /mnt/<挂载短名>/search_test.lua /mnt/<挂载短名> <api_key> <model> <api_url>
# 结果写入 /mnt/<挂载>/<脚本名>.txt，宿主机直接 cat 读取
```

测试脚本统一约定：
- 脚本首个参数 = 挂载路径（用作 dofile agent.lua 的 base），其后为自定义参数
- 结果写入挂载根的 `<脚本名>.txt`（capability_one 写 `cap_<task>.txt`）
- 注意 OpenOS 的 lua 会吞掉 `--` 开头的参数（`lua agent.lua -- --subagent` 需 `--` 分隔符）；Windows 上传的脚本必须 LF 行尾（CRLF 会破坏 Lua 字符串）

## 测试约定

- agent.lua 加载时 `_TEST_MODE = true` 跳过 `main()`，暴露 `agent_test` 钩子表（chat/http_post/build_system_prompt/**build_runtime_block**/trim_history/compact_history/should_compact/summarize_history/process_exchange/wait_modem_message/load_history/append_history/rebuild_history/set_history_path/cmd_ctx/estimate_tokens/ctx_bar/show_ctx_line/**cache_stats**/collect_multiline/ensure_context_budget/force_trim/TOOLS）
- TOOLS 断言：`run_tests.lua` 定义 `EXPECTED_TOOLS` 显式清单（15 项），双向校验（无缺失 + 无多余）——**新增工具必须在清单登记**，否则测试失败
- 脚本内不用 `arg` 全局（OpenOS 的 lua 无此变量），参数用 `{...}` vararg
- 结果实时写入文件（OpenOS 崩溃时保留部分结果）；ocvm 驱动自动保存副本到 `results/`（gitignored）
