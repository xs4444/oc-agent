-- ═══════════════════════════════════════════════════════════════
-- agent.selftest — 实机自检（/selftest 命令）
--
-- 为什么存在: ocvm 层验证的是"模拟器行为"（4MB RAM、C++ 模拟的
-- internet/时钟），模拟层（run_tests）验证的是"代码路径"（mock
-- 硬编码响应）。真机（OpenComputers JVM + luajit + 2MB RAM + 真实
-- 网络）的行为两者都覆盖不到——os.clock CPU 时间、event.pull 多过滤
-- 语义、迭代器让出、JVM internet 时序，都是模拟层假阴性、ocvm 偶发
-- 假阴性的点。本模块嵌入式自检: agent.lua 已在真机（用户日常运行），
-- 零传输（无需上传脚本），/selftest 一键跑完写结果文件 + 可选 gist
-- 回传（复用 agent.debug.upload）。
--
-- 内存约束: 真机 2MB。每个测试独立 pcall + 每测 collectgarbage，
-- 大字符串（报告）最后才组装。
--
-- 测试项（真机能力设计）:
--   env    环境 sanity（OS/uptime/RAM/CPU/挂载盘）——验证环境识别
--   json   JSON roundtrip（空表/嵌套/转义边界）——真实 luajit 行为
--   fs     文件系统读写追加删除——真实 OpenOS 文件系统
--   session session 文件持久化 roundtrip
--   config config 存/取 roundtrip
--   net    真实 internet 小请求（GET api.github.com）——真实网络 +
--          http.lua 超时/重试链路（含 connection 挂起保护）
--   interrupt interrupt 补丁: install + timer 注入 + os.sleep 提前返回
--          （真机 JVM 事件时序——ocvm 已验证，真机最宝贵）
--   tools  TOOLS 清单（19 项齐全）
--   mem    内存预算 sanity（collectgarbage("count") vs 2MB）——GC 健康
-- ═══════════════════════════════════════════════════════════════

local M = {}

-- 结果收集（最后才拼大字符串; 中间只存小行）
local results = {}
local started = os.clock()

local function record(name, ok, detail)
  -- 同名覆盖（v0.3.91）: 线程超时放弃后线程可能仍在后台跑，迟到写入
  -- 会重复——按 name 覆盖，最终保留最后一次结果。
  for i, r in ipairs(results) do
    if r.name == name then
      results[i] = { name = name, ok = ok, detail = detail or "" }
      collectgarbage("collect")
      return
    end
  end
  results[#results + 1] = {
    name = name,
    ok = ok,
    detail = detail or "",
  }
  collectgarbage("collect")  -- 每测 gc（2MB 约束）
end

-- 所有测试经 pcall 包裹——单个崩溃不中断后续。
-- 成功路径: 测试函数内部自行 record（各函数只 record 一次）；
-- 崩溃路径: 这里兜底 record（防止"崩溃后无记录"）。
-- 线程化 + 超时（v0.3.91）: OC internet.request 连接阶段无超时
-- （v0.3.73 /debug 卡死教训: 连接挂起时 Lua 层不运行，Ctrl+C 补丁
-- 也无机会）——同步跑 net 测试会把整个 selftest 卡死只能重启。每项
-- 测试跑在 thread 里 + waitForAll(timeout) 超时 → 超时记 FAIL 继续
-- 下一项，任何一项卡住不影响整体。thread 不可用（测试/精简环境）
-- 回退同步执行。
local function run_test(name, fn, timeout_sec)
  local ok_th, thread = pcall(require, "thread")
  timeout_sec = timeout_sec or 30
  if not ok_th or not thread or not thread.create or not thread.waitForAll then
    local ok, err = pcall(fn)
    if not ok then
      record(name, false, "CRASH: " .. tostring(err))
    end
    return
  end
  local t = thread.create(fn)
  local ok_w, werr = pcall(thread.waitForAll, {t}, timeout_sec)
  if not ok_w or not werr then
    record(name, false, "TIMEOUT after " .. timeout_sec .. "s (线程卡住已放弃)")
  end
end

