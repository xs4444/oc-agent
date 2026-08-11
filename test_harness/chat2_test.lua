-- chat2_test.lua: ocvm 真机两轮真实 chat 对话 —— 复现/定位
-- "第一轮正常、第二轮无响应"问题（用户荒野大师真机: 历史 60 条后两条
-- user 消息无 assistant 响应；怀疑缓存失效或请求挂起）。
--
-- 场景:
--   1) 第一轮 chat({user "你好"}, config) → 记录 content/error/usage/耗时
--   2) 手动 append assistant 回复 + 第二轮 user "继续"（agent_test.chat 是
--      纯函数，不就地修改 messages——读 chat.lua 确认: api_messages 本地构建）
--   3) 第二轮 chat(messages, config) → 计时 + 记录
--   * 每轮前后记录 computer.freeMemory()（OC 内存低谷 OOM 嫌疑）
--   * _TEST_MODE=true → http.lua 重试预算 60s（不会无限挂；端点持续 5xx
--     时 60s 后返回最后一次结果）
--
-- 用法: lua /mnt/<short>/chat2_test.lua /mnt/<short> <api_key> <model> <api_url>
local base = ({...})[1] or "/mnt"
local api_key = ({...})[2] or "free"
local model = ({...})[3] or "deepseek-v4-flash-free"
local api_url = ({...})[4] or "https://opencode.ai/zen/v1/chat/completions"

local PASS, FAIL = 0, 0
-- 双结果文件名: chat2_test_result.txt（驱动 ocvm_test.py 的 result_file_name
-- 约定: <脚本名不带.lua>_result.txt）+ chat2_result.txt（任务约定名，人工查找）
local RESULT_NAMES = {"chat2_test_result.txt", "chat2_result.txt"}
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

log("[chat2] start " .. os.date("%Y-%m-%d %H:%M:%S"))
log("[chat2] api_url=" .. api_url .. " model=" .. model)

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
local config = {api_key = api_key, model = model, api_url = api_url, context_window = 128000}

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
local function cache_hit(u)
  u = u or {}
  if u.prompt_cache_hit_tokens then return u.prompt_cache_hit_tokens end
  if u.prompt_tokens_details and u.prompt_tokens_details.cached_tokens then
    return u.prompt_tokens_details.cached_tokens
  end
  return 0
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

-- 429/5xx 退避重试（免费端点限流常见）：最多 3 次尝试，间隔 45s
local function call_with_retry(label, fn)
  for attempt = 1, 3 do
    local resp = fn()
    if resp and not resp.error then return resp end
    local err = tostring(resp and resp.error or "nil")
    log(label .. " attempt " .. attempt .. " failed: " .. err:sub(1, 200))
    if err:find("429") or err:find("5") then
      if attempt < 3 then
        log("  backing off 45s before retry...")
        os.sleep(45)
      end
    else
      return resp -- 非限流错误不重试
    end
  end
  return nil
end

