-- ═══════════════════════════════════════════════════════════════
-- agent.debug — 诊断报告收集 + 上传（Phase 4b 新增）。
--
-- 供 `/debug` 命令使用：把版本、配置（脱敏）、最近会话历史、
-- 运行状态汇总成一个文本报告，可选上传到 GitHub Gist
-- （api.github.com/gists），便于远程调试。
--
-- 依赖: agent.json / agent.http / agent.config（config 传参即可）。
-- ═══════════════════════════════════════════════════════════════

local json = require("agent.json")

-- 脱敏: token 类完全遮蔽；key 类保留首 4 + 尾 4
local function mask(s)
  if not s or s == "" then return "(未设置)" end
  if #s <= 8 then return "***" end
  return s:sub(1, 4) .. "***" .. s:sub(-4)
end
local function mask_token(s)
  if not s or s == "" then return "(未设置)" end
  return "(已设置 " .. #s .. " 字符)"
end

-- ── 历史消息脱敏（2026-08-09 安全修复）──
-- 泄漏背景: GitHub 扫描到 gist 内的完整 PAT（oc-agent-debug note）并撤销。
-- Config 段一直安全（gist_token 完全遮蔽），泄漏点在 Recent history 段：
-- msg_line 原样输出消息 content——若历史中某条消息（用户自然语言提交的
-- token、或工具结果如 read_file config.json 输出）含明文密钥，报告即带出。
-- 修复: 已知明文值（config 中的 api_key/tavily_key/gist_token）整体替换
-- + 常见 token 格式模式遮蔽（GitHub PAT/OAuth/OpenAI/Tavily 前缀）。

