# OC Agent 模块化拆分计划

日期：2026-08-03 · 状态：计划（待批准执行）· 源文件：`agent.lua`（1757 行，10 个 section）

## 1. 背景与目标

单文件 agent.lua 已满 1757 行。拆分动机：

1. **增量更新**：现在每次更新都重下 71KB 单文件；拆分后只更新改动模块（几 KB）
2. **自举扩展**（核心收益）：单文件约束下移除了 `execute_lua` 导致 LLM 无法扩展自身；模块化后 LLM 可用 `write_file` 写新工具模块到 `tools/` 目录，下次启动自动注册——恢复原设计文档的插件愿景
3. **按需加载**：未用模块（如搜索）不常驻内存
4. **可维护性**：分文件 diff 清晰，故障定位快

约束：**保持 `lua agent.lua` 入口行为完全不变**（REPL / `--subagent` / 配置 / 历史全部兼容）；OpenOS 无 tar，多文件靠 install.lua 逐个 wget。

## 2. 现状分析（依赖图）

```
Section 1  json (全局表 json = {}；encode/decode)
Section 2  http_post_once → http_post（依赖 json）
Section 3  TOOLS 表（纯声明式 14 工具定义，无执行体）
Section 4  execute_tool（大 if/elseif 分派 14 个工具实现；依赖 json/http/execute_lua_code(禁用残留)/load_config(前向声明)）
Section 5  build_system_prompt / chat（依赖 http_post/TOOLS）
Section 5.5 summarize/compact/should_compact（依赖 chat）
Section 6  find_writable_base（顶层副作用！）→ WRITABLE_BASE/CONFIG_PATH/HISTORY_PATH/SESSIONS_DIR
           load_history/append_history/rebuild_history/save_config/first_run_setup
Section 7  handle_command + REPL（依赖全部）
Section 8  subagent 协议：wait_modem_message（Section 3 前）/load_session_history 族
Section 8.5 process_exchange（shared 循环）
main() 尾部 agent_test 钩子表（重绑 HISTORY_PATH 的 hack）

顶层状态（模块化最大障碍）：
- local TOOLS          ← Section 3，被 build_system_prompt/execute_tool/agent_test 引用
- local load_config    ← 前向声明（Section 3 注释），execute_tool 用它
- local WRITABLE_BASE / CONFIG_PATH / HISTORY_PATH / SESSIONS_DIR ← Section 6 顶层执行副作用
- json（全局表）        ← 所有 section 共用
- execute_lua_code     ← 577 行禁用残留（781 行调用处已封死）
```

依赖方向：1 → 2 → 3/4 → 5 → 5.5 → 6 → 7/8/8.5（线性，无环，天然适合模块链）。

## 3. 目标结构

```
/usr/agent/                    # 安装根（可写路径下，或 /usr/share/lua/5.3/agent/）
├── init.lua                   # 入口：require 各模块 + main 分派（原 Section 7/8.5 + main()）
├── json.lua                   # Section 1（json.encode/decode）
├── http.lua                   # Section 2（http_post，重试/yield 保护）
├── config.lua                 # Section 6 配置部分：load_config/save_config/first_run_setup/find_writable_base
├── session.lua                # Section 6 历史 + 5.5 compaction + 归档
├── tools.lua                  # Section 3 TOOLS 声明表 + 扫描 tools/ 目录注册
├── execute.lua                # Section 4 工具执行（分派到 tools/ 模块实现）
├── chat.lua                   # Section 5 LLM 客户端（chat/build_system_prompt/summarize）
├── subagent.lua               # Section 8 子代理协议（wait_modem_message/会话族）
└── tools/                     # 工具实现模块（每个导出 {name, tools, exec}）
    ├── file.lua               # read_file/write_file/edit_file/append_file/list_directory
    ├── data.lua               # json_query/calc/text_ops
    ├── component.lua          # component_list/doc/invoke
    ├── search.lua             # web_search
    └── shell.lua              # shell_execute
```

