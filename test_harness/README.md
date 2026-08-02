# test_harness — 测试脚本

agent.lua 的测试套件：本地 mock 回归 + 模拟器（ocvm / OCEmu）内验证 + LLM 能力边界测试。

## 快速开始（本地回归）

```bash
# 需在 test_harness/ 目录内运行（脚本用相对路径加载 ../agent.lua）
../lua_portable/bin/lua.exe -e "package.path = './?.lua;' .. (package.path or '')" run_tests.lua
```

预期输出：`FINAL: 48 pass, 0 fail out of 48 tests`

## 脚本分类

### 本地单元测试（Lua 5.4 + mock，不联网）

| 脚本 | 用途 |
|------|------|
| `oc_mock.lua` | OC API 模拟层（component/computer/filesystem/shell/internet/serialization），`package.loaded` 注入 `require` |
| `run_tests.lua` | 主回归：JSON 编解码 26 项 + 工具执行 22 项（含 web_search/component_doc/component_invoke） |

### 模拟器内验证（部署到 ocvm / OCEmu 的 /mnt/<mount>/ 后运行）

| 脚本 | 用途 |
|------|------|
| `vm_test.lua` / `vm_test2.lua` | 早期验证：agent 加载 + JSON + 工具执行（v2 支持动态查找 agent.lua） |
| `chat_test*.lua` | chat() 端到端：`chat_test2.lua` 走 agent_test hooks（验证 tool_calls），`chat_test3.lua` 简版 |
| `search_test.lua` | web_search 工具直接调用（HN Algolia 真实搜索） |
| `mem_test.lua` | 4 轮工具密集对话 + freeMemory 追踪（验证无内存泄漏） |
| `http_test.lua` | internet.request GET/POST 裸测 |

### 能力边界测试（LLM 自主行为评估）

| 脚本 | 用途 |
|------|------|
| `capability_one.lua` | **单任务模式**（推荐）：`lua capability_one.lua <task> <key> <model> <url>`，结果实时 flush 到 `/mnt/*/cap_<task>.txt` |
| `capability_test.lua` | 旧版批量模式（5 任务顺序跑，易超时） |

任务编号：1=基础对话 2=文件读写 3=组件链(list→doc→invoke) 4=execute_lua 计算 5=多组件查询

### 历史诊断（开发期产物，保留参考）

`debug_*.lua`（io/print 行为探查）、`diag_go.lua`（HTTP 原始响应）、`trace*.lua`（逐步追踪）、`test_main.lua`（main() 崩溃捕获）

## 模拟器内运行方式

```bash
# 一键驱动（自动：重启 ocvm → 等 OpenOS 启动 → 上传 agent.lua+脚本 → 探测挂载 → 运行 → 拉取结果）
python ../tools/ocvm_test.py <测试脚本.lua> [脚本参数...]

# 例：
python ../tools/ocvm_test.py search_test.lua
python ../tools/ocvm_test.py newfeat_test.lua

# 手动方式（ocvm，挂载名每次重启会变，先 ls /mnt 确认）：
# 在 OpenOS shell 中：
lua /mnt/<挂载短名>/search_test.lua /mnt/<挂载短名> <api_key> <model> <api_url>
# 结果写入 /mnt/<挂载>/<脚本名>_result.txt，宿主机直接 cat 读取
```

测试脚本统一约定：
- 脚本首个参数 = 挂载路径（用作 dofile agent.lua 的 base），其后为自定义参数
- 结果写入挂载根的 `<脚本名>.txt`（capability_one 写 `cap_<task>.txt`）

## 测试约定

- agent.lua 加载时 `_TEST_MODE = true` 跳过 `main()`，暴露 `agent_test` 钩子表（chat/http_post/build_system_prompt/trim_history/TOOLS）
- 脚本内不用 `arg` 全局（OpenOS 的 lua 无此变量），参数用 `{...}` vararg
- 结果实时写入文件（OpenOS 崩溃时保留部分结果）
