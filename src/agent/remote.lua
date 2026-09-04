-- ═══════════════════════════════════════════════════════════════
-- agent.remote — 远程控制守护（v0.3.125）。
--
-- 后台线程经 internet 卡 long-poll 外部控制服务器（tools/
-- remote_server.py），取命令 → 用现有工具注册表执行（ping/exec/
-- read/write/list，护栏随 execute.run 生效）→ 回传结果。让外部
-- 自动化（DSH）无需在游戏内交互即可对真机做基础读写执行。
--
-- 配置（agent_config.txt）: remote_url = "http://host:port"（不带
-- 尾部路径）, remote_token = "..."。两者齐备时 main() 引导自启；
-- TUI: /remote | /remote on | /remote off | /remote url <u> |
-- /remote token <t>。
--
-- 协议（与 tools/remote_server.py 对应）:
--   GET  /poll?token=T        服务器 hold ≤12s；{"id","op","args"}
--                             或 {"op":"noop"}
--   POST /report?token=T&id=I  body {"ok":bool,"result":"..."}
--
-- 硬约束与对策:
--   - OC 网卡只能主动发 HTTP（不能监听）→ 轮询方向必须是 agent→服务器
--   - long-poll hold（12s）< 客户端读 deadline（30s）< patch P1 的
--     internet.request 包装无冲突（localhost 连接瞬时）；真机 JVM
--     internet GET 无 read timeout（patch.lua 注释实证），hold 安全
--   - 结果截断 MAX_RESULT（64KB）——读大文件用 read 的 offset/limit 分页
--   - 失败退避 2s→60s 封顶；成功即复位
--   - 中断（Ctrl+C 给 TUI 的）对守护 = clear + continue（守护必须
--     活过 TUI 的 Ctrl+C，与 http.lua 的中断即终止不同语义）
--   - print 只打状态迁移（started/stopped/error 首报+每 10 次）——
--     TUI 模式下 print 进内容区，高频打会刷屏
-- ═══════════════════════════════════════════════════════════════

local json = require("agent.json")
local execute_mod = require("agent.execute")
local interrupt = require("agent.interrupt")
local patch = require("agent.patch")
local now = patch.now

local POLL_TIMEOUT = 30      -- poll 读 deadline（秒）: 连接后 30s 无响应判超时
local BACKOFF_BASE = 2       -- 失败退避基数（秒）
local BACKOFF_CAP = 60       -- 退避封顶（秒）
local MAX_RESULT = 65536     -- 回传结果截断（字节）: 64KB
local MAX_POLL_BODY = 131072 -- poll 响应体上限（字节）: 命令 JSON 应远小于此

-- 状态表（/remote 命令透出）
local state = {
  running = false,
  thread = nil,
  stop_flag = false,
  polls = 0,
  cmds = 0,
  errors = 0,
  report_errors = 0,
  last_op = nil,
  last_ok = nil,
  last_err = nil,
  backoff = BACKOFF_BASE,
}

local opts = nil  -- {url, token, deps}

local function url_encode(s)
  return (tostring(s):gsub("[^%w%-%_%.%~]", function(c)
    return string.format("%%%02X", string.byte(c))
  end))
end

-- ── HTTP 小客户端（internet 卡；模式同 http.lua，不做重试——退避在
-- 守护循环层，poll 本身幂等）─────────────────────────────────────
--
-- v0.3.125r2（2026-09-04 坑位排查修复）:
-- ① 零 chunk 挂起: 旧读循环的 deadline 检查在 `for chunk in handle`
--    循环体内——服务器中途死掉（RST/半开连接）时首个 next() 永久
--    阻塞，超时永不触发，守护单点挂死（ocvm 实证: 杀服务器后守护
--    12min+ 零请求零输出）。现改 P1 看门狗模式（patch.lua 连接超时
--    同款）: 读循环放子线程 + thread.waitForAll(deadline)——超时
--    主上下文返回，不再依赖"有 chunk 才检查超时"。
-- ② 连接泄漏: 旧版所有退出路径（超时/过大/中断/读失败）都弃置
--    handle 不 close——每次泄漏 1 个 OC 连接，~50 次后触顶
--    "too many open connections"（machine.lua:1085），通道死亡直到
--    进程重启（ocvm 实证: 旧守护 22000+ 错误后触顶自旋）。现所有
--    路径 pcall(handle.close)。
-- ③ thread 库不可用（mock/精简环境）时回退原同步读循环（不破坏
--    run_tests 的 oc_mock 环境——其 internet mock 无 thread 语义）。

