# test_harness — 测试脚本

agent.lua 的测试套件：本地 mock 回归 + 模拟器（ocvm / OCEmu）内验证 + 子代理双实例集成测试。

## 快速开始（本地回归）

```bash
# 需在 test_harness/ 目录内运行（脚本用相对路径加载 ../agent.lua）
../lua_portable/bin/lua.exe -e "package.path = './?.lua;' .. (package.path or '')" run_tests.lua
```

预期输出：`FINAL: 122 pass, 0 fail out of 122 tests`

## 脚本分类

### 本地单元测试（Lua 5.4 + mock，不联网）

| 脚本 | 用途 |
|------|------|
| `oc_mock.lua` | OC API 模拟层（component/computer/filesystem/shell/internet/serialization/**event/modem**），`package.loaded` 注入 `require`；含 chat/completions 端点 mock 与 modem 环路事件队列 |
| `run_tests.lua` | 主回归：JSON 编解码 + 工具执行 + compaction + **append-only 会话日志** + **子代理协议/会话持久化**（122 项） |

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
| `perf_test.lua` | **工具调用性能监测**：循环 json_query/calc/text_ops/文件工具 N 次，对比新旧版本耗时 | `lua perf_test.lua <agent.lua路径> [循环次数]` |

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

- agent.lua 加载时 `_TEST_MODE = true` 跳过 `main()`，暴露 `agent_test` 钩子表（chat/http_post/build_system_prompt/trim_history/compact_history/should_compact/summarize_history/process_exchange/wait_modem_message/load_history/append_history/rebuild_history/set_history_path/TOOLS）
- 脚本内不用 `arg` 全局（OpenOS 的 lua 无此变量），参数用 `{...}` vararg
- 结果实时写入文件（OpenOS 崩溃时保留部分结果）