## 4. 模块接口（导出契约）

```lua
-- json.lua
return { encode = function(val) -> string, decode = function(str) -> val|nil,err }

-- http.lua
return { post = function(url, headers, body, timeout) -> code, resp, err }  -- 含重试

-- config.lua
return { load = function() -> config|nil, save = function(config), find_writable_base() -> path }
-- 初始化副作用：WRITABLE_BASE 探测在此模块加载时执行一次，缓存导出
-- 导出 { writable_base, config_path, history_path, sessions_dir }（测试可覆盖）

-- session.lua
return {
  load_history(), append_history(msg), rebuild_history(messages),
  compact_history(messages, config), should_compact(messages), summarize_history(...),
  set_paths(history_path)   -- 取代 agent_test 的 HISTORY_PATH 重绑 hack
}

-- tools.lua
return {
  list = function() -> TOOLS 声明表（合并内置 + tools/ 扫描注册）,
  register = function(tool_def)   -- 供工具模块注册
}

-- execute.lua
return { run = function(name, args_str) -> result_str,  register_impl = function(name, fn) }

-- chat.lua
return {
  chat = function(messages, config) -> text|nil, err,
  build_system_prompt = function(),
  summarize = function(messages, config, prev) -> summary
}

-- subagent.lua
return {
  wait_modem_message(timeout, reply_port) -> sender, port, payload,
  load_session(session), append_session(session, msg), rebuild_session(session, messages),
  SUBAGENT_LISTEN_PORT, SUBAGENT_REPLY_PORT, SUBAGENT_TIMEOUT
}

-- init.lua（入口）
-- require 链装配 + main() + 分派（无参数 → REPL；--subagent → 服务；测试 _TEST_MODE → 导出 agent_test 钩子）
```

## 5. 关键改造点

| # | 现状 | 改造 |
|---|------|------|
| 1 | `json` 全局表 | 改为模块返回值；所有引用处 `local json = require("agent.json")`（或入口注入局部） |
| 2 | `local load_config` 前向声明 | config.lua 模块在 execute.lua 加载时 require（依赖方向 6→4 反转，模块链自然解决） |
| 3 | 顶层副作用 `find_writable_base()` | 移到 config.lua 模块加载时执行；**但单文件模式也依赖它** → 构建脚本合并时保留原顺序 |
| 4 | `TOOLS` 内联声明 | tools.lua 内置 5 个基础工具 + `fs.list` 扫描 `tools/*.lua` 动态 require 注册（LLM 写模块 → 重启即注册） |
| 5 | execute_tool 大分派 | 每个工具实现移入对应模块，`execute.register_impl(name, fn)`；execute.lua 只剩 JSON 解析 + 分派骨架 |
| 6 | `agent_test` HISTORY_PATH 重绑 hack | session.lua 提供 `set_paths()`，钩子表直接调用（删 hack） |
| 7 | execute_lua_code 禁用残留 | 删除（577 行死代码 + 781 行封死分支）——本次拆分顺带清理 |
| 8 | 单文件兼容 | 新增 `scripts/build_single.lua`：按依赖顺序拼接模块 → 输出单文件 agent.lua（保持原分发路径可用） |

## 6. 部署方案（install.lua 扩展）

```
1. wget install.lua（不变，bootstrap 仍单文件）
2. install.lua 内嵌模块清单（init/json/http/config/session/tools/execute/chat/subagent + tools/*.lua）
3. 逐个下载到 <可写路径>/agent/（每文件独立校验大小；失败单文件重试 ×3）
4. 写入 package.path 引导：<可写路径>/agent/?.lua
5. 兼容：若单文件 agent.lua 已存在且更新 → 提示用户可切换到模块版（行为等价）
```

