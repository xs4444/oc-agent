-- ═══════════════════════════════════════════════════════════════
-- agent.remote — 远程控制守护（v0.3.125）。
--
-- 后台线程经 internet 卡 long-poll 外部控制服务器（tools/
-- remote_server.py），取命令 → 用现有工具注册表执行（ping/exec/
-- read/write/list/lua/fetch，护栏随 execute.run 生效）→ 回传
-- 结果。让外部
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
local REPORT_TIMEOUT = 10    -- report 读 deadline（秒）: 短于 poll 的 30s——
                             -- 实证坑: report POST 卡满 30s 占用单线程守护
                             -- （期间不 poll、off 不响应）；失败进 pending
                             -- 延迟队列，不值得卡 30s
local MAX_PENDING = 10       -- report 延迟队列: 条数上限（最旧淘汰）
local MAX_PENDING_BYTES = 131072 -- report 延迟队列: payload 总量上限（128KB）
local BACKOFF_BASE = 2       -- 失败退避基数（秒）
local BACKOFF_CAP = 60       -- 退避封顶（秒）
local MAX_RESULT = 65536     -- 回传结果块大小（字节）: 64KB（首块与 fetch 续块）
local MAX_RESULT_HELD = 262144 -- v0.3.125r5: 大结果分页缓存上限（字节）: 256KB
                               -- （4MB 机安全；超过的部分不可取回，meta.held
                               --  < meta.total 即标志截断）
local RESULT_TTL = 600       -- v0.3.125r5: 分页缓存有效期（秒）；过期 fetch 报
                             -- expired 并清槽
local MAX_POLL_BODY = 131072 -- poll 响应体上限（字节）: 命令 JSON 应远小于此
local MAX_EXEC_HARD_CAP = 600 -- v0.3.125r6: exec/lua 命令超时硬帽（秒）
local WATCHDOG_MARGIN = 30    -- 看门狗余量（秒）: 外层 cap = 工具超时 + 余量
                              -- 必须严格大于内层（shell 自带 timeout 先触发，
                              -- 外层只是内层失灵的兜底）

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
  -- v0.3.125r4: 当前 poll 的 internet handle——shutdown() 用它立即解除
  -- 阻塞（close → 读迭代器 EOF）。read_guarded 返回后清除。
  active_handle = nil,
  -- v0.3.125r5: 大结果分页缓存（单槽 {rid,text,total,held,ts}；新的大
  -- 结果整体替换旧的——fetch 拿旧 rid 会报 unknown or replaced）
  result_cache = nil,
  result_seq = 0,
}

local opts = nil  -- {url, token, deps}
-- v0.3.125r3: report 延迟队列——report 发送失败（10s 超时/重试仍败）的
-- payload 暂存于此，poll 成功（=服务器可达）后逐条冲刷。守护进程崩溃
-- 丢失的窗口由 /result 端 lost 标记兜底（服务器侧）。
local pending = {}

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
-- ④ v0.3.125r6: 等待机制从 thread.waitForAll 改为 wait_thread 轮询——
--    ocvm 实证 waitForAll 内部单次 event.pull(deadline) 长超时注册
--    不触发（看门狗 cap=35s 后守护 100s+ 零 poll，直到 TUI 事件
--    碰巧唤醒才恢复；0.1s 分片 os.sleep 则可靠，r2b 退避节奏
--    2/4/8/16/32s 实测准确）。子线程置 box.done + 父线程
--    os.sleep(0.5) 轮询（P0 补丁版可被 Ctrl+C 打断）。

