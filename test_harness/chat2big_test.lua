-- chat2big_test.lua: ocvm 验证"大历史 encode 内存不足"假设
--
-- 真机 gist 现象: 第二轮两条 user 消息入历史但无 assistant 响应（快速返回
-- = error 可能性大）；agent 自测内存低谷 278KB、历史 60 条含大工具结果。
--
-- 假设: 60+ 条真实体积历史（tool 结果 ~3000B = MAX_TOOL_RESULT 上限）在
-- chat() 内 json.encode 时峰值内存超可用 → pcall 捕获（chat.lua:171-189）
-- → 返回 {error="请求编码失败（内存不足）: ..."}。encode 在发 HTTP 之前
-- 同步失败 → "快速返回"；而 user 消息在 chat() 之前已 append_history
-- （init.lua:742）→ "两条 user 入历史、无 assistant、无错误记录"。
--
-- 本测试:
--   1) 构造 20 轮 {user(30字), assistant(500-800字中文), tool(3000B)} = 60 条
--      真实体积历史（模拟真机探索），每轮 log 累计字节数
--   2) 探针: 精确复刻 chat.lua 的 payload（system+messages+tools+runtime）
--      并 json.encode，测出请求体字节数（encode 内存压力的直接证据）
--   3) 第一轮: append user "第一轮输入" → chat() → append assistant 响应
--   4) 第二轮: append user "继续" → chat()（计时 + freeMemory + error 原文）
--   * 断言: 第二轮 error 含"内存不足"/"编码失败" = 复现成功；
--     正常返回则报 content/usage，说明 ocvm 大历史不 OOM（真机差异在环境/低谷）
--
-- 用法: lua /mnt/<short>/chat2big_test.lua /mnt/<short> <api_key> <model> <api_url>
local base = ({...})[1] or "/mnt"
local api_key = ({...})[2] or "free"
local model = ({...})[3] or "deepseek-v4-flash-free"
local api_url = ({...})[4] or "https://opencode.ai/zen/v1/chat/completions"

local PASS, FAIL = 0, 0
-- 双结果文件名: chat2big_test_result.txt（驱动 ocvm_test.py 的 result_file_name
-- 约定: <脚本名不带.lua>_result.txt）+ chat2big_result.txt（任务约定名，人工查找）
local RESULT_NAMES = {"chat2big_test_result.txt", "chat2big_result.txt"}
local function log(...)
  local parts = {}
  for i = 1, select("#", ...) do parts[i] = tostring(select(i, ...)) end
  local line = table.concat(parts, " ")
  print(line)
  -- 写到所有挂载盘（宿主机 find 任一挂载都能抓到）
  local fs_ok, fs = pcall(require, "filesystem")
  if fs_ok and fs.list then
    for item in fs.list("/mnt") do
      for _, rn in ipairs(RESULT_NAMES) do
        local f = io.open("/mnt/" .. item .. "/" .. rn, "a")
        if f then f:write(line .. "\n") f:close() end
      end
    end
  end
end
for _, rn in ipairs(RESULT_NAMES) do io.open(base .. "/" .. rn, "w"):close() end
local function check(name, cond, detail)
  if cond then PASS = PASS + 1 log("PASS " .. name)
  else FAIL = FAIL + 1 log("FAIL " .. name .. (detail and (" -- " .. tostring(detail)) or "")) end
end

log("[chat2big] start " .. os.date("%Y-%m-%d %H:%M:%S"))
log("[chat2big] api_url=" .. api_url .. " model=" .. model)

local fs = require("filesystem")
local agent_path
for item in fs.list("/mnt") do
  local full = "/mnt/" .. item
  if fs.exists(full .. "/agent.lua") then agent_path = full .. "/agent.lua" break end
end
if not agent_path then log("ERROR: agent.lua not found") log("RESULT: 0 pass, 0 fail") return end

_TEST_MODE = true
local ok, err = pcall(dofile, agent_path)
check("agent loads", ok, err)
if not ok then log("RESULT: " .. PASS .. " pass, " .. FAIL .. " fail") return end

local chat = agent_test.chat
-- max_tokens=256: 大历史请求的响应只用于确认 encode/网络路径正常，
-- 限制输出侧时长（encode 发生在任何响应之前，不影响本测试目的）
local config = {api_key = api_key, model = model, api_url = api_url,
  context_window = 128000, max_tokens = 256}

local function free_mem()
  local ok_c, computer = pcall(require, "computer")
  if ok_c and computer and computer.freeMemory then
    local ok_f, m = pcall(computer.freeMemory)
    if ok_f then return tostring(m) end
  end
  return "n/a"
end

local function usage_str(u)
  u = u or {}
  return "hit=" .. tostring(u.prompt_cache_hit_tokens or 0)
    .. " miss=" .. tostring(u.prompt_cache_miss_tokens or 0)
    .. " total=" .. tostring(u.prompt_tokens or 0)