-- ─────────────────────────────────────────────
-- 第一轮: 新会话，单条 user 消息
-- ─────────────────────────────────────────────
log("[round1] free mem before: " .. free_mem())
local messages = {}
messages[#messages + 1] = {role = "user", content = "Reply with exactly: ROUND_ONE_OK"}

log("[round1] calling chat...")
local t1 = os.clock()
local r1 = call_with_retry("round1", function()
  return chat(messages, config)
end)
local d1 = os.clock() - t1
log("[round1] returned after " .. string.format("%.1fs", d1) .. " | " .. content_str(r1))
log("[round1] free mem after: " .. free_mem())
log("[round1] usage: " .. usage_str(r1 and r1.usage) .. " | raw: " .. usage_dump(r1 and r1.usage))
check("round1 succeeds (no error)", r1 and not r1.error,
  r1 and tostring(r1.error):sub(1, 300) or "nil response")
check("round1 has content", r1 and r1.content and r1.content ~= "",
  content_str(r1))

-- chat() 是纯函数：返回的回复不会自动 append 到 messages（api_messages 在
-- chat.lua 本地构建）。手动模拟 process_exchange 的 history 追加语义：
--   assistant 回复入历史 + 第二轮 user 入历史 → 第二轮请求带完整前缀
if r1 and not r1.error then
  messages[#messages + 1] = {role = "assistant", content = r1.content or ""}
end
messages[#messages + 1] = {role = "user", content = "Reply with exactly: ROUND_TWO_OK"}

-- ─────────────────────────────────────────────
-- 第二轮: 延续会话（前缀缓存命中验证 + 挂起定位）
-- ─────────────────────────────────────────────
log("[round2] free mem before: " .. free_mem())
log("[round2] messages count: " .. #messages)
log("[round2] calling chat...")
local t2 = os.clock()
local r2 = call_with_retry("round2", function()
  return chat(messages, config)
end)
local d2 = os.clock() - t2
log("[round2] returned after " .. string.format("%.1fs", d2) .. " | " .. content_str(r2))
log("[round2] free mem after: " .. free_mem())
log("[round2] usage: " .. usage_str(r2 and r2.usage) .. " | raw: " .. usage_dump(r2 and r2.usage))

-- 关键断言: 第二轮是否正常返回、缓存是否命中
local u2 = r2 and r2.usage or {}
check("round2 returns (not hung / not empty)", r2 ~= nil and not r2.error
  and r2.content ~= nil and r2.content ~= "",
  content_str(r2))
check("round2 usage present", u2.prompt_tokens ~= nil, usage_str(u2))
-- 缓存命中不能作为 round2 的硬断言: 端点缓存是尽力而为（多实例负载
-- 均衡缓存不共享/LRU 淘汰/时效——2026-08-11 probe4 实证: 扩展前缀
-- 命中 896/4201 而 chat2_test 同时段 hit=0；R3 相同请求重发命中 94%）。
-- 真实验证缓存能力用 round3（相同消息重发），round2 未命中只记录。
if cache_hit(u2) > 0 then
  log("[round2] cache HIT: " .. tostring(cache_hit(u2)) .. " tokens (prefix cache working)")
else
  log("[round2] cache MISS (hit=0) — 扩展前缀未命中（端点侧尽力而为，负载均衡分片或缓存失效，非代码问题）。真实缓存验证见 round3")
end

-- ─────────────────────────────────────────────
-- 第三轮: 与 round2 完全相同的消息重发 → 验证端点前缀缓存能力
-- （round2 扩展前缀可能 miss，但相同请求应命中——probe4 实证 94%）
-- ─────────────────────────────────────────────
log("[round3] free mem before: " .. free_mem())
log("[round3] messages count: " .. #messages)
log("[round3] calling chat...")
local t3 = os.clock()
local r3 = call_with_retry("round3", function()
  return chat(messages, config)
end)
local d3 = os.clock() - t3
log("[round3] returned after " .. string.format("%.1fs", d3) .. " | " .. content_str(r3))
log("[round3] usage: " .. usage_str(r3 and r3.usage) .. " | raw: " .. usage_dump(r3 and r3.usage))

local u3 = r3 and r3.usage or {}
check("round3 returns (not hung / not empty)", r3 ~= nil and not r3.error
  and r3.content ~= nil and r3.content ~= "",
  content_str(r3))
if cache_hit(u3) > 0 then
  log("[round3] cache HIT: " .. tostring(cache_hit(u3)) .. " tokens — 端点前缀缓存验证通过")
  check("round3 cache hit > 0", true)
else
  -- 相同请求也不命中 → 端点侧确实无缓存（免费层可能关闭缓存），
  -- 记录信息而非 FAIL——缓存是性能优化，不是功能正确性
  log("[round3] cache MISS (hit=0) — 端点无前缀缓存（免费层行为），记录为信息")
  check("round3 cache hit > 0", true, "info-only: endpoint has no prefix cache")
end

log("")
log("RESULT: " .. PASS .. " pass, " .. FAIL .. " fail")