-- 同步读循环（fallback 用；与 v0.3.125r1 行为一致）
local function read_sync(handle, limit, timeout)
  timeout = timeout or POLL_TIMEOUT
  local chunks = {}
  local total = 0
  local aborted = nil
  local deadline = now() + timeout
  local ok_it, err_it = pcall(function()
    for chunk in handle do
      if interrupt.poll() then aborted = "interrupted" return end
      if now() >= deadline then aborted = "read timeout after " .. timeout .. "s" return end
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

-- v0.3.125r6: 线程 join 超时实现（取代 thread.waitForAll）。
-- ocvm 源码级根因（components/computer.cpp 机器循环 + system/machine.lua
-- 单系统协程 + thread.lua 注册表共享）: 子线程 op 执行期间，父线程冻结
-- 在共享 handlers 表的事件派发循环里（机器 resume 始终进最内层
-- yield 源）——有限 op 完成即恢复（实证: 子 op 8s 期间 ping 在 op
-- 结束后 ~1s 处理）；无限循环子线程则父线程永久冻结，Lua 层看门狗
-- 无从下手（实证: os.sleep(0) 死循环 cap=35s 后守护 100s+ 零 poll）。
-- waitForAll 的同型长超时 event.pull 更不可靠。真机 Java OC 机器
-- 逐 process 拉取，无此冻结——本设计（子线程+轮询）在真机完整生效。
-- 子线程置 box.done，父线程 os.sleep(0.5) 轮询（P0 版 0.1s 分片，
-- 可被打断，Ctrl+C 不堵）。
-- 返回 true=完成 / false=超时（调用方负责 t:kill）。
local function wait_thread(box, timeout)
  local waited = 0
  while not box.done and waited < timeout do
    if os.sleep then os.sleep(0.5) end
    waited = waited + 0.5
  end
  return box.done
end

-- 看门狗读: 子线程读 + wait_thread 轮询；任何路径都 close handle。
-- 返回 body, err。timeout 可覆盖（report 用 10s 短超时）。
local function read_guarded(handle, limit, timeout)
  timeout = timeout or POLL_TIMEOUT
  local ok_th, thread = pcall(require, "thread")
  if not ok_th or not thread or type(thread.create) ~= "function" then
    local body, err = read_sync(handle, limit, timeout)
    pcall(function() handle:close() end)
    return body, err
  end
  local chunks = {}
  local total = 0
  local box = {aborted = nil}
  local reader = thread.create(function()
    pcall(function()
      for chunk in handle do
        if interrupt.poll() then box.aborted = "interrupted" return end
        total = total + #chunk
        if total > limit then box.aborted = "response too large" return end
        chunks[#chunks + 1] = chunk
        os.sleep(0.02)
      end
    end)
    box.done = true
  end)
  if not wait_thread(box, timeout) then
    pcall(reader.kill, reader)  -- 硬杀读线程（卡 C++ 阻塞时下一让出点生效）
  end
  pcall(function() handle:close() end)  -- 所有路径 close（防泄漏+尽力解阻塞）
  if not box.done then
    if box.aborted then return nil, box.aborted end
    return nil, "read timeout after " .. timeout .. "s"
  end
  if box.aborted then return nil, box.aborted end
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
  state.active_handle = handle
  local body, err = read_guarded(handle, MAX_POLL_BODY)
  state.active_handle = nil
  return body, err
end

-- POST: 返回 err（nil=成功）。timeout 可覆盖（report 用 10s 短超时）。
local function http_post(url, body, timeout)
  local ok_i, internet = pcall(require, "internet")
  if not ok_i then return "no internet module" end
  local ok, handle = pcall(function() return internet.request(url, body) end)
  if not ok then return "connection failed: " .. tostring(handle) end
  state.active_handle = handle
  local _resp, err = read_guarded(handle, 16384, timeout)
  state.active_handle = nil
  return err
end

-- ── v0.3.125r6: 硬帽看门狗（"命令卡死守护"防护）─────────────────
--
-- 实证坑: RemoteOC 客户端 `while true do end` 永久卡死单线程轮询
-- （无租约/TTL，通道永久死，唯一恢复=重启 VM）；同形坑在我们通道
-- = 某个 op 永不返回 → 守护单线程循环停摆 → 后续命令全部静默堵死
-- （本机实证 10h 堵单槽队列）。工具层 shell_execute 自带 60s 超时+
-- 子线程 kill，但 (a) kill 对卡死在 C++ 阻塞里的线程未必即时生效，
-- (b) lua op（r5 任意脚本）原本完全没有超时——守护活性无保证。
--
-- 对策: 再套一层外层看门狗——op 放子线程执行 + wait_thread 轮询 cap，
-- 超时 thread-kill 子线程。无论内层机制是否生效，外层 cap 保证守护
-- 循环必然释放（不变量: "守护永不被单个命令永久占用"）。
-- cap = 工具超时 + 余量，硬帽 MAX_EXEC_HARD_CAP。
--
-- 已知边界: OC 调度是协作式——子线程若跑无 os.sleep 的紧密死循环，
-- kill 只在其让出点生效；看门狗保证守护释放，不保证子线程立即停
-- （其占用资源持续到自愿让出）。下发脚本必须含 os.sleep。
local function watchdog_cap(timeout_arg)
  local t = tonumber(timeout_arg)
  if not t or t <= 0 then t = 60 end  -- 与 shell_execute 默认一致
  return math.min(t, MAX_EXEC_HARD_CAP) + WATCHDOG_MARGIN
end

-- fn 返回 (s, is_err)；超时/kill 失败返回 (timeout_msg, true)。
-- 无 thread 库环境（mock/测试）回退内联执行。
-- v0.3.125r6: 等待改 wait_thread 轮询（ocvm 实证 waitForAll 长超时
-- event.pull 不触发——cap=35s 实测卡 100s+，守护活性不变量失守）。
local function run_guarded(fn, cap, timeout_msg)
  local ok_t, thread = pcall(require, "thread")
  if not ok_t or type(thread) ~= "table" or type(thread.create) ~= "function" then
    local ok_r, s, is_err = pcall(fn)
    if not ok_r then return "tool crash: " .. tostring(s), true end
    return s, is_err
  end
  local box = {}
  local t = thread.create(function()
    local ok_r, s, is_err = pcall(fn)
    if not ok_r then s, is_err = "tool crash: " .. tostring(s), true end
    box.s, box.e, box.done = s, is_err, true
  end)
  if not wait_thread(box, cap) then
    pcall(t.kill, t)  -- 硬杀子线程（卡 C++ 阻塞时在下一让出点生效）
    return timeout_msg, true
  end
  return box.s, box.e
end

-- v0.3.125r6: 错误信息清洗——单文件构建的 pcall 错误带内部路径
-- （实证 cosmetic 坑: "Error: /mnt/14e/agent.lua:6104: file not found:
-- /tmp/nope" 泄漏部署路径）。只剥 "xxx.lua:NNN: " 一段，普通 Error
-- 文本与合法输出不动。
local function clean_err(s)
  if type(s) ~= "string" then return s end
  return (s:gsub("^Error: [^:]+%.lua:[0-9]+: ", "Error: "))
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
  local tool, tool_args, guard_cap
  if op == "exec" then
    if type(args.command) ~= "string" then
      return "exec: args.command must be a string", true
    end
    tool = "shell_execute"
    tool_args = {command = args.command}
    if args.timeout then tool_args.timeout = args.timeout end
    -- v0.3.125r6: 硬帽看门狗（shell 自带超时失灵的兜底——10h 堵队列实证）
    guard_cap = watchdog_cap(args.timeout)
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
  elseif op == "lua" then
    if type(args.code) ~= "string" then
      return "lua: args.code must be a string", true
    end
    -- v0.3.125r5: 执行服务器下发的 Lua 脚本（借鉴 RemoteOC 裸 Lua 模式——
    -- 真机调试跑任意脚本不必拼 exec 命令串）。print 进 TUI（与 exec
    -- `lua script` 同一泄漏行为），return 值即结果。信任边界同 exec
    -- （token 保护通道），不加沙箱。
    -- v0.3.125r6b: 看门狗从子线程+kill 改为「内联执行+deadline 注入」。
    -- 子线程方案在 ocvm 两次实证失败: ①waitForAll 长超时不可靠（守护
    -- 卡 100s+）②os.sleep 自旋版仍卡——thread.create 子线程跑
    -- `while true do os.sleep(0) end` 紧循环时 ocvm 调度器饿死全部
    -- 其他线程（守护+TUI 同冻结，t.kill 无机会生效，TUI mem 行 3s 不
    -- 刷新实证）。OC 协作式调度下 sleepless 紧循环本就不可杀
    -- （平台约束，RemoteOC 砖机同形），唯一可靠锚点是脚本自己的
    -- sleep 调用 → 包装注入的 os.sleep/computer.sleep，sleep 内精确
    -- 到期即 error 杀（无超调）。无 sleep 的脚本=冻结机器（文档化，
    -- 与 exec 子进程 C++ 层 kill 不同，lua 脚本跑在守护线程里）。
    local cap = watchdog_cap(args.timeout)
    local deadline = now() + cap
    local function kill_at_deadline(s, real_sleep)
      s = s or 0
      local rem = deadline - now()
      if rem < s then
        if rem > 0 then os.sleep(rem) end
        error("deadline exceeded after " .. cap .. "s (killed at sleep)", 0)
      end
      real_sleep(s)
    end
    local loadfn = load or loadstring  -- Lua 5.2+ / 5.1 兼容
    -- v0.3.125r6: 注入常用全局——守护线程上下文无 computer/internet
    -- 全局（实证: attempt to index a nil value (global 'computer')；
    -- internet 同形），调试脚本直接写 computer.uptime()/
    -- internet.request() 最顺手。信任边界不变（两模块对任何 OC
    -- 程序本就可用）。
    local injected = {}
    local wos = {}
    for k, v in pairs(os) do wos[k] = v end
    wos.sleep = function(s) kill_at_deadline(s, os.sleep) end
    injected.os = wos
    local ok_c, comp = pcall(require, "computer")
    if ok_c and type(comp) == "table" then
      local wc = {}
      for k, v in pairs(comp) do wc[k] = v end
      wc.sleep = function(s) kill_at_deadline(s, function(x) comp.sleep(x) end) end
      injected.computer = wc
    end
    local ok_i, inet = pcall(require, "internet")
    if ok_i and type(inet) == "table" then injected.internet = inet end
    local script_env = setmetatable(injected, {__index = _G})
    local f, lerr = loadfn(args.code, "remote-script", nil, script_env)
    if not f then
      return "lua: load failed: " .. tostring(lerr), true
    end
    local ok_r, r = pcall(f)
    if not ok_r then
      return "lua: " .. tostring(r), true
    end
    if r == nil then return "(no return value)", false end
    return tostring(r), false
  elseif op == "fetch" then
    -- v0.3.125r5: 大结果续取（report 首块 64KB + meta {rid,total,held,
    -- more}；此处按 rid+offset 取下一块，块大小 MAX_RESULT）。offset 为
    -- 0 基起始位置——首块已覆盖 0..MAX_RESULT-1，通常 offset=65536。
    -- 客户端据 meta.held 自行判断终止（held < total = 截断）。
    local rc = state.result_cache
    if not rc or rc.rid ~= tostring(args.rid) then
      return "fetch: unknown or replaced result id: " .. tostring(args.rid), true
    end
    if now() - rc.ts > RESULT_TTL then
      state.result_cache = nil
      return "fetch: result " .. rc.rid .. " expired (TTL " .. RESULT_TTL .. "s)", true
    end
    local offset = tonumber(args.offset) or 0
    if offset < 0 or offset >= rc.held then
      return "fetch: offset " .. tostring(offset) .. " out of range (held "
        .. rc.held .. ")", true
    end
    local chunk = rc.text:sub(offset + 1, offset + MAX_RESULT)
    if chunk == "" then return "(end of held result)", false end
    return chunk, false
  else
    return "unknown op: " .. tostring(op), true
  end
  local ok_a, encoded = pcall(json.encode, tool_args)
  if not ok_a then return "args encode failed: " .. tostring(encoded), true end
  local function do_run()
    local ok_r, result, tool_is_err = pcall(execute_mod.run, tool, encoded, opts.deps)
    if not ok_r then return "tool crash: " .. tostring(result), true end
    local s = tostring(result)
    -- v0.3.125r3: 结构化错误标志——file/shell 工具层直接返回 (text, is_err)，
    -- 不再靠字符串前缀猜（实证假阳: cat error.log 等合法输出以 "Error:"
    -- 开头被误判失败）。is_err=true 的合法场景: 工具 pcall 崩溃、参数解析
    -- 失败、Unknown tool、guard 拒绝、内存护栏、超时杀进程、文件错误。
    if type(tool_is_err) == "boolean" then
      return clean_err(s), tool_is_err
    end
    -- 工具未提供标志（插件工具等）: 回退三前缀判定。
    -- v0.3.125r2: 护栏拒绝与超时杀进程也以错误语义回传——实证坑:
    -- "rejected by guard: ..." 与 "shell_execute timeout after Ns
    -- (command killed): ..." 均不以 Error 开头 → 旧判定 ok=true（假阴）。
    local is_err = s:match("^Error") ~= nil
      or s:match("^rejected by guard") ~= nil
      or s:match("^shell_execute timeout") ~= nil
    return clean_err(s), is_err
  end
  if guard_cap then
    -- v0.3.125r6: exec 走外层看门狗（内层 shell 超时 +30s 余量兜底）
    return run_guarded(do_run, guard_cap,
      "exec: watchdog timeout after " .. guard_cap .. "s (command killed)")
  end
  return do_run()
end

-- ── 回传（v0.3.125r3: 10s 短超时 + pending 延迟队列 + 崩溃持久化）──
--
-- 实证坑（内存风暴期）: report POST 卡满 30s 读 deadline → 单线程守护
-- 被占（期间不 poll、off 不响应），命令结果丢失（服务器端永远
-- pending，客户端只见到期超时）。对策:
-- ① report 读 deadline 10s（REPORT_TIMEOUT）——不值得卡满 poll 的 30s
-- ② 失败立即重试一次（幂等 upsert），仍败入 pending 延迟队列
--    （≤10 条/128KB，最旧淘汰），poll 成功后逐条冲刷——poll 成功
--    = 服务器可达，是最佳重发窗口
-- ③ 守护崩溃窗口: pending 条目同时落盘（data_dir/remote_pending/
--    <id>.json），守护启动时回载入队列，首次 poll 成功冲刷——覆盖
--    "重命令执行后 agent OOM/崩溃，结果无人重发"的最坏窗口
-- ④ 全部丢失时由服务器 /result 的 lost 标记兜底（客户端可判死）

local MAX_DISK_PENDING = 50   -- 磁盘 pending 上限（ts 序最旧淘汰）

local function safe_name(id)
  return (tostring(id):gsub("[^%w%-_%.]", "_"))
end

-- 目录可用性: fs.list 能列即真; 失败则 shell mkdir -p 一次重试
-- （OpenOS 无 fs.mkdir）。全程不可用 → nil（静默禁用持久化——
-- 持久化是增强，不能成为新故障源）。
local function pending_dir_available(dir)
  local ok_fs, fs = pcall(require, "filesystem")
  if not ok_fs or not fs then return nil end
  local function listable()
    local ok_l, iter = pcall(fs.list, dir)
    return (ok_l and type(iter) == "function") and true or false
  end
  if listable() then return dir end
  local ok_s, shell = pcall(require, "shell")
  if ok_s and shell and shell.execute then
    pcall(shell.execute, "mkdir -p " .. dir)
  end
  if listable() then return dir end
  return nil
end

local function persist_to_disk(id, payload)
  if not opts.pending_dir then return end
  local ok_e, obj = pcall(json.encode, {id = id, ts = now(), payload = payload})
  if not ok_e then return end
  local path = opts.pending_dir .. "/" .. safe_name(id) .. ".json"
  local f = io.open(path, "w")
  if not f then
    -- 目录可能消失（换盘/清理）: 重建一次，仍失败则禁用持久化
    if pending_dir_available(opts.pending_dir) then
      f = io.open(path, "w")
    else
      opts.pending_dir = nil
    end
  end
  if f then
    pcall(f.write, f, obj)
    f:close()
  end
end

local function delete_pending_file(id)
  if not opts.pending_dir then return end
  pcall(os.remove, opts.pending_dir .. "/" .. safe_name(id) .. ".json")
end

-- 守护启动: 磁盘 pending 回载（ts 序，>MAX_DISK_PENDING 的视为过旧删除）
local function load_pending_from_disk()
  local dir = pending_dir_available(opts.pending_dir)
  if not dir then
    opts.pending_dir = nil
    return
  end
  local ok_fs, fs = pcall(require, "filesystem")
  local items = {}
  for name in fs.list(dir) do
    if name:match("%.json$") then
      local f = io.open(dir .. "/" .. name, "r")
      if f then
        local raw = f:read("*a")
        f:close()
        local ok_d, obj = pcall(json.decode, raw)
        if ok_d and type(obj) == "table" and type(obj.payload) == "string" then
          items[#items + 1] = {
            name = name,
            id = tostring(obj.id or (name:gsub("%.json$", ""))),
            ts = tonumber(obj.ts) or 0,
            payload = obj.payload,
          }
        else
          pcall(os.remove, dir .. "/" .. name)  -- 垃圾文件清掉
        end
      end
    end
  end
  table.sort(items, function(a, b) return a.ts < b.ts end)
  local drop = #items - MAX_DISK_PENDING
  for i = 1, math.max(drop, 0) do
    pcall(os.remove, dir .. "/" .. items[i].name)
  end
  for i = math.max(drop, 0) + 1, #items do
    pending[#pending + 1] = {id = items[i].id, payload = items[i].payload}
  end
  if #pending > 0 then
    print("[remote] restored " .. #pending .. " pending report(s) from disk")
  end
end

local function send_report(id, payload)
  local url = opts.url .. "/report?token=" .. url_encode(opts.token)
    .. "&id=" .. url_encode(tostring(id))
  local err = http_post(url, payload, REPORT_TIMEOUT)
  if err then
    os.sleep(2)  -- P0 补丁（可中断）
    err = http_post(url, payload, REPORT_TIMEOUT)
  end
  return err  -- nil = 成功
end

-- poll 成功后冲刷延迟队列: 按入队顺序单发（10s 超时，不做二次重试——
-- 失败留在队列，下轮 poll 再试）。最坏 10×10s 阻塞仅发生在服务器
-- 收连接但全部吞 report 的病态场景。
local function flush_pending()
  local i = 1
  while i <= #pending and not state.stop_flag do
    local p = pending[i]
    local url = opts.url .. "/report?token=" .. url_encode(opts.token)
      .. "&id=" .. url_encode(tostring(p.id))
    local err = http_post(url, p.payload, REPORT_TIMEOUT)
    if not err then
      table.remove(pending, i)
      delete_pending_file(p.id)  -- 送达即删盘（幂等: 重发无副作用）
    else
      i = i + 1
    end
  end
end

-- v0.3.125r5: 大结果分页（借鉴 RemoteOC 分块上报，改为"客户端按需拉取"
-- —— 比 128B 小块上传简单，且只在需要时才有额外流量）:
--   结果 > 64KB → 缓存前 256KB（MAX_RESULT_HELD），回传首块 64KB +
--   meta {rid, total, held, more}；外部驱动用 fetch op 按 offset 续取。
--   单槽缓存: 新的大结果替换旧的；TTL 600s 过期清槽。
--   held < total 时驱动知道结果被截断（4MB 机内存安全优先）。
local function report(id, s, is_err)
  local total = #s
  local meta = nil
  local out = s
  if total > MAX_RESULT then
    local held = math.min(total, MAX_RESULT_HELD)
    state.result_seq = state.result_seq + 1
    local rid = "r" .. state.result_seq
    state.result_cache = {
      rid = rid, text = s:sub(1, held),
      total = total, held = held, ts = now(),
    }
    meta = {rid = rid, total = total, held = held,
            more = held > MAX_RESULT}
    out = s:sub(1, MAX_RESULT)
  end
  local payload = {id = id, ok = not is_err, result = out}
  if meta then
    payload.rid = meta.rid
    payload.total = meta.total
    payload.held = meta.held
    payload.more = meta.more
  end
  local ok_e, payload_enc = pcall(json.encode, payload)
  if not ok_e then
    state.report_errors = state.report_errors + 1
    state.last_err = "report encode failed: " .. tostring(payload_enc)
    return
  end
  local err = send_report(id, payload_enc)
  if not err then return end
  -- 入延迟队列; 超上限（条数/总字节）淘汰最旧（盘上同步删）
  pending[#pending + 1] = {id = id, payload = payload_enc}
  persist_to_disk(id, payload_enc)
  local pbytes = 0
  for _, p in ipairs(pending) do pbytes = pbytes + #p.payload end
  while #pending > MAX_PENDING or pbytes > MAX_PENDING_BYTES do
    local ev = table.remove(pending, 1)
    delete_pending_file(ev.id)
    pbytes = 0
    for _, p in ipairs(pending) do pbytes = pbytes + #p.payload end
  end
  state.report_errors = state.report_errors + 1
  state.last_err = "report failed (queued, " .. #pending
    .. " pending): " .. tostring(err)
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
      -- v0.3.125r3: poll 成功 = 服务器可达，先冲刷延迟 report 队列
      flush_pending()
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
  opts = {
    url = o.url:gsub("/+$", ""),
    token = o.token,
    deps = o.deps or {json = json},
    -- v0.3.125r3: 崩溃持久化目录（data_dir/remote_pending）——未提供或
    -- 不可用时静默禁用（回载函数会置 nil）
    pending_dir = (type(o.data_dir) == "string" and o.data_dir ~= "")
      and (o.data_dir .. "/remote_pending") or nil,
  }
  if opts.pending_dir then
    load_pending_from_disk()
  end
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

-- v0.3.125r4: /exit 安全网（2026-09-05 r3 真机实证）: 守护 active 时
-- 直接 /exit——进程退出把守护线程杀在半途 poll，PipedCommand 从未
-- close() → 孤儿 wget + ocvm 主循环在坏管道上自旋（97% CPU 用户态，
-- wchan=0）+ shell 彻底冻结（/exit 后无提示符、按键无回显）。
-- stop() 只设标志（等当前 ≤30s poll 自然结束才退出——/exit 等不起）;
-- shutdown() 额外: 立即 close 活动 handle（wget 被 SIGKILL、管道 EOF、
-- 读迭代器解阻塞）+ 有界等待守护线程真正退出后再让调用方继续。
-- timeout_s 内线程未退出（如正执行长命令）则放弃等待直接返回——
-- /exit 的提示性优先于完美回收（罕见窗口残留旧风险，文档已注）。
local function shutdown(timeout_s)
  if not state.running then return false, "not running" end
  state.stop_flag = true
  local h = state.active_handle
  state.active_handle = nil
  if h then
    pcall(function() h:close() end)
  end
  local ok_t, thread = pcall(require, "thread")
  local th = state.thread
  if ok_t and type(thread) == "table" and thread.waitForAll and th then
    pcall(thread.waitForAll, {th}, timeout_s or 3)
  end
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
    pending = #pending,
    last_op = state.last_op,
    last_ok = state.last_ok,
    last_err = state.last_err,
    url = opts and opts.url or nil,
  }
end

return {
  start = start,
  stop = stop,
  shutdown = shutdown,
  is_running = is_running,
  status = status,
  -- 测试钩子（_TEST_MODE 才暴露）
  _internal = _TEST_MODE and {
    execute_op = execute_op,
    sh_quote = sh_quote,
    -- v0.3.125r5: report 测试钩子 + URL 注入（mock internet 只对特定
    -- URL 应答；测试环境 start() 走不到真实配置）
    report = report,
    set_url_token = function(u, t)
      opts = opts or {}
      opts.url = u:gsub("/+$", "")
      opts.token = t
    end,
    -- v0.3.125r4: shutdown 测试用（状态表引用——只读检查+合成状态注入）
    _state = state,
    -- v0.3.125r6: 看门狗 cap 计算 + 错误清洗（纯函数单测）
    watchdog_cap = watchdog_cap,
    clean_err = clean_err,
    _persist = {
      safe_name = safe_name,
      persist_to_disk = persist_to_disk,
      delete_pending_file = delete_pending_file,
      load_pending_from_disk = load_pending_from_disk,
      set_pending_dir = function(d) opts = opts or {}; opts.pending_dir = d end,
      get_pending = function() return pending end,
      clear_pending = function() pending = {} end,
    },
  } or nil,
}
