-- memcurve_test.lua: ocvm 真机内存曲线采样（验证 agent 加载 + 工具循环内存波动源）
-- 背景: 荒野大师真机 10s 采样 free 内存 min 926KB / max 1.5MB / avg 1.47MB（波动 ±594KB）;
-- 该环境 collectgarbage 为 nil。本测试验证: ocvm（完整 OC 模拟 lua5.3 + OpenOS 标准沙箱）
-- 是否也缺 collectgarbage，并用 computer.freeMemory() 作为观测手段采样内存曲线。
-- 采样项:
--   1) collectgarbage 可用性（OpenOS 沙箱白名单——预期 nil，与荒野大师一致）
--   2) GC 锯齿: 20 轮 × 小批量字符串分配 → freeMemory 采样（看是否有上升/回落锯齿）
--   3) 响应模拟: ~40KB JSON decode → 驻留 → 丢弃 → 采样
--   4) messages 驻留: 15 轮对话累积 → trim 到一半 → 采样
--   5) min/max/swing 总结（同荒野大师格式可对比）
-- 观测: computer.freeMemory()（KB）——机器 4096k RAM, OpenOS 自身占一部分。
-- 注意: freeMemory 是"剩余"内存——曲线反向（分配→free 降, 丢弃→free 升）。
-- 钩子版（无协程）; log 只写结果文件不 print 屏幕; 每轮 os.sleep 防 yield 超时。
-- 用法: lua /mnt/<short>/memcurve_test.lua /mnt/<short>
local base = ({...})[1] or "/mnt"
local PASS, FAIL = 0, 0
local RESULT_NAME = "memcurve_test_result.txt"
local function log(...)
  local parts = {}
  for i = 1, select("#", ...) do parts[i] = tostring(select(i, ...)) end
  local line = table.concat(parts, " ")
  local fs_ok, fs = pcall(require, "filesystem")
  if fs_ok and fs.list then
    for item in fs.list("/mnt") do
      local okf, f = pcall(io.open, "/mnt/" .. item .. "/" .. RESULT_NAME, "a")
      if okf and f then f:write(line .. "\n") f:close() end
    end
  end
end
pcall(function() io.open(base .. "/" .. RESULT_NAME, "w"):close() end)
local function check(name, cond, detail)
  if cond then PASS = PASS + 1 log("PASS " .. name)
  else FAIL = FAIL + 1 log("FAIL " .. name .. (detail and (" -- " .. tostring(detail)) or "")) end
end

local fs = require("filesystem")
local agent_path = fs.exists(base .. "/agent.lua") and (base .. "/agent.lua") or nil
if not agent_path then
  for item in fs.list("/mnt") do
    local full = "/mnt/" .. item
    if fs.exists(full .. "/agent.lua") then agent_path = full .. "/agent.lua" break end
  end
end
log("agent at " .. tostring(agent_path))
_TEST_MODE = true
local ok, err = pcall(dofile, agent_path)
check("agent loads", ok, err)
if not ok then log("RESULT: " .. PASS .. " pass, " .. FAIL .. " fail") return end

-- 内存观测: collectgarbage（OpenOS 沙箱白名单无 → nil）+ require("computer").freeMemory()
-- （ocvm/荒野大师均为标准 OpenOS 沙箱: collectgarbage/computer 全局均不在白名单,
--   computer 只能经 require 取; freeMemory 返回字节, 转 KB）
local gc_avail = type(collectgarbage) == "function"
check("collectgarbage available", gc_avail, "type=" .. tostring(type(collectgarbage)))
local computer_mod = nil
local ok_cm, cm = pcall(require, "computer")
if ok_cm and type(cm) == "table" then computer_mod = cm end
local total_mem = 0
local function free_kb()
  if computer_mod then
    local ok_f, fm = pcall(computer_mod.freeMemory)
    if ok_f and fm then
      if total_mem == 0 then
        local ok_t, tm = pcall(computer_mod.totalMemory)
        total_mem = ok_t and tm or 0
      end
      return math.floor(fm / 1024)
    end
  end
  return 0
end

