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

-- GET: 返回 body, err。不依赖状态码（服务器总回 JSON；解析失败按
-- 错误处理）。
local function http_get(url)
  local ok_i, internet = pcall(require, "internet")
  if not ok_i then return nil, "no internet module" end
  local ok, handle = pcall(function() return internet.request(url) end)
  if not ok then return nil, "connection failed: " .. tostring(handle) end

  local chunks = {}
  local total = 0
  local aborted = nil
  local deadline = now() + POLL_TIMEOUT
  local ok_it, err_it = pcall(function()
    for chunk in handle do
      if interrupt.poll() then aborted = "interrupted" return end
      if now() >= deadline then aborted = "poll timeout after " .. POLL_TIMEOUT .. "s" return end
      total = total + #chunk
      if total > MAX_POLL_BODY then aborted = "poll response too large" return end
      chunks[#chunks + 1] = chunk
      os.sleep(0.02)  -- 每 chunk yield: OC 调度器看到进展
    end
  end)
  if not ok_it then return nil, "http read failed: " .. tostring(err_it) end
  if aborted then return nil, aborted end
  return table.concat(chunks), nil
end

-- POST: 返回 err（nil=成功）。
local function http_post(url, body)
  local ok_i, internet = pcall(require, "internet")
  if not ok_i then return "no internet module" end
  local ok, handle = pcall(function() return internet.request(url, body) end)
  if not ok then return "connection failed: " .. tostring(handle) end
  local total = 0
  local aborted = nil
  local deadline = now() + POLL_TIMEOUT
  local ok_it, err_it = pcall(function()
    for chunk in handle do
      if interrupt.poll() then aborted = "interrupted" return end
      if now() >= deadline then aborted = "report timeout" return end
      total = total + #chunk
      if total > 16384 then aborted = "report response too large" return end
      os.sleep(0.02)
    end
  end)
  if not ok_it then return "http read failed: " .. tostring(err_it) end
  if aborted then return aborted end
  return nil
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
    tool = "shell_execute"
    tool_args = {command = "ls -la " .. sh_quote(args.path)}
  else
    return "unknown op: " .. tostring(op), true
  end
  local ok_a, encoded = pcall(json.encode, tool_args)
  if not ok_a then return "args encode failed: " .. tostring(encoded), true end
  local ok_r, result = pcall(execute_mod.run, tool, encoded, opts.deps)
  if not ok_r then return "tool crash: " .. tostring(result), true end
  local s = tostring(result)
  -- 工具失败约定: "Error: ..." 前缀（shell/file 模块一致）
  local is_err = s:match("^Error") ~= nil
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
    state.report_errors = state.report_errors + 1
    state.last_err = "report failed: " .. tostring(err)
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
