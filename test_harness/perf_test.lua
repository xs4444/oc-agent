-- perf_test.lua — 工具调用性能监测（对比新旧版本用）
--
-- 用法（本地）:
--   lua.exe -e "package.path = './?.lua;../src/?.lua;' .. (package.path or '')" perf_test.lua ../agent.lua
--   lua.exe -e "package.path = './?.lua;'" perf_test.lua ../old_agent.lua
-- 用法（ocvm）:
--   lua /mnt/<x>/perf_test.lua /mnt/<x> [循环次数]
--
-- 测量: 无网络依赖工具（json_query/calc/text_ops/read_file/write_file/
-- list_directory）循环 N 次总耗时 + 每轮内存。结果写入
-- <base>/perf_result.txt。

local base = ({...})[1] or "."
local N = tonumber(({...})[2]) or 200

-- 本地测试环境注入 oc_mock（ocvm/真实 OpenOS 下 require 不到则跳过）
local mock_ok, oc_mock = pcall(require, "oc_mock")
if mock_ok and type(oc_mock) == "table" then
  package.loaded["component"] = oc_mock.component
  package.loaded["computer"] = oc_mock.computer
  package.loaded["filesystem"] = oc_mock.filesystem
  package.loaded["shell"] = oc_mock.shell
  package.loaded["internet"] = oc_mock.internet
  package.loaded["serialization"] = oc_mock.serialization
  package.loaded["event"] = oc_mock.event
end

local computer
local now
do
  local ok_c, m = pcall(require, "computer")
  if ok_c and type(m) == "table" and type(m.uptime) == "function" then
    computer = m
    -- 本地 mock 的 uptime 是固定值（不随时间走），用 os.clock 计真实时间；
    -- ocvm/OpenOS 的 uptime 真实递增，直接用
    if mock_ok then
      now = os.clock
    else
      now = computer.uptime
    end
  else
    computer = { uptime = os.clock, freeMemory = function() return -1 end }
    now = os.clock
  end
end

-- 加载 agent（参数 1 是 agent.lua 路径，或挂载 base 下的 agent.lua）
local agent_path
local result_path
if base:match("%.lua$") then
  agent_path = base
  local dir = base:match("^(.*)[/\\][^/\\]+$") or "."
  result_path = dir .. "/perf_result.txt"
else
  agent_path = base .. "/agent.lua"
  result_path = base .. "/perf_result.txt"
end
local rf = io.open(result_path, "w")
if rf then rf:close() end

local function log(...)
  print(...)
  local f = io.open(result_path, "a")
  if f then f:write(table.concat({...}, " ") .. "\n"); f:close() end
end

_TEST_MODE = true
local ok, err = pcall(dofile, agent_path)
if not ok then
  log("LOAD FAILED: " .. tostring(err))
  os.exit(1)
end

log("=== perf test ===")
log("agent: " .. agent_path)
log("iterations: " .. N)
log("freeMemory start: " .. computer.freeMemory())

local function bench(name, fn, iters)
  iters = iters or N
  local t0 = now()
  for _ = 1, iters do
    local r = fn()
    if r == nil or r == "" then
      log("WARN " .. name .. " returned empty at iter")
      break
    end
  end
  local t1 = now()
  log(string.format("%-16s %d iters in %.3fs (%.4f s/iter)",
    name, iters, t1 - t0, (t1 - t0) / iters))
end

local p = "/tmp/perf_write.txt"
local big = string.rep("x", 200)

bench("json_query", function()
  return execute_tool("json_query", '{"json":"{\\"a\\":{\\"b\\":[1,2,3]}}","path":"a.b.2"}')
end)
bench("calc", function()
  return execute_tool("calc", '{"expr":"(1+2)*3-4/2"}')
end)
bench("text_ops", function()
  return execute_tool("text_ops", '{"op":"upper","text":"hello world"}')
end)
bench("write_file", function()
  return execute_tool("write_file", '{"path":"' .. p .. '","content":"' .. big .. '"}')
end)
bench("read_file", function()
  return execute_tool("read_file", '{"path":"' .. p .. '"}')
end)
bench("list_directory", function()
  return execute_tool("list_directory", '{"path":"/tmp"}')
end)
bench("edit_file", function()
  return execute_tool("edit_file", '{"path":"' .. p .. '","old_string":"xxx","new_string":"yyy","replace_all":true}')
end)

log("freeMemory end: " .. computer.freeMemory())
log("=== perf done ===")
