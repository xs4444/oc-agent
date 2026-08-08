-- status_test.lua: ocvm 真机验证 TUI 模式 io.write 泄漏修复（v0.3.23）
-- 背景: init.lua process_exchange 的 `io.write("Thinking...\n")` 在 TUI 模式
-- （UI_INPUT ~= nil）下被跳过（CLI 残留——io.write 直写终端与状态栏叠加）。
-- 验证:
--   1) TUI 模式（UI_INPUT 非 nil）: process_exchange 不输出 "Thinking"
--   2) REPL 模式（UI_INPUT == nil）: 保留 "Thinking" 输出（回归保护）
--   3) process_exchange 单轮成功（mock LLM 返回 content="ok" 无 tool_calls）
--
-- 关键实现细节（真机实证）:
--   * UI_INPUT 是 agent.lua 模块级 **local**（非全局），测试脚本直接赋值
--     `UI_INPUT = ...` 够不到它。
--   * ocvm 沙箱的 debug 只有 getinfo/getlocal/getupvalue/traceback，
--     无 debug.setupvalue → 无法改 upvalue。
--   * 解法: 加载 agent.lua 前对源码做**测试专用最小接缝**——在
--     `local UI_INPUT = nil` 旁注入 `_G.__TEST_SET_UI = function(f) UI_INPUT = f end`
--     （不改变任何业务逻辑，只暴露一个测试入口），加载后用 __TEST_SET_UI
--     切换 TUI/REPL 模式。产品代码 agent.lua 本身不动。
--   * mock internet.request 照抄 run_tests.lua Tool Loop Guards（next_llm 表）。
--   * 钩子版无协程；log 只写结果文件不 print 屏幕。
-- 用法: lua /mnt/<short>/status_test.lua /mnt/<short>
local base = ({...})[1] or "/mnt"
local PASS, FAIL = 0, 0
local RESULT_NAME = "status_test_result.txt"
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

-- 读取产物 agent.lua 源码，注入测试接缝（仅暴露 setter，不改逻辑）
local f_src = io.open(agent_path, "r")
local src = f_src and f_src:read("*a") or ""
if f_src then f_src:close() end
local SEAM_PATTERN = "local UI_INPUT = nil"
local seam_ok = src:find(SEAM_PATTERN, 1, true) ~= nil
check("UI_INPUT seam pattern found", seam_ok, "pattern=" .. SEAM_PATTERN)
if not seam_ok then log("RESULT: " .. PASS .. " pass, " .. FAIL .. " fail") return end
local seam_src = src:gsub(SEAM_PATTERN,
  "local UI_INPUT = nil\n_G.__TEST_SET_UI = function(f) UI_INPUT = f end", 1)
-- v0.3.24: UI_HOOKS 也是模块级 local（onAssistantText 钩子）→ 同样注入 setter
local SEAM_HOOKS_PATTERN = "local UI_HOOKS = {onToolCall = nil, onAssistantText = nil}"
if seam_src:find(SEAM_HOOKS_PATTERN, 1, true) then
  seam_src = seam_src:gsub(SEAM_HOOKS_PATTERN,
    "local UI_HOOKS = {onToolCall = nil, onAssistantText = nil}\n"
    .. "_G.__TEST_SET_HOOKS = function(h) UI_HOOKS.onAssistantText = h end", 1)
end

_TEST_MODE = true
local chunk, lerr = load(seam_src, "=" .. agent_path)
local ok, err = false, lerr
if chunk then ok, err = pcall(chunk) end
check("agent loads", ok, err)
if not ok then log("RESULT: " .. PASS .. " pass, " .. FAIL .. " fail") return end

-- 验证接缝生效: __TEST_SET_UI 可用
check("UI_INPUT setter injected", type(_G.__TEST_SET_UI) == "function",
  tostring(type(_G.__TEST_SET_UI)))
check("UI_HOOKS setter injected", type(_G.__TEST_SET_HOOKS) == "function",
  tostring(type(_G.__TEST_SET_HOOKS)))

-- agent_test 钩子: process_exchange 入口（_TEST_MODE 下由 agent.lua 暴露）
local pe = agent_test and agent_test.process_exchange
check("process_exchange hook available", type(pe) == "function", tostring(pe))
if type(pe) ~= "function" then log("RESULT: " .. PASS .. " pass, " .. FAIL .. " fail") return end