local samples = {}
local function sample(tag)
  local kb = free_kb()
  samples[#samples + 1] = kb
  log("MEM " .. tag .. ": " .. tostring(kb) .. "KB free")
end

local total_min, total_max = math.huge, 0

-- ═══ 1) GC 锯齿: 20 轮 × 小批量分配（不触发 OOM） ═══
log("--- phase1: allocation sawtooth (freeMemory, KB) ---")
sample("p1_0")
local chunk = string.rep("y", 2048)  -- 2KB 块
for i = 1, 20 do
  local junk = {}
  for j = 1, 10 do junk[j] = chunk .. tostring(j) end
  junk = nil
  os.sleep(0.01)
  sample("p1_" .. i)
end
-- 主动等 GC（若可用; 不可用则靠沙箱自动 GC）
if gc_avail then
  local ok_c, after = pcall(collectgarbage, "count")
  if ok_c then log("GC count after phase1: " .. tostring(math.floor(after)) .. "KB") end
else
  log("collectgarbage nil — rely on sandbox auto-GC")
end
os.sleep(0.02)
sample("p1_after_settle")

-- ═══ 2) 响应模拟: ~40KB JSON decode → 驻留 → 丢弃 ═══
log("--- phase2: response decode (freeMemory, KB) ---")
sample("p2_before")
do
  local content = string.rep("响应内容", 5000)   -- ~15KB
  local reasoning = string.rep("思考过程", 4000)  -- ~12KB
  local tool_args = string.rep("参数数据", 3000)  -- ~9KB
  local body = '{"choices":[{"message":{"role":"assistant","content":"' .. content
    .. '","reasoning_content":"' .. reasoning .. '","tool_calls":[{"function":{"name":"read_file","arguments":"'
    .. tool_args .. '"}}]},"finish_reason":"stop"}],"usage":{"prompt_tokens":1500}}'
  log("response json bytes: " .. tostring(#body))
  sample("p2_alloc_before_decode")
  local ok_j, json = pcall(require, "agent.json")
  local decoded = nil
  if ok_j and json and json.decode then
    local ok_d, d = pcall(json.decode, body)
    if ok_d and d then
      decoded = d
      log("decode ok")
    else
      log("decode err: " .. tostring(d))
    end
  else
    log("agent.json unavailable, skip decode")
  end
  sample("p2_after_decode_hold")
  decoded = nil
  os.sleep(0.02)
  sample("p2_after_drop")
end
sample("p2_after_block")

-- ═══ 3) messages 驻留: 15 轮对话累积 → trim 到一半 ═══
log("--- phase3: messages retention (freeMemory, KB) ---")
sample("p3_0")
local msgs = {}
for i = 1, 15 do
  msgs[#msgs + 1] = {role = "user", content = "第 " .. i .. " 轮用户问题 " .. string.rep("u", 300)}
  msgs[#msgs + 1] = {role = "assistant", content = "第 " .. i .. " 轮回复内容 " .. string.rep("a", 900)}
  msgs[#msgs + 1] = {role = "tool", content = "工具结果 " .. string.rep("t", 700)}
  os.sleep(0.005)
end
sample("p3_after15")
local trimmed = {}
for i = 1, #msgs do
  if i % 2 == 0 then trimmed[#trimmed + 1] = msgs[i] end
end
msgs = trimmed
os.sleep(0.02)
sample("p3_after_trim")
msgs = nil
os.sleep(0.02)
sample("p3_after_drop_all")

-- ═══ 4) 总结: min/max/swing（同荒野大师格式） ═══
log("--- summary ---")
for i, kb in ipairs(samples) do
  if kb < total_min then total_min = kb end
  if kb > total_max then total_max = kb end
end
log("MEM SUMMARY min_free=" .. tostring(total_min) .. "KB max_free=" .. tostring(total_max)
  .. "KB swing=" .. tostring(total_max - total_min) .. "KB")
log("MEM samples count=" .. #samples)
-- 锯齿/波动判定: 相邻样本差绝对值 >1KB 的次数（freeMemory 反向: 升=回收, 降=分配）
local upsteps, downsteps = 0, 0
for i = 2, #samples do
  local d = samples[i] - samples[i - 1]
  if d > 1 then upsteps = upsteps + 1
  elseif d < -1 then downsteps = downsteps + 1 end
end
log("free+ steps (reclaim): " .. upsteps .. ", free- steps (alloc): " .. downsteps)
check("agent loads", ok, err)
log("")
log("RESULT: " .. PASS .. " pass, " .. FAIL .. " fail")
