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

  return table.concat(lines, "\n")
end

-- 上传到 GitHub Gist。返回 (url, err)。
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
  local code, resp, err = http.post("https://api.github.com/gists", headers, body)
  if err then return nil, "network: " .. tostring(err) end
  if code ~= 201 then
    return nil, "HTTP " .. tostring(code) .. ": " .. tostring(resp):sub(1, 200)
  end
  local url = resp and resp:match('"html_url"%s*:%s*"([^"]+)"')
  if not url then url = resp and resp:match('"url"%s*:%s*"([^"]+)"') end
  return url or "(gist created, no url parsed)"
end

return {
  collect = collect,
  upload = upload,
  mask = mask,
  redact = redact,
}