-- 收集 config 中已知的敏感明文值（去重、跳过空值/过短值）
local function known_secrets(config)
  local list = {}
  local seen = {}
  local cfg = config or {}
  for _, k in ipairs({ "api_key", "tavily_key", "gist_token" }) do
    local v = cfg[k]
    if type(v) == "string" and #v >= 8 and not seen[v] then
      seen[v] = true
      list[#list + 1] = v
    end
  end
  return list
end

-- 纯文本替换（避免 Lua pattern magic 字符误伤：token 值含 % . - 等时
-- string.gsub 会把第一个参数当 pattern——已知值必须按字面匹配）
local function plain_replace(s, find_str, repl)
  local out = s
  local pos = 1
  while true do
    local a, b = string.find(out, find_str, pos, true)
    if not a then break end
    out = out:sub(1, a - 1) .. repl .. out:sub(b + 1)
    pos = a + #repl
  end
  return out
end

-- token 前缀（格式遮蔽：保留前缀便于人读，值部分一律 ***）。
-- 长的前缀在前（github_pat_ 先于 ghp_ 检查；sk-ant- 先于 sk-）。
-- 实现用词元扫描 + 函数替换：一次 gsub 完成，无二次匹配问题
-- （Lua pattern 的 ? 量词在本环境 5.4.6 上行为异常，且分组+量词
--   二次匹配污染产物——实测 a(b)?c 匹配 abc 返回 nil，弃用）。
local TOKEN_PREFIXES = {
  "github_pat_", "ghp_", "gho_", "ghu_", "ghs_", "ghr_",
  "sk-ant-", "sk-", "tvly-",
}

-- 对文本做脱敏：先替换已知明文值，再按前缀格式遮蔽 token 值。
-- 顺序很重要：已知值替换优先（更长更精确，避免模式先行后值已变）。
local function redact(text, config)
  if not text or text == "" then return text end
  local out = tostring(text)
  for _, secret in ipairs(known_secrets(config)) do
    out = plain_replace(out, secret, "***")
  end
  -- 词元扫描: 对每个 [%w_]（含 - 的连续 token 候选）检查前缀，
  -- 命中则保留前缀、值部分换 ***；函数替换单遍完成，无二次匹配。
  out = out:gsub("[%w_%-]+", function(tok)
    for _, prefix in ipairs(TOKEN_PREFIXES) do
      if tok:sub(1, #prefix) == prefix then
        return prefix .. "***"
      end
    end
    return tok
  end)
  return out
end

-- 单条消息 → 紧凑单行（tool 结果截断放宽到 1000 字符；
-- content 先经 redact 脱敏——历史中可能含明文密钥）
local function msg_line(msg, config)
  if type(msg) ~= "table" then return tostring(msg) end
  local role = msg.role or "?"
  local parts = { "[" .. role .. "]" }
  if msg.tool_call_id then parts[#parts + 1] = "(" .. msg.tool_call_id .. ")" end
  if msg.content and msg.content ~= "" then
    local c = redact(msg.content, config):gsub("\n", " "):gsub("\r", "")
    if #c > 1000 then c = c:sub(1, 997) .. "..." end
    parts[#parts + 1] = c
  end
  if msg.tool_calls then
    for _, tc in ipairs(msg.tool_calls) do
      local fn = tc and tc["function"]
      if fn then parts[#parts + 1] = "→tool:" .. tostring(fn.name or "?") end
    end
  end
  return table.concat(parts, " ")
end

-- 收集报告。config = 当前配置表；history = load_history() 结果（可选）。
-- 返回报告字符串。
local function collect(config, history)
  local lines = {}
  -- 统一获取 computer 模块（pcall 保护：某些环境无此模块/require 返回 nil）。
  -- 注意不能依赖全局 computer——pcall(computer.uptime) 的参数在 pcall 进入
  -- 前求值，全局缺失（真机 OpenOS）会直接崩溃而非被捕获。
  local ok_comp, computer = pcall(require, "computer")
  if not ok_comp or type(computer) ~= "table" then computer = nil end

  lines[#lines + 1] = "=== OC Agent Debug Report ==="
  -- 时间: os.date 在无 RTC 时返回 epoch (1970)，此时回退用 uptime
  do
    local ts
    local ok_d, d = pcall(os.date, "%Y-%m-%d %H:%M:%S")
    if ok_d and d and d:match("^20%d%d%-") then
      ts = d
    else
      local ok_u, u = false
      if computer then ok_u, u = pcall(computer.uptime) end
      ts = "uptime " .. ((ok_u and u and string.format("%.0f", u) .. "s") or "?")
    end
    lines[#lines + 1] = "Generated: " .. ts
  end
  lines[#lines + 1] = ""

  -- 版本
  local ver = "(未记录)"
  do
    local dir = type(AGENT_DIR) == "string" and AGENT_DIR or ""
    local vf = dir ~= "" and io.open(dir .. "/version.txt", "r")
    if vf then
      local v = vf:read("*a"):gsub("%s", "")
      vf:close()
      if v ~= "" then ver = v end
    end
  end
  lines[#lines + 1] = "Version: " .. ver

  -- 运行状态（computer 已在函数顶部统一获取，可能为 nil；
  -- pcall 参数求值陷阱同上：computer 为 nil 时须先判空再调用）
  local ok_uptime, uptime = false
  if computer then ok_uptime, uptime = pcall(computer.uptime) end
  local ok_mem, free_mem = false
  if computer then ok_mem, free_mem = pcall(computer.freeMemory) end
  local ok_addr, addr = false
  if computer then ok_addr, addr = pcall(computer.address) end
  lines[#lines + 1] = "Uptime: " .. (ok_uptime and string.format("%.1f", uptime) or "?") .. "s"
  lines[#lines + 1] = "Free memory: " .. (ok_mem and tostring(free_mem) or "?") .. " bytes"
  lines[#lines + 1] = "Computer address: " .. (ok_addr and tostring(addr) or "?")
  lines[#lines + 1] = ""

  -- 配置（脱敏：api_key/tavily_key 首尾4位，gist_token 完全遮蔽）
  lines[#lines + 1] = "--- Config ---"
  local cfg = config or {}
  lines[#lines + 1] = "model: " .. tostring(cfg.model or "?")
  lines[#lines + 1] = "api_url: " .. tostring(cfg.api_url or "?")
  lines[#lines + 1] = "api_key: " .. mask(cfg.api_key)
  lines[#lines + 1] = "tavily_key: " .. mask(cfg.tavily_key)
  lines[#lines + 1] = "gist_token: " .. mask_token(cfg.gist_token)
  lines[#lines + 1] = "subagent: " .. tostring(cfg.subagent or false)
  lines[#lines + 1] = ""

  -- 最近会话历史（默认最近 30 条，避免报告过大）
  local max_msgs = 30
  lines[#lines + 1] = "--- Recent history (last " .. max_msgs .. " of " .. tostring(history and #history or 0) .. ") ---"
  if history and #history > 0 then
    local start = math.max(1, #history - max_msgs + 1)
    for i = start, #history do
      lines[#lines + 1] = msg_line(history[i], config)
    end
  else
    lines[#lines + 1] = "(empty)"
  end

  -- 运行时诊断段（v0.3.56）: 内存曲线 / 最后一次内存裁剪 / 最后一次
  -- chat 请求。数据源 init.lua 的 DIAG 表（_G._AGENT_DIAG 全局挂载，
  -- 与 json 全局同先例）。用途: 对话卡死无反馈时（真机第 7 次现场，
  -- gist 5ff1d4——[mem] 裁剪后对话中断）报告可见:
  --   - mem curve: 内存下降路径（哪轮开始跌破阈值）
  --   - last mem trim: 裁剪事件（触发时间/前后 free/裁剪条数）——
  --     若 free_after 未回升说明 GC 未释放堆（裁剪无效）
  --   - last chat: 最后一次请求耗时与错误——elapsed 接近 retry_budget
  --     （默认 300s）说明端点慢/挂起；error 有值说明编码/请求失败
  -- v0.3.66 快照恢复（gist 535cfe 现场丢失教训）: 卡死时重启 agent
  -- 再 /debug，进程内 DIAG 已清空（历史是旧会话加载的，诊断全空）。
  -- 修复: init.lua 每次 chat/裁剪后写 <WRITABLE_BASE>/agent_diag.json，
  -- 此处进程内数据缺失时读文件恢复现场，并标注"（重启前快照）"。
  local diag = type(_G._AGENT_DIAG) == "table" and _G._AGENT_DIAG or nil
  local snapshot = false
  if not diag or (not diag.last_chat and not diag.last_trim) then
    local ok_cfg, cfg_mod = pcall(require, "agent.config")
    if ok_cfg and cfg_mod and cfg_mod.writable_base then
      local ok_f, f = pcall(io.open, cfg_mod.writable_base .. "/agent_diag.json", "r")
      if ok_f and f then
        local content = f:read("*a")
        f:close()
        local ok_j, snap = pcall(json.decode, content)
        if ok_j and type(snap) == "table" and (snap.last_chat or snap.last_trim) then
          diag = snap
          snapshot = true
        end
      end
    end
  end
  if diag then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "--- Diagnostics ---"
    if snapshot then
      lines[#lines + 1] = "来源: agent_diag.json 重启前快照（本次进程无诊断数据）"
    end
    if diag.mem_curve and #diag.mem_curve > 0 then
      local pts = {}
      for _, p in ipairs(diag.mem_curve) do
        pts[#pts + 1] = string.format("%.1fs→%d", p.uptime or 0, p.free or 0)
      end
      lines[#lines + 1] = "mem curve (uptime→free): " .. table.concat(pts, ", ")
    else
      lines[#lines + 1] = "mem curve: (no samples)"
    end
    if diag.last_trim then
      local t = diag.last_trim
      lines[#lines + 1] = "last mem trim: uptime=" .. string.format("%.1fs", t.uptime or 0)
        .. " free_before=" .. tostring(t.free_before)
        .. " removed=" .. tostring(t.removed)
        .. " free_after=" .. tostring(t.free_after)
        .. (t.free_after and t.free_before and t.free_after < t.free_before
          and "  <-- GC 未释放堆（裁剪无效）" or "")
    else
      lines[#lines + 1] = "last mem trim: (never)"
    end
    if diag.last_chat then
      local c = diag.last_chat
      lines[#lines + 1] = "last chat: uptime=" .. string.format("%.1fs", c.uptime or 0)
        .. " elapsed=" .. string.format("%.1fs", c.elapsed or 0)
        .. " error=" .. tostring(c.error or "nil")
    else
      lines[#lines + 1] = "last chat: (never)"
    end
    -- 进行中标记（v0.3.80）: chat_started 有值 = 卡在 chat 请求进行中
    -- （未完成——last_chat 只有上一次成功的）；last_tool 有值 = 卡在
    -- 工具执行中（subagent_call 240s / shell 60s 等长阻塞工具）。
    -- 真机 gist dec2a65 现场（uptime 8.5h 卡死，快照只有上次成功的
    -- 6.8s chat）暴露盲区——卡住的那次请求/工具从未完成，无记录。
    if diag.chat_started then
      local c = diag.chat_started
      lines[#lines + 1] = ">> CHAT IN PROGRESS: started uptime=" .. string.format("%.1fs", c.uptime or 0)
        .. " est_bytes=" .. tostring(c.est or 0)
        .. "  <-- 卡在 chat 请求进行中（从未完成）"
    end
    if diag.last_tool then
      local t = diag.last_tool
      lines[#lines + 1] = ">> TOOL IN PROGRESS: " .. tostring(t.name or "?")
        .. " started uptime=" .. string.format("%.1fs", t.uptime or 0)
        .. "  <-- 卡在工具执行中（从未完成）"
    end
  end

  return table.concat(lines, "\n")
end

-- 上传到 GitHub Gist。返回 (url, err)。
-- v0.3.73 超时保护（真机多次卡死根因，gist 852193/用户反复反馈）:
-- OC internet.request 连接阶段**无超时**（http.lua 的 120s/300s 保护只
-- 覆盖响应迭代与重试预算——连接挂起时 once 不返回，预算检查不到）。
-- 用户网络 api.github.com 不可达时 TCP connect 永久挂起 → /debug 卡在
-- "Uploading..."。修复: 上传跑在 thread 里，外部 waitForAll 带超时
-- （默认 30s，config.debug_upload_timeout 可调）；超时放弃线程返回
-- 提示（报告已写本地）。thread 库不可用（测试/精简环境）时回退同步
-- 调用（行为同旧版）。
local function upload(report, token)
  if not token or token == "" then
    return nil, "no gist token configured (use /gist-token <token>)"
  end
  local http = require("agent.http")
  local body = json.encode({
    description = "OC Agent debug report",
    public = false,
    files = { ["debug_report.txt"] = { content = report } },
  })
  local headers = {
    ["Content-Type"] = "application/json",
    ["Authorization"] = "token " .. token,
    ["Accept"] = "application/vnd.github+json",
    ["User-Agent"] = "oc-agent",
  }
  local thread_ok, thread = pcall(require, "thread")
  if not thread_ok or not thread or not thread.create or not thread.waitForAll then
    -- 无 thread（测试/精简环境）: 同步调用（行为同旧版）
    local code, resp, err = http.post("https://api.github.com/gists", headers, body)
    if err then return nil, "network: " .. tostring(err) end
    if code ~= 201 then
      return nil, "HTTP " .. tostring(code) .. ": " .. tostring(resp):sub(1, 200)
    end
    local url = resp and resp:match('"html_url"%s*:%s*"([^"]+)"')
    if not url then url = resp and resp:match('"url"%s*:%s*"([^"]+)"') end
    return url or "(gist created, no url parsed)"
  end

  -- 线程化 + 超时: 连接挂起不再阻塞主循环
  local result = {}
  local t = thread.create(function()
    local code, resp, err = http.post("https://api.github.com/gists", headers, body)
    result.code, result.resp, result.err = code, resp, err
  end)
  local timeout = 30
  local ok_cfg, cfg = pcall(require, "agent.config")
  if ok_cfg and cfg and cfg.load then
    local ok_c, c = pcall(cfg.load)
    if ok_c and c and c.debug_upload_timeout then
      timeout = tonumber(c.debug_upload_timeout) or 30
    end
  end
  local ok_w, werr = pcall(thread.waitForAll, {t}, timeout)
  if not ok_w or not werr then
    -- 超时或 waitForAll 失败: 放弃（线程后台继续，连接最终由
    -- http.lua 响应超时兜底；不再阻塞用户）
    return nil, "upload timeout after " .. timeout .. "s (network unreachable?) — report saved locally"
  end
  if result.err then return nil, "network: " .. tostring(result.err) end
  if result.code ~= 201 then
    return nil, "HTTP " .. tostring(result.code) .. ": " .. tostring(result.resp):sub(1, 200)
  end
  local url = result.resp and result.resp:match('"html_url"%s*:%s*"([^"]+)"')
  if not url then url = result.resp and result.resp:match('"url"%s*:%s*"([^"]+)"') end
  return url or "(gist created, no url parsed)"
end

return {
  collect = collect,
  upload = upload,
  mask = mask,
  redact = redact,
}