-- ════════════════════════════════════════
-- 1. env — 环境 sanity
-- ════════════════════════════════════════
local function test_env()
  local ok_c, computer = pcall(require, "computer")
  if not ok_c then record("env", false, "no computer lib: " .. tostring(computer)); return end
  local info = {}
  local ok_g, g = pcall(computer.getDeviceInfo)
  if ok_g and type(g) == "table" then
    for k, v in pairs(g) do
      if type(v) == "table" and v.description then
        info[#info + 1] = tostring(v.description)
      end
    end
  end
  local free, total = pcall(computer.freeMemory)
  local _, total_mem = pcall(computer.totalMemory)
  record("env", true,
    "uptime=" .. string.format("%.0f", computer.uptime())
    .. " free=" .. tostring(free) .. " total=" .. tostring(total_mem)
    .. " devices=" .. table.concat(info, "|"))
end

-- ════════════════════════════════════════
-- 2. json — roundtrip 边界（真实 luajit 行为）
-- ════════════════════════════════════════
local function test_json()
  local ok_j, json = pcall(require, "agent.json")
  if not ok_j then record("json", false, "no agent.json: " .. tostring(json)); return end
  -- 空表 encode（OC json.lua 历史: {} → [] 数组编码——真机行为验证）
  local ok1, e1 = pcall(json.encode, {})
  local d1 = ok1 and e1 or ("ERR: " .. tostring(e1))
  -- 嵌套 roundtrip
  local ok2, e2 = pcall(json.encode, {a = {b = {c = 1}}, d = "x\ny", e = true, f = nil})
  local r2 = "n/a"
  if ok2 then
    local ok3, d3 = pcall(json.decode, e2)
    r2 = ok3 and (tostring(d3 and d3.a and d3.a.b and d3.a.b.c)) or ("DECODE_ERR: " .. tostring(d3))
  else
    r2 = "ENCODE_ERR: " .. tostring(e2)
  end
  local ok4, e4 = pcall(json.encode, {n = 123456789012345})
  record("json", ok2 and ok4,
    "empty={}->" .. tostring(d1) .. " nested.c=" .. tostring(r2)
    .. " bigint=" .. tostring(ok4 and e4 or ("ERR: " .. tostring(e4))))
end

-- ════════════════════════════════════════
-- 3. fs — 文件系统读写（真实 OpenOS）
-- ════════════════════════════════════════
local function test_fs()
  local ok_cfg, cfg = pcall(require, "agent.config")
  if not ok_cfg or not cfg or not cfg.writable_base then
    record("fs", false, "no agent.config: " .. tostring(cfg)); return
  end
  local p = cfg.writable_base .. "/selftest_tmp.txt"
  local ok_w = pcall(function()
    local f = io.open(p, "w")
    f:write("SELFTEST_FS_12345\n")
    f:close()
  end)
  local readback = nil
  local ok_r = pcall(function()
    local f = io.open(p, "r")
    readback = f:read("*a")
    f:close()
  end)
  -- 追加
  local ok_a = pcall(function()
    local f = io.open(p, "a")
    f:write("APPEND_67890\n")
    f:close()
  end)
  -- 追加后重读（验证 append 真实生效）
  local readback2 = nil
  local ok_r2 = pcall(function()
    local f = io.open(p, "r")
    readback2 = f:read("*a")
    f:close()
  end)
  -- 清理
  pcall(os.remove, p)
  record("fs", ok_w and ok_r and ok_a and ok_r2
    and readback == "SELFTEST_FS_12345\n"
    and readback2 == "SELFTEST_FS_12345\nAPPEND_67890\n",
    "write=" .. tostring(ok_w) .. " read=" .. tostring(ok_r)
    .. " append=" .. tostring(ok_a) .. " r2=" .. tostring(ok_r2)
    .. " got=" .. tostring(readback2):gsub("\n", "\\n"))
end

-- ════════════════════════════════════════
-- 4. session — 会话文件持久化 roundtrip
--    （agent.session 基于"当前路径"（set_paths/set_sessions_dir 设置），
--     append_history(msg)/load_history() 无 per-path 变参——测试借
--     set_sessions_dir 指向临时目录，跑完恢复。改路径会改变 agent 的
--     会话文件位置——只在测试期改，结束后恢复原值。）
-- ════════════════════════════════════════
local function test_session()
  local ok_s, session = pcall(require, "agent.session")
  if not ok_s then record("session", false, "no agent.session: " .. tostring(session)); return end
  local ok_cfg, cfg = pcall(require, "agent.config")
  if not ok_cfg or not cfg or not cfg.writable_base then
    record("session", false, "no config"); return
  end
  local orig_dir = session.get_sessions_dir and session.get_sessions_dir()
  local tmp_dir = cfg.writable_base .. "/selftest_sess"
  pcall(session.set_sessions_dir, tmp_dir)
  -- 清残留（tmp_dir 下的 session 文件）
  pcall(function()
    local ok_fs, fs = pcall(require, "filesystem")
    if ok_fs and fs then
      for item in fs.list(tmp_dir) do
        pcall(os.remove, tmp_dir .. "/" .. item)
      end
    end
  end)
  -- 追加两条 + 重读
  local ok_a1 = pcall(session.append_history, {role = "user", content = "FIRST_LINE"})
  local ok_a2 = pcall(session.append_history, {role = "user", content = "SECOND_LINE"})
  local lines = nil
  local ok_l = pcall(function()
    lines = session.load_history()
  end)
  -- 恢复原会话目录
  if orig_dir then pcall(session.set_sessions_dir, orig_dir) end
  -- 判定: load 回 2 条（content 匹配）
  local content_match = ok_l and type(lines) == "table" and #lines >= 2
  if content_match then
    content_match = false
    local found1, found2 = false, false
    for _, m in ipairs(lines) do
      if m and m.content == "FIRST_LINE" then found1 = true end
      if m and m.content == "SECOND_LINE" then found2 = true end
    end
    content_match = found1 and found2
  end
  record("session", ok_a1 and ok_a2 and content_match,
    "append=" .. tostring(ok_a1) .. "/" .. tostring(ok_a2)
    .. " load=" .. tostring(ok_l) .. " n=" .. tostring(type(lines) == "table" and #lines or "?"))
end

-- ════════════════════════════════════════
-- 5. config — 存/取 roundtrip
-- ════════════════════════════════════════
local function test_config()
  local ok_cfg, cfg = pcall(require, "agent.config")
  if not ok_cfg or not cfg then record("config", false, "no agent.config: " .. tostring(cfg)); return end
  local ok_l, loaded = pcall(cfg.load)
  if not ok_l then record("config", false, "load crash: " .. tostring(loaded)); return end
  -- 存在性 + 类型 sanity（不写回——不动用户配置）
  local t = type(loaded)
  local has_api = type(loaded) == "table" and loaded.api_key ~= nil
  record("config", ok_l and (type(loaded) == "table"),
    "type=" .. tostring(t) .. " has_api_key=" .. tostring(has_api))
end

-- ════════════════════════════════════════
-- 6. net — 真实 internet 小请求（GET，验证网络 + http 超时链路）
-- ════════════════════════════════════════
local function test_net()
  local ok_h, http = pcall(require, "agent.http")
  if not ok_h then record("net", false, "no agent.http: " .. tostring(http)); return end
  -- 短超时配置（测试不长时间挂起; http.lua 的 120s 读超时对自检太久）
  -- http.post 用默认 retry_budget; GET 走 internet.request 原始 API
  local ok_i, internet = pcall(require, "internet")
  if not ok_i then record("net", false, "no internet lib: " .. tostring(internet)); return end
  local ok_c, computer = pcall(require, "computer")
  local timeout = 20  -- 秒（自检用短超时）
  local handle = nil
  local ok_open = pcall(function()
    handle = internet.request("https://api.github.com/zen", nil, {["User-Agent"] = "oc-agent-selftest"})
  end)
  if not ok_open or not handle then
    record("net", false, "connect fail: " .. tostring(handle)); return
  end
  -- 迭代读取（带 deadline——http.lua 同款挂起保护）
  local chunks = {}
  local deadline = (ok_c and computer.uptime() or os.clock()) + timeout
  local now_fn = ok_c and computer.uptime or os.clock
  local ok_iter = true
  local iter_err = nil
  for chunk in handle do
    chunks[#chunks + 1] = chunk
    if now_fn() > deadline then
      iter_err = "read timeout after " .. timeout .. "s"
      break
    end
  end
  local body = table.concat(chunks)
  -- 验证: 返回非空（api.github.com/zen 返回一句话）
  record("net", body ~= nil and #body > 0,
    "body_len=" .. tostring(#body) .. " head=" .. tostring(body):sub(1, 40)
    .. (iter_err and (" iter_err=" .. tostring(iter_err)) or ""))
end

-- ════════════════════════════════════════
-- 7. interrupt — 补丁 + timer 注入 + 提前返回
--    （真机 JVM 事件时序——ocvm 已验证，真机最宝贵）
-- ════════════════════════════════════════
local function test_interrupt()
  local ok_i, interrupt = pcall(require, "agent.interrupt")
  if not ok_i then record("interrupt", false, "no agent.interrupt: " .. tostring(interrupt)); return end
  local ok_c, computer = pcall(require, "computer")
  local ok_e, event = pcall(require, "event")
  if not (ok_c and ok_e) then record("interrupt", false, "computer/event missing"); return end
  interrupt.install()
  local up0 = computer.uptime()
  local timer_id = event.timer(0.5, function()
    computer.pushSignal("interrupted")
  end)
  local t0 = os.clock()
  os.sleep(2)  -- 应被 0.5s 的 interrupted 提前打断
  local dt = os.clock() - t0
  local flag = interrupt.poll()
  interrupt.clear()
  pcall(event.cancel, timer_id)
  -- 判定: flag 已置（事件链路通）且返回快（提前打断）或至少 flag 置位
  record("interrupt", flag and dt < 1.5,
    "flag=" .. tostring(flag) .. " dt=" .. string.format("%.2f", dt)
    .. " (expect <1.5 if early-return, ~2 if full wait)")
end

-- ════════════════════════════════════════
-- 8. patch — OpenOS 运行时补丁在位检查（v0.3.99）
--    P0 可中断 os.sleep（agent.interrupt.installed）
--    P1 internet.request 连接超时（CONNECT_TIMEOUT 常量存在 + 包装已装）
--    P2 墙钟 now() 可用（uptime 优先——os.clock CPU 时间残留修复）
-- ════════════════════════════════════════
local function test_patch()
  local ok_p, patch = pcall(require, "agent.patch")
  if not ok_p then record("patch", false, "no agent.patch: " .. tostring(patch)); return end
  -- P2: now() 可用且返回数字
  local ok_n, n = pcall(patch.now)
  -- P0: interrupt 补丁已安装（os.sleep 已替换）
  local ok_i, interrupt = pcall(require, "agent.interrupt")
  local installed = ok_i and interrupt and interrupt.installed == true
  -- P1: 连接超时常量在位（包装在 install 时装配，常量是模块级）
  local has_ct = type(patch.CONNECT_TIMEOUT) == "number"
  record("patch", ok_n and type(n) == "number" and installed and has_ct,
    "now=" .. tostring(ok_n and n) .. " interrupt_installed=" .. tostring(installed)
    .. " connect_timeout=" .. tostring(has_ct))
end

-- ════════════════════════════════════════
-- 9. tools — TOOLS 清单齐全（11 项）
-- v0.3.124: 从 19 精简到 11——删 list_directory/glob（OpenOS 有
-- ls/find）、json_query/calc/text_ops（模型自身能力）、component_*
-- 三件（OpenOS 有 `components` 命令 + lua -e 调组件）。
-- ════════════════════════════════════════
local function test_tools()
  local ok_t, tools = pcall(require, "agent.tools")
  if not ok_t then record("tools", false, "no agent.tools: " .. tostring(tools)); return end
  local ok_l, list = pcall(tools.list)
  if not ok_l or type(list) ~= "table" then record("tools", false, "list fail"); return end
  local names = {}
  for _, t in ipairs(list) do
    local n = t and t["function"] and t["function"].name
    if n then names[#names + 1] = n end
  end
  local EXPECTED = {
    "read_file","edit_file","append_file","write_file","search_files",
    "web_search","shell_execute","subagent_call","subagent_discover",
    "ask_user","compact_history",
  }
  local missing = {}
  for _, e in ipairs(EXPECTED) do
    local found = false
    for _, n in ipairs(names) do if n == e then found = true break end end
    if not found then missing[#missing + 1] = e end
  end
  record("tools", #missing == 0 and #names == 11,
    "count=" .. #names .. " missing=" .. (#missing > 0 and table.concat(missing, ",") or "none"))
end

-- ════════════════════════════════════════
-- 9. mem — 内存预算 sanity（2MB 真机约束）
-- ════════════════════════════════════════
local function test_mem()
  local ok_c, computer = pcall(require, "computer")
  if not ok_c then record("mem", false, "no computer lib"); return end
  collectgarbage("collect")
  local ok_f, free = pcall(computer.freeMemory)
  local ok_t, total = pcall(computer.totalMemory)
  local used = (ok_t and total or 0) - (ok_f and free or 0)
  local pct = used / math.max(1, total or 1) * 100
  -- 真机 2MB: 占用 >85% 视为危险（agent 常驻 + 系统）
  record("mem", ok_f and ok_t and pct < 85,
    string.format("free=%.0f used=%.0f total=%.0f (%.0f%%)", free or 0, used, total or 0, pct))
end

-- ════════════════════════════════════════
-- 执行器
-- ════════════════════════════════════════
M.run = function()
  results = {}
  -- 每项超时（线程化，v0.3.91）: 单项卡住（如 net 连接挂起）30s 自动
  -- FAIL 继续，不再需要重启。interrupt 项含 os.sleep(2) 预期耗时，给
  -- 15s 裕量。
  run_test("env", test_env, 15)
  run_test("json", test_json, 15)
  run_test("fs", test_fs, 15)
  run_test("session", test_session, 15)
  run_test("config", test_config, 15)
  run_test("net", test_net, 30)
  run_test("interrupt", test_interrupt, 15)
  run_test("patch", test_patch, 15)
  run_test("tools", test_tools, 15)
  run_test("mem", test_mem, 15)
  -- 组装报告（最后才拼大字符串）
  local lines = {
    "OC Agent selftest — " .. os.date("%Y-%m-%d %H:%M"),
    "elapsed " .. string.format("%.1fs", os.clock() - started),
  }
  local pass = 0
  for _, r in ipairs(results) do
    if r.ok then pass = pass + 1 end
    lines[#lines + 1] = (r.ok and "PASS" or "FAIL") .. " " .. r.name
      .. (r.detail ~= "" and (" — " .. r.detail) or "")
  end
  lines[#lines + 1] = "RESULT: " .. pass .. "/" .. #results .. " pass"
  return table.concat(lines, "\n")
end

return M