-- 同步读循环（fallback 用；与 v0.3.125r1 行为一致）
local function read_sync(handle, limit)
  local chunks = {}
  local total = 0
  local aborted = nil
  local deadline = now() + POLL_TIMEOUT
  local ok_it, err_it = pcall(function()
    for chunk in handle do
      if interrupt.poll() then aborted = "interrupted" return end
      if now() >= deadline then aborted = "read timeout after " .. POLL_TIMEOUT .. "s" return end
      total = total + #chunk
      if total > limit then aborted = "response too large" return end
      chunks[#chunks + 1] = chunk
      os.sleep(0.02)  -- 每 chunk yield: OC 调度器看到进展
    end
  end)
  if not ok_it then return nil, "http read failed: " .. tostring(err_it) end
  if aborted then return nil, aborted end
  if total == 0 then
    return nil, "empty response (zero chunks — connection dropped)"
  end
  return table.concat(chunks), nil
end

-- 看门狗读: 子线程读 + waitForAll(deadline)；任何路径都 close handle。
-- 返回 body, err。
local function read_guarded(handle, limit)
  local ok_th, thread = pcall(require, "thread")
  if not ok_th or not thread or not thread.create or not thread.waitForAll then
    local body, err = read_sync(handle, limit)
    pcall(function() handle:close() end)
    return body, err
  end
  local chunks = {}
  local total = 0
  local aborted = nil
  local done = false
  local reader = thread.create(function()
    pcall(function()
      for chunk in handle do
        if interrupt.poll() then aborted = "interrupted" return end
        total = total + #chunk
        if total > limit then aborted = "response too large" return end
        chunks[#chunks + 1] = chunk
        os.sleep(0.02)
      end
    end)
    done = true
  end)
  local ok_w, completed = pcall(thread.waitForAll, {reader}, POLL_TIMEOUT)
  pcall(function() handle:close() end)  -- 所有路径 close（防泄漏+尽力解阻塞）
  if not ok_w or not completed then
    if aborted then return nil, aborted end
    return nil, "read timeout after " .. POLL_TIMEOUT .. "s"
  end
  if aborted then return nil, aborted end
  if total == 0 then
    -- v0.3.125r2b: 零 chunk 干净 EOF（连接被 RST/服务器死掉）——
    -- 必须按错误处理: 服务器总回 JSON（noop 也非空），空响应只可能是
    -- 连接被中途丢弃。旧判定 `if body then` 里 "" 为真 → 空 body 走
    -- 成功分支 → 退避被复位 + polls 虚增 + else 分支的退避睡眠永不
    -- 执行 → 守护以纯请求开销空转（ocvm 实证: polls≈errs 同速爬升，
    -- 退避恒 2s，杀服务器后 2min 900+ 错误）。
    return nil, "empty response (zero chunks — connection dropped)"
  end
  return table.concat(chunks), nil
end

-- GET: 返回 body, err。不依赖状态码（服务器总回 JSON；解析失败按
-- 错误处理）。
local function http_get(url)
  local ok_i, internet = pcall(require, "internet")
  if not ok_i then return nil, "no internet module" end
  local ok, handle = pcall(function() return internet.request(url) end)
  if not ok then return nil, "connection failed: " .. tostring(handle) end
  return read_guarded(handle, MAX_POLL_BODY)
end

-- POST: 返回 err（nil=成功）。
local function http_post(url, body)
  local ok_i, internet = pcall(require, "internet")
  if not ok_i then return "no internet module" end
  local ok, handle = pcall(function() return internet.request(url, body) end)
  if not ok then return "connection failed: " .. tostring(handle) end
  local _resp, err = read_guarded(handle, 16384)
  return err
end

-- ── 命令执行 ────────────────────────────────────────────────────

local function sh_quote(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

-- 返回 (result_str, is_err)
local function execute_op(cmd)
  local op = cmd.op
  local args = (type(cmd.args) == "table") and cmd.args or {}
  if op == "ping" then
    local data = {}
    local ok_c, comp = pcall(require, "computer")
    if ok_c and comp and comp.uptime then
      local ok2, up = pcall(comp.uptime)
      if ok2 and type(up) == "number" then data.uptime = math.floor(up + 0.5) end
    end
    local ok_u, cmod = pcall(require, "component")
    if ok_u and cmod then
      local ok3, mem = pcall(function()
        return cmod.invoke(cmod.list("memory")(), "freeMemory")
      end)
      if ok3 and type(mem) == "number" then data.free_mem = mem end
      local ok4, tot = pcall(function()
        return cmod.invoke(cmod.list("memory")(), "totalMemory")
      end)
      if ok4 and type(tot) == "number" then data.total_mem = tot end
    end
    data.os = _G._OSVERSION or "?"
    local ok5, enc = pcall(json.encode, {data = data})
    if ok5 then return enc, false end
    return "ping encode failed: " .. tostring(enc), true
  end
  local tool, tool_args
  if op == "exec" then
    if type(args.command) ~= "string" then
      return "exec: args.command must be a string", true
    end
    tool = "shell_execute"
    tool_args = {command = args.command}
    if args.timeout then tool_args.timeout = args.timeout end
  elseif op == "read" then
    if type(args.path) ~= "string" then
      return "read: args.path must be a string", true
    end
    tool = "read_file"
    tool_args = {path = args.path}
    if args.offset then tool_args.offset = args.offset end
    if args.limit then tool_args.limit = args.limit end
  elseif op == "write" then
    if type(args.path) ~= "string" or type(args.content) ~= "string" then
      return "write: args.path and args.content must be strings", true
    end
    tool = "write_file"
    tool_args = {path = args.path, content = args.content}
  elseif op == "list" then
    if type(args.path) ~= "string" then
      return "list: args.path must be a string", true
    end
    -- v0.3.125r2: 纯 Lua filesystem.list（免 shell）——实证坑: `ls -la`
    -- 走 OpenOS full_ls.lua，4MB 机低内存下崩溃（"attempt to index a
    -- nil value (field '?')"，提示 "try using `list` instead"），连
    -- 空闲 ~317KB 时 `ls -la /` 都崩。filesystem.list 是纯迭代器，
    -- 无 shell 无额外进程。500 项封顶防超大目录撑爆回传。
    local ok_fs, fs = pcall(require, "filesystem")
    if not ok_fs or not fs then
      return "list: no filesystem module", true
    end
    -- 存在性检查用 fs.exists（ocvm 的 filesystem 无 isPath，pcall 必失败
    -- 导致 list 全拒——首次真机验证即现形）。目录/文件都放行给
    -- fs.list：对文件 list 抛错走下方 "list failed" 路径。
    local ok_p, p_ok = pcall(fs.exists, args.path)
    if not ok_p or not p_ok then
      return "Error: cannot access " .. args.path .. ": No such file or directory", true
    end
    local entries = {}
    local ok_l, l_err = pcall(function()
      for name in fs.list(args.path) do
        entries[#entries + 1] = name
        if #entries >= 500 then break end
      end
    end)
    if not ok_l then
      return "Error: list failed: " .. tostring(l_err), true
    end
    table.sort(entries)
    local s = table.concat(entries, "\n")
    if s == "" then s = "(empty)" end
    return s, false
  else
    return "unknown op: " .. tostring(op), true
  end
  local ok_a, encoded = pcall(json.encode, tool_args)
  if not ok_a then return "args encode failed: " .. tostring(encoded), true end
  local ok_r, result = pcall(execute_mod.run, tool, encoded, opts.deps)
  if not ok_r then return "tool crash: " .. tostring(result), true end
  local s = tostring(result)
  -- 工具失败约定: "Error: ..." 前缀（shell/file 模块一致）。
  -- v0.3.125r2: 护栏拒绝与超时杀进程也以错误语义回传——实证坑:
  -- "rejected by guard: ..." 与 "shell_execute timeout after Ns
  -- (command killed): ..." 均不以 Error 开头 → 旧判定 ok=true（假阴），
  -- 而合法输出 "Error: ..." 又被判假阳。三前缀并集。
  local is_err = s:match("^Error") ~= nil
    or s:match("^rejected by guard") ~= nil
    or s:match("^shell_execute timeout") ~= nil
  return s, is_err
end

-- ── 回传 ────────────────────────────────────────────────────────

local function report(id, s, is_err)
  local total = #s
  if total > MAX_RESULT then
    s = s:sub(1, MAX_RESULT) .. "…[truncated: " .. total .. " bytes total]"
  end
  local ok_e, payload = pcall(json.encode,
    {id = id, ok = not is_err, result = s})
  if not ok_e then
    state.report_errors = state.report_errors + 1
    state.last_err = "report encode failed: " .. tostring(payload)
    return
  end
  local url = opts.url .. "/report?token=" .. url_encode(opts.token)
    .. "&id=" .. url_encode(tostring(id))
  local err = http_post(url, payload)
  if err then
    -- v0.3.125r2: 失败重试一次——实证坑: 内存风暴期单次 report POST
    -- 卡满 30s 超时，命令结果丢失（服务器端永远 pending，客户端只见
    -- 超时）。幂等（服务器按 id upsert），重试覆盖"请求已到但响应
    -- 丢失"场景。sleep 走 P0 补丁（可中断）。
    os.sleep(2)
    err = http_post(url, payload)
  end
  if err then
    state.report_errors = state.report_errors + 1
    state.last_err = "report failed (after retry): " .. tostring(err)
  end
end

-- ── 守护循环 ────────────────────────────────────────────────────

local function loop()
  while not state.stop_flag do
    if interrupt.poll() then interrupt.clear() end
    local url = opts.url .. "/poll?token=" .. url_encode(opts.token)
    local body, err = http_get(url)
    if body then
      state.backoff = BACKOFF_BASE
      state.polls = state.polls + 1
      local ok_j, cmd = pcall(json.decode, body)
      if not ok_j or type(cmd) ~= "table" or type(cmd.op) ~= "string" then
        state.errors = state.errors + 1
        state.last_err = "bad poll body: " .. tostring(tostring(body):sub(1, 120))
      elseif cmd.op == "noop" then
        -- 无事发生（服务器 hold 期满后空回）
      else
        state.cmds = state.cmds + 1
        state.last_op = cmd.op
        local s, is_err = execute_op(cmd)
        state.last_ok = not is_err
        report(cmd.id, s, is_err)
      end
    else
      state.errors = state.errors + 1
      state.last_err = tostring(err)
      if state.errors == 1 or state.errors % 10 == 0 then
        print("[remote] poll error: " .. tostring(err)
          .. "（" .. state.errors .. " 次，退避 " .. state.backoff .. "s）")
      end
      local sleep_s = state.backoff
      state.backoff = math.min(state.backoff * 2, BACKOFF_CAP)
      -- 可打断退避睡眠
      for _ = 1, math.ceil(sleep_s / 0.5) do
        if state.stop_flag then break end
        os.sleep(0.5)
      end
    end
  end
  state.running = false
  state.thread = nil
  print("[remote] stopped")
end

-- ── 对外接口 ────────────────────────────────────────────────────

-- start({url=, token=, deps={json=, load_config=}}) → ok, err
local function start(o)
  if state.running then return false, "already running" end
  if type(o) ~= "table" or type(o.url) ~= "string" or o.url == "" then
    return false, "url required"
  end
  if type(o.token) ~= "string" or o.token == "" then
    return false, "token required"
  end
  local ok_t, thread = pcall(require, "thread")
  if not ok_t or type(thread) ~= "table" or type(thread.create) ~= "function" then
    return false, "no thread library (headless/test env)"
  end
  opts = {url = o.url:gsub("/+$", ""), token = o.token, deps = o.deps or {json = json}}
  state.stop_flag = false
  state.running = true
  state.thread = thread.create(loop)
  print("[remote] started → " .. tostring(opts.url))
  return true, nil
end

local function stop()
  if not state.running then return false, "not running" end
  state.stop_flag = true
  -- 线程在当前 poll（≤30s）结束后自行退出并打印 stopped
  return true, nil
end

local function is_running()
  return state.running
end

local function status()
  return {
    running = state.running,
    polls = state.polls,
    cmds = state.cmds,
    errors = state.errors,
    report_errors = state.report_errors,
    last_op = state.last_op,
    last_ok = state.last_ok,
    last_err = state.last_err,
    url = opts and opts.url or nil,
  }
end

return {
  start = start,
  stop = stop,
  is_running = is_running,
  status = status,
  -- 测试钩子（_TEST_MODE 才暴露）
  _internal = _TEST_MODE and {execute_op = execute_op, sh_quote = sh_quote} or nil,
}