OpenOS 模块路径两种选择：
- **A（推荐）**：`<writable>/agent/` 自建目录 + 启动时 `package.path = writable .. "/agent/?.lua;" .. package.path`（对 `/home` 只读的服务器也通用）
- B：`/usr/share/lua/5.3/` 系统路径（需要写权限，服务器不一定有）

## 7. 测试适配

| 层 | 改动 |
|----|------|
| run_tests.lua（122 项） | 加载入口从 `dofile "../agent.lua"` 改为 `dofile "../init.lua"`（或 require agent.init）；模块加载依赖 oc_mock 的 `package.loaded` 注入（oc_mock 已支持） |
| oc_mock.lua | 补 `require("filesystem")` 的模块化加载（现在顶层 dofile 直接全局）；实际已注入 package.loaded 无需改 |
| 新增 `modular_test.lua` | 验证：模块扫描注册（临时写一个假工具模块 → 断言注册成功）、set_paths 替代 hack、模块加载顺序无环 |
| ocvm 集成 | `ocvm_test.py` 上传整目录（`agent/` 树）而非单文件——驱动脚本需支持目录上传 |
| 回归 | 122/122 必须保持；ocvm 单实例 REPL + 双实例 subagent 各重跑一遍 |

## 8. 分阶段执行

### Phase 1 — 工具插件化（核心收益，改动最小）
1. 抽出 tools/ 5 个模块（file/data/component/search/shell）：把 execute_tool 的 14 个分支体搬出，改为 `register_impl(name, fn)`
2. tools.lua 加目录扫描注册 + `register` 导出
3. 删除 execute_lua_code 死代码
4. 验证：122 项回归 + ocvm filetools_test/newfeat_test

### Phase 2 — 基础设施模块
1. json/http/config/session 四模块抽出（依赖链 1→2→6）
2. `set_paths()` 替代 agent_test 重绑 hack
3. 验证：122 项回归 + chat_test2（chat 端到端）

### Phase 3 — 核心装配
1. chat.lua / subagent.lua / init.lua（入口分派 REPL/subagent/_TEST_MODE）
2. `scripts/build_single.lua` 单文件构建
3. install.lua 多文件下载 + package.path 引导
4. 验证：本地回归 + ocvm REPL e2e + 双实例 subagent e2e + 全新安装 e2e（install.lua → 模块版运行）

### Phase 4 — 自举扩展验证（里程碑）
- ocvm 内：LLM 用 write_file 写 `tools/hello.lua`（自定义工具）→ 重启 → 工具自动注册并调用成功 → 证明插件机制闭环

## 9. 风险与对策

| 风险 | 对策 |
|------|------|
| require 在 OpenOS 的 package.path 细节（`/home` 只读服务器） | 自建目录方案 A + 安装时写引导（已验证 wiki `api_non-standard-lua-libs.txt` require 机制） |
| 顶层执行顺序变化改变行为（WRITABLE_BASE 探测时机） | 构建脚本保持合并顺序 = 单文件原顺序；模块版 init.lua 严格按依赖序 require |
| 工具模块扫描在 ocvm 挂载路径下路径拼接错误 | 模块加载用绝对路径（`<base>/agent/tools/`），不做 cwd 假设 |
| LLM 自举写坏模块导致启动崩溃 | tools/ 扫描注册用 pcall 包裹，坏模块跳过并告警（不阻塞主循环） |
| 双分发源（单文件/模块版）漂移 | build_single.lua 每次发布生成单文件 = 模块版完全一致；CI 前验证一致性 |

## 10. 验收标准

- [ ] 122 项本地回归全过（加载入口改为 init.lua）
- [ ] ocvm：REPL 对话 + 工具调用 + compaction 行为与单文件版一致
- [ ] ocvm 双实例 subagent 往返 + 会话复用通过
- [ ] 自举扩展闭环：LLM 写入新工具模块 → 重启自动注册 → 可调用
- [ ] install.lua 全新安装 e2e（服务器 /home 只读场景）
- [ ] build_single.lua 产物与模块版行为一致（回归对照）