-- mock LLM: 单轮成功响应 {content="ok"} 无 tool_calls（照抄 run_tests 方式）
local internet = require("internet")
local orig_request = internet.request
local next_llm = nil
local llm_idx = 0
internet.request = function(url, data, headers, method)
  if next_llm and type(next_llm[llm_idx + 1]) == "table" then
    llm_idx = llm_idx + 1
    local body
    local ok_e, e = pcall(function()
      body = json.encode(next_llm[llm_idx])
    end)
    if not ok_e then
      body = '{"choices":[{"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}]}'
    end
    local started = false
    local handle = {}
    setmetatable(handle, {
      __call = function()
        if started then return nil end
        started = true
        return body
      end,
      __index = { response = function() return 200 end },
    })
    return handle
  end
  return orig_request(url, data, headers, method)
end
local function llm_content(content, reasoning, finish)
  local msg = {role = "assistant", content = content}
  if reasoning then msg.reasoning_content = reasoning end
  return {choices = {{message = msg, finish_reason = finish or "stop"}}}
end

-- io.write 捕获（保存原函数，用后恢复）
local orig_io_write = io.write
local captured = {}
local function capture_io_write()
  captured = {}
  io.write = function(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[i] = tostring(select(i, ...)) end
    captured[#captured + 1] = table.concat(parts)
  end
end
local function restore_io_write()
  io.write = orig_io_write
end

local MIN_CFG = {model = "mock", api_url = "https://example.test/chat/completions",
  context_window = 128000, ctx_auto = false}

-- 断言 2: TUI 模式（UI_INPUT 非 nil）→ 不输出 "Thinking"
next_llm = { llm_content("ok") }
llm_idx = 0
_G.__TEST_SET_UI(function() return "" end)
capture_io_write()
local tui_call_ok, tui_res = pcall(function()
  return agent_test.process_exchange({}, MIN_CFG, "hi", false)
end)
restore_io_write()
local tui_out = table.concat(captured, "")
check("TUI mode no Thinking leak", tui_out:find("Thinking", 1, true) == nil,
  "captured='" .. tui_out:sub(1, 120) .. "'")

-- 断言 3: REPL 模式（UI_INPUT = nil）→ 保留 "Thinking"
next_llm = { llm_content("ok") }
llm_idx = 0
_G.__TEST_SET_UI(nil)
capture_io_write()
local repl_call_ok, repl_res = pcall(function()
  return agent_test.process_exchange({}, MIN_CFG, "hi", false)
end)
restore_io_write()
local repl_out = table.concat(captured, "")
check("REPL mode keeps Thinking", repl_out:find("Thinking", 1, true) ~= nil,
  "captured='" .. repl_out:sub(1, 120) .. "'")

-- 断言 4: process_exchange 两轮均成功（无 error）
check("process_exchange succeeds",
  (tui_call_ok and tui_res and not tui_res.error)
  and (repl_call_ok and repl_res and not repl_res.error),
  "tui_ok=" .. tostring(tui_call_ok) .. " repl_ok=" .. tostring(repl_call_ok)
  .. " tui_err=" .. tostring(tui_res and tui_res.error or "none")
  .. " repl_err=" .. tostring(repl_res and repl_res.error or "none"))

-- 断言 5: 调用前后不崩（已隐含于上述 pcall 成功）
check("state status clean", tui_call_ok and repl_call_ok,
  "tui_ok=" .. tostring(tui_call_ok) .. " repl_ok=" .. tostring(repl_call_ok))

-- ══════════════════════════════════════════════════════════════
-- v0.3.24 新增断言
-- ══════════════════════════════════════════════════════════════

-- 断言 6+7: onAssistantText 钩子（TUI 下 assistant 输出走钩子而非 print）
local ok_tui, tui = pcall(require, "agent.tui")
check("tui module available", ok_tui and type(tui) == "table", tostring(ok_tui))
if ok_tui and type(tui) == "table" then
  local tui_init_ok = pcall(function() tui.init({}) end)
  check("tui init ok", tui_init_ok, tostring(tui_init_ok))

  -- 注入 onAssistantText 捕获钩子（模拟 TUI 注册行为）
  local captured_ast = {}
  _G.__TEST_SET_HOOKS(function(s) captured_ast[#captured_ast + 1] = tostring(s) end)
  _G.__TEST_SET_UI(function() return "" end)  -- TUI 模式
  next_llm = { llm_content("hello world") }
  llm_idx = 0
  local ast_ok, ast_res = pcall(function()
    return agent_test.process_exchange({}, MIN_CFG, "hi", false)
  end)
  local ast_joined = table.concat(captured_ast, "")
  check("onAssistantText hook called",
    ast_ok and ast_joined:find("hello world", 1, true) ~= nil,
    "captured='" .. ast_joined:sub(1, 120) .. "'")

  -- 断言: assistant 渲染走角色色（printRole 存在于 tui 模块 + history 含文本）
  local ph_ok, ph = pcall(tui.printRole, "assistant", "hello world")
  local hist_after = tui.history()
  local hist_joined = ""
  for _, e in ipairs(hist_after) do hist_joined = hist_joined .. tostring(e.text or "") end
  check("onAssistantText prints role color",
    ph_ok and hist_joined:find("hello world", 1, true) ~= nil,
    "hist='" .. hist_joined:sub(1, 120) .. "'")

  -- 断言: user input 回显路径（printRole user 前缀 "> " 渲染）
  local h0 = #tui.history()
  local pu_ok, pu = pcall(tui.printRole, "user", "test input")
  local hist2 = tui.history()
  local hist2_joined = ""
  for i = h0 + 1, #hist2 do hist2_joined = hist2_joined .. tostring(hist2[i].text or "") end
  check("user input echoed",
    pu_ok and hist2_joined:find("test input", 1, true) ~= nil,
    "hist='" .. hist2_joined:sub(1, 120) .. "'")
end

-- 断言 8: statusData 回调防御（pcall 兜底，回调抛错不崩）
if ok_tui and type(tui) == "table" then
  local sd_ok = pcall(tui.setStatusData, function() error("boom") end)
  local set_ok = pcall(tui.setStatus, "Ready")
  check("statusData callback defensive", sd_ok and set_ok,
    "sd_ok=" .. tostring(sd_ok) .. " set_ok=" .. tostring(set_ok))
  -- 清理: 恢复默认
  pcall(tui.setStatusData, nil)
end

-- ══════════════════════════════════════════════════════════════
-- v0.3.24 状态栏读屏实证: ctx%/cache%/model 真实渲染
-- （复制 init.lua:4427-4441 真实回调逻辑 + agent_test.cache_stats 真实现）
-- ══════════════════════════════════════════════════════════════
if ok_tui and type(tui) == "table" then
  local gpu = require("component").gpu
  -- 状态栏行 = height-1（同 resolution_test 锚点）
  local function status_row_text()
    local sw, sh = gpu.getResolution()
    local parts = {}
    for x = 1, sw do
      local okg, c = pcall(gpu.get, x, sh - 1)
      if okg and c then parts[#parts + 1] = c end
    end
    return table.concat(parts)
  end
  -- 复制 init.lua 回调逻辑（usage 用测试注入，模拟 LAST_USAGE）
  local status_usage = nil
  local status_cfg = {context_window = 128000, model = "mock-model"}
  local function real_status_cb()
    local parts = {}
    if status_usage and status_usage.prompt_tokens then
      local win = tonumber(status_cfg.context_window) or 128000
      local pt = tonumber(status_usage.prompt_tokens) or 0
      local pct = win > 0 and (pt / win * 100) or 0
      parts[#parts + 1] = string.format("ctx %.0f%%", pct)
      local hit, miss = agent_test.cache_stats(status_usage)
      if hit and hit + miss > 0 then
        parts[#parts + 1] = string.format("cache %.0f%%", hit / (hit + miss) * 100)
      end
    end
    parts[#parts + 1] = status_cfg.model
    return table.concat(parts, "  ")
  end

  -- 断言 9: 典型 usage（字符串字段 + cached_tokens）→ 状态栏含 ctx/cache/model
  status_usage = {prompt_tokens = "446", prompt_tokens_details = {cached_tokens = 400}}
  pcall(tui.setStatusData, real_status_cb)
  local set9 = pcall(tui.setStatus, "Ready")
  local row9 = status_row_text()
  check("statusData shows ctx and cache",
    set9 and row9:find("ctx", 1, true) ~= nil and row9:find("cache", 1, true) ~= nil
    and row9:find("mock-model", 1, true) ~= nil and row9:find("Ready", 1, true) ~= nil,
    "row='" .. row9 .. "'")

  -- 断言 10: 无缓存字段 → 状态栏仍含 model（且含 ctx）
  status_usage = {prompt_tokens = 1000}
  local set10 = pcall(tui.setStatus, "Ready")
  local row10 = status_row_text()
  check("statusData shows model name",
    set10 and row10:find("mock-model", 1, true) ~= nil and row10:find("ctx", 1, true) ~= nil,
    "row='" .. row10 .. "'")

  -- 断言 11: 怪异 usage（字符串 token + 非表 details）→ 不崩，状态栏仍含 model
  status_usage = {prompt_tokens = "x", prompt_tokens_details = true}
  local set11 = pcall(tui.setStatus, "Ready")
  local row11 = status_row_text()
  check("statusData survives weird usage",
    set11 and row11:find("mock-model", 1, true) ~= nil,
    "row='" .. row11 .. "'")

  pcall(tui.setStatusData, nil)
  status_usage = nil
end

-- 恢复
internet.request = orig_request
_G.__TEST_SET_UI(nil)
_G.__TEST_SET_HOOKS(nil)
log("")
log("RESULT: " .. PASS .. " pass, " .. FAIL .. " fail")
