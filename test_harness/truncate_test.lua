-- truncate_test.lua: ocvm 真机验证 v0.3.25 截断机制（MAX_TOOL_RESULT head+tail /
-- read_file 400 行/20KB 帽 + offset 续读 / search_files 超长行 [line truncated]）
-- 骨架仿 printhistory_test: base/_TEST_MODE/pcall dofile agent/log 只写结果文件。
-- 调用方式:
--   * head+tail 截断走真实路径: mock LLM tool_call read_file → process_exchange
--     （MAX_TOOL_RESULT 截断在 process_exchange 内执行, 照抄 run_tests 方式）
--   * read_file 帽/search_files 标记: 直接调全局 execute_tool（dofile 后可用）
-- 用法: lua /mnt/<short>/truncate_test.lua /mnt/<short>
local base = ({...})[1] or "/mnt"
local PASS, FAIL = 0, 0
local RESULT_NAME = "truncate_test_result.txt"
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
check("execute_tool available", type(execute_tool) == "function", tostring(type(execute_tool)))

-- json 编码（agent 内部 require agent.json 亦可用；这里用全局 json 兜底）
local function encode(v)
  local ok_j, j = pcall(require, "agent.json")
  if ok_j and j and j.encode then return j.encode(v) end
  return json.encode(v)
end

-- 测试文件目录: 用数据盘（base 可写）
local WR = base

-- ═══ 断言 1: MAX_TOOL_RESULT head+tail（走 process_exchange 真实路径）═══
-- 构造 >3000 字节含中文的大文件
local big_path = WR .. "/trunc_big.txt"
do
  local head_sentinel = "HEAD_START_甲乙丙"
  local tail_sentinel = "TAIL_END_子丑寅"
  local body = string.rep("数据行", 400)   -- ~1200 字节
  local content = head_sentinel .. "\n" .. body .. "\n" .. tail_sentinel
  local fw = io.open(big_path, "w")
  fw:write(content)
  fw:close()
  log("big file bytes: " .. tostring(#content))

  -- mock LLM: tool_call read_file → 然后正常回答（照抄 run_tests）
  local next_llm = nil
  local llm_idx = 0
  local internet = require("internet")
  local orig_request = internet.request
  internet.request = function(url, data, headers, method)
    if next_llm and type(next_llm[llm_idx + 1]) == "table" then
      llm_idx = llm_idx + 1
      local body
      local ok_e, e = pcall(function() body = encode(next_llm[llm_idx]) end)
      if not ok_e then
        body = '{"choices":[{"message":{"role":"assistant","content":"done"},"finish_reason":"stop"}]}'
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
  local function llm_tool_calls(calls, finish)
    return {choices = {{message = {role = "assistant", content = nil, tool_calls = calls},
      finish_reason = finish or "stop"}}}
  end
  local function llm_content(content, finish)
    return {choices = {{message = {role = "assistant", content = content}, finish_reason = finish or "stop"}}}
  end

  next_llm = {
    llm_tool_calls({{id = "call_1", type = "function",
      ["function"] = {name = "read_file", arguments = encode({path = big_path})}}}),
    llm_content("done"),
  }
  llm_idx = 0
  local msgs = {}
  local res = agent_test.process_exchange(msgs,
    {model = "m", api_key = "", api_url = "https://example.test/chat/completions",
     context_window = 128000}, "测试", false)
  next_llm = nil
  internet.request = orig_request

  local tool_content = nil
  for _, m in ipairs(msgs) do
    if m.role == "tool" and tostring(m.content):find("truncated", 1, true) ~= nil then
      tool_content = m.content
    end
  end
  local got = tool_content ~= nil
  local head_ok = got and tool_content:find(head_sentinel, 1, true) ~= nil
  local tail_ok = got and tool_content:find(tail_sentinel, 1, true) ~= nil
  local marker_ok = got and tool_content:find("[truncated", 1, true) ~= nil
      and tool_content:find("head+tail", 1, true) ~= nil
  local hint_ok = got and tool_content:find("use read_file with offset/limit", 1, true) ~= nil
      and tool_content:find(big_path, 1, true) ~= nil
  local no_mojibake = (tool_content and not tool_content:find("\239\191\189")) or false
  check("utf8 head+tail kept", head_ok and tail_ok and marker_ok,
    "head=" .. tostring(head_ok) .. " tail=" .. tostring(tail_ok)
    .. " marker=" .. tostring(marker_ok)
    .. " got=" .. tostring(tool_content and tool_content:sub(1, 80) or "nil"))
  check("truncate continuation hint with path", hint_ok,
    tostring(tool_content and tool_content:sub(1, 200) or "nil"))
  check("truncate no replacement char", no_mojibake,
    tostring(tool_content and tool_content:sub(1, 120) or "nil"))
  check("truncate exchange returns answer", res and res.text == "done",
    tostring(res and res.text))
  os.remove(big_path)
end

-- ═══ 断言 2+3: read_file 默认帽（400 行/20KB）+ offset 续读 ═══
local rl_path = WR .. "/trunc_cap.txt"
do
  local rl = {}
  for i = 1, 450 do rl[i] = "caprow " .. i end
  local fw = io.open(rl_path, "w")
  fw:write(table.concat(rl, "\n"))
  fw:close()
  local rl_res = execute_tool("read_file", encode({path = rl_path}))
  local rl_cont = execute_tool("read_file",
    encode({path = rl_path, offset = 401, limit = 10}))
  check("read_file cap hint",
    type(rl_res) == "string" and rl_res:find("truncated: showing first 400 lines", 1, true) ~= nil
    and rl_res:find("use read_file with offset=401", 1, true) ~= nil,
    tostring(rl_res and rl_res:sub(-150)))
  check("read_file offset continues",
    type(rl_cont) == "string" and rl_cont:find("401. caprow 401", 1, true) ~= nil
    and rl_cont:find("410. caprow 410", 1, true) ~= nil,
    tostring(rl_cont and rl_cont:sub(1, 150)))
  os.remove(rl_path)
end

-- ═══ 断言 4+5: search_files 超长行 [line truncated] + 无乱码 ═══
local sf_path = WR .. "/trunc_long.txt"
do
  local long_line = string.rep("x", 80) .. string.rep("中", 60) .. string.rep("y", 100)
  local fw = io.open(sf_path, "w")
  fw:write("needle " .. long_line .. "\n")
  fw:write("other line\n")
  fw:close()
  local sf_res = execute_tool("search_files",
    encode({pattern = "needle", path = sf_path, max_line_length = 200}))
  check("search_files line mark",
    type(sf_res) == "string" and sf_res:find("[line truncated at 200]", 1, true) ~= nil,
    tostring(sf_res and sf_res:sub(1, 250)))
  check("search_files no replacement char",
    type(sf_res) == "string" and sf_res:find("needle ", 1, true) ~= nil
    and not sf_res:find("\239\191\189"),
    tostring(sf_res and sf_res:sub(1, 250)))
  os.remove(sf_path)
end

log("")
log("RESULT: " .. PASS .. " pass, " .. FAIL .. " fail")