end
local function usage_dump(u)
  u = u or {}
  local parts = {}
  for k, v in pairs(u) do
    if type(v) == "table" then
      local sub = {}
      for k2, v2 in pairs(v) do sub[#sub + 1] = tostring(k2) .. "=" .. tostring(v2) end
      parts[#parts + 1] = tostring(k) .. "={" .. table.concat(sub, ",") .. "}"
    else
      parts[#parts + 1] = tostring(k) .. "=" .. tostring(v)
    end
  end
  return table.concat(parts, " ")
end
local function content_str(r)
  if not r then return "nil response" end
  if r.error then return "ERROR: " .. tostring(r.error):sub(1, 200) end
  local c = tostring(r.content or "")
  return "content[" .. #c .. "]=" .. c:sub(1, 100)
end

-- ─────────────────────────────────────────────
-- 构造大历史: 20 轮 { user(30字), assistant(500-800字中文),
--   tool(3000B = MAX_TOOL_RESULT 上限附近) } = 60 条
-- ─────────────────────────────────────────────
local messages = {}
local total_bytes = 0
local function push(msg)
  messages[#messages + 1] = msg
  total_bytes = total_bytes + #(msg.content or "")
      + #(msg.tool_calls and tostring(msg.tool_calls) or "")
end

-- 用中文+ASCII 填充到精确 target 字节（utf8 中文字符 = 3 字节，
-- 中文比 ASCII 更占 encode 体积——模拟真实探索输出）
local PAD_ZH = "探索执行中：模块状态与数据一致性校验通过，结果记录于当前会话上下文。"
local function zh_pad(s, target)
  while #s < target - 20 do s = s .. PAD_ZH end
  s = s .. string.rep("a", math.max(0, target - #s))
  return s
end

local function user_short(i)
  return string.format("第%d轮：探索配置文件目录并核对组件清单，等待结果并继续", i)
end

local function assistant_report(i)
  local zh1 = "已核对配置文件与组件地址清单，路径映射与离线文档描述一致，未发现偏差；"
  local zh2 = "部分配置文件 enable 字段与预期不符，怀疑为模板生成差异，已记录现场；"
  local zh3 = "通过 component_list 扫描外围设备，地址归属正常，调用返回码均为 0；"
  local ascii = " config_scan(): entries=12; checksum=0x" .. string.format("%X", 0x3F2A + i)
      .. "; status=OK "
  local s = "本轮探索总结（第 " .. i .. " 轮）:"
  local n = 0
  -- 500-800 字符（中英混合）→ 目标字节 ~1600-2100
  while n < 1600 do
    s = s .. zh1; n = n + #zh1
    if n < 1600 then s = s .. zh2; n = n + #zh2 end
    if n < 1600 then s = s .. zh3; n = n + #zh3 end
    if n < 1600 then s = s .. ascii; n = n + #ascii end
  end
  return s
end

local function tool_result(i)
  -- KEY_FIELD 风格 JSON 工具结果，填充到 3000 字节（MAX_TOOL_RESULT 上限）
  local s = '{"status":"ok","KEY_FIELD_' .. i .. '":"'
  s = s .. zh_pad("", 2400)
  s = s .. '","path":"/etc/gtnh/config_' .. i .. '.cfg","hits":[{"line":12,"text":"探索记录"}],'
  s = s .. '"checksum":"0x' .. string.format("%X", 0x9A3F + i) .. '"}'
  return zh_pad(s, 3000)
end

log("[build] sample sizes: user=" .. #user_short(1) .. "B assistant="
  .. #assistant_report(1) .. "B tool=" .. #tool_result(1) .. "B")
log("[build] free mem before: " .. free_mem())
for i = 1, 20 do
  push({role = "user", content = user_short(i)})
  push({role = "assistant", content = assistant_report(i)})
  push({role = "tool", tool_call_id = "call_" .. i, content = tool_result(i)})
  log("[build] round " .. i .. ": messages=" .. #messages
    .. " est_content_bytes=" .. total_bytes .. " free=" .. free_mem())
end
check("big history built (>=60 msgs)", #messages >= 60, "#messages=" .. #messages)
check("big history volume >= 80KB", total_bytes >= 80000,
  total_bytes .. " bytes (target 150KB or at least 80KB)")
log("[build] done: messages=" .. #messages .. " est_content_bytes=" .. total_bytes)

-- ─────────────────────────────────────────────
-- 探针: 精确复刻 chat.lua 的 payload 并 encode，测量请求体字节
-- （encode 内存压力的直接证据——OC 内存 1.4MB，encode 峰值 ~1.2x 文本）
-- ─────────────────────────────────────────────
log("[probe] replicating chat.lua payload encode (system+messages+tools+runtime)...")
local probe_free_before = free_mem()
local ok_enc_probe, body = false, nil
do
  local ok_json, json = pcall(require, "agent.json")
  local ok_tools, tools_mod = pcall(require, "agent.tools")
  if ok_json and ok_tools then
    local api_messages = {}
    api_messages[#api_messages + 1] = {role = "system", content = agent_test.build_system_prompt()}
    for _, m in ipairs(messages) do api_messages[#api_messages + 1] = m end
    api_messages[#api_messages + 1] = {role = "user", content = agent_test.build_runtime_block()}
    local okp, bod = pcall(json.encode, {
      model = model,
      messages = api_messages,
      tools = tools_mod.list(),
      max_tokens = 256,
      temperature = 0.7,
    })
    ok_enc_probe, body = okp, bod
  else
    body = "require agent.json/tools failed: " .. tostring(ok_json) .. "/" .. tostring(ok_tools)
  end
end
if ok_enc_probe then
  log("[probe] encode OK: payload_body_bytes=" .. #body)
  check("encode probe OK (60-msg history, no OOM)", true)
else
  log("[probe] encode FAILED: " .. tostring(body):sub(1, 300))
  check("encode probe OK (60-msg history, no OOM)", false, tostring(body):sub(1, 300))
end
log("[probe] free mem before=" .. probe_free_before .. " after=" .. free_mem())

-- ─────────────────────────────────────────────
-- 第一轮: 60 条历史 + user "第一轮输入" → chat → append assistant 响应
-- ─────────────────────────────────────────────
messages[#messages + 1] = {role = "user", content = "第一轮输入"}
total_bytes = total_bytes + #"第一轮输入"
log("[round1] free mem before: " .. free_mem() .. " messages=" .. #messages
  .. " est_content_bytes=" .. total_bytes)
log("[round1] calling chat...")
local t1 = os.clock()
local r1 = chat(messages, config)
local d1 = os.clock() - t1
log("[round1] returned after " .. string.format("%.1fs", d1) .. " | " .. content_str(r1))
log("[round1] free mem after: " .. free_mem())
if r1 and r1.usage then
  log("[round1] usage: " .. usage_str(r1.usage) .. " | raw: " .. usage_dump(r1.usage))
end

local r1err = r1 and tostring(r1.error) or ""
if r1 and r1.error and (r1err:find("内存不足") or r1err:find("编码失败")) then
  check("round1 encode OOM reproduced (memory-error)", true, r1.error)
else
  check("round1 succeeds (no error)", r1 ~= nil and not r1.error, r1err:sub(1, 300))
end

if r1 and not r1.error then
  messages[#messages + 1] = {role = "assistant", content = r1.content or ""}
end

-- ─────────────────────────────────────────────
-- 第二轮: append user "继续" → chat（关键: 60+ 条历史，encode 内存峰值最高点）
-- ─────────────────────────────────────────────
messages[#messages + 1] = {role = "user", content = "继续"}
log("[round2] free mem before: " .. free_mem() .. " messages=" .. #messages)
log("[round2] calling chat...")
local t2 = os.clock()
local r2 = chat(messages, config)
local d2 = os.clock() - t2
log("[round2] returned after " .. string.format("%.1fs", d2) .. " | " .. content_str(r2))
log("[round2] free mem after: " .. free_mem())
if r2 and r2.usage then
  log("[round2] usage: " .. usage_str(r2.usage) .. " | raw: " .. usage_dump(r2.usage))
end

local r2err = r2 and tostring(r2.error) or ""
if r2 and r2.error and (r2err:find("内存不足") or r2err:find("编码失败")) then
  -- 复现成功: OOM → error 路径实证（真机第二轮快速返回 = 此路径）
  check("round2 encode OOM reproduced (memory-error)", true, r2.error)
  log("[chat2big] HYPOTHESIS REPRODUCED: 大历史 encode 内存不足 → chat 返回 error")
elseif r2 and not r2.error then
  -- 正常返回: ocvm 大历史不 OOM（真机差异在环境/内存低谷 278KB）
  check("round2 returns (no error)", r2.content ~= nil, content_str(r2))
  check("round2 usage present", r2.usage ~= nil and r2.usage.prompt_tokens ~= nil,
    usage_str(r2.usage))
  log("[chat2big] round2 OK: ocvm 大历史 encode 不 OOM（fresh VM 内存充足；"
    .. "真机低谷 278KB 时 encode 峰值 ~1.2x 文本可能超限）")
else
  check("round2 returns (no error)", false, r2err:sub(1, 300))
end

log("")
log("[chat2big] final: messages=" .. #messages .. " est_content_bytes=" .. total_bytes)
log("RESULT: " .. PASS .. " pass, " .. FAIL .. " fail")
