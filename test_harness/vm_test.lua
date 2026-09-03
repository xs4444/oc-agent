-- ══════════════════════════════════════════════════════
-- in-vm test runner: loads agent.lua, runs unit tests,
-- writes results to /mnt/test_result.txt
-- ══════════════════════════════════════════════════════

local results = {}
local function log(...)
  local parts = {}
  for i = 1, select("#", ...) do
    parts[i] = tostring(select(i, ...))
  end
  results[#results + 1] = table.concat(parts, " ")
end

log("=== OC Agent In-VM Test ===")
log("Lua version: " .. _VERSION)

-- Load agent.lua in test mode (skips main())
-- 挂载路径是 /mnt/<mount>/agent.lua（非 /mnt/agent.lua），用 base 参数定位
local base_dir = ({...})[1] or "/mnt"
local agent_path = base_dir .. "/agent.lua"
if not _G.fs or not _G.fs.exists then
  -- 保险: 遍历 /mnt 找含 agent.lua 的挂载（与 chat2_test.lua 同策略）
  local fs_ok, fs_mod = pcall(require, "filesystem")
  if fs_ok and fs_mod and fs_mod.exists then
    for item in fs_mod.list("/mnt") do
      local full = "/mnt/" .. item
      if fs_mod.exists(full .. "/agent.lua") then agent_path = full .. "/agent.lua" break end
    end
  end
end
_TEST_MODE = true
local ok, err = pcall(dofile, agent_path)
if not ok then
  log("AGENT LOAD FAILED: " .. tostring(err))
else
  log("agent.lua loaded OK")
end

-- Test JSON codec
-- 单文件 agent.lua 的 json 是模块化局部（全局 json 仅占位空表——旧版
-- 单文件时代全局 json 是真实模块，vm_test 直接依赖它已失效）。显式
-- require: 单文件构建内联注册 package.preload，可解析。
local ok_json_mod, json_mod = pcall(require, "agent.json")
if not ok_json_mod then
  log("WARN: require agent.json failed (" .. tostring(json_mod) .. ") — trying global fallback")
  json_mod = json  -- 全局占位（空表时后续测试会如实报 ENCODE FAIL）
end
local json = json_mod
log("--- JSON tests ---")
local function jt(label, val)
  local enc_ok, encoded = pcall(json.encode, val)
  if not enc_ok then
    log(label .. ": ENCODE FAIL " .. tostring(encoded))
    return
  end
  local dec_ok, decoded = pcall(json.decode, encoded)
  if not dec_ok then
    log(label .. ": DECODE FAIL " .. tostring(decoded) .. " (enc=" .. encoded .. ")")
    return
  end
  if type(val) == "table" then
    log(label .. ": OK (enc=" .. encoded .. ")")
  elseif val == decoded then
    log(label .. ": OK (enc=" .. encoded .. ")")
  else
    log(label .. ": MISMATCH (enc=" .. encoded .. ", dec=" .. tostring(decoded) .. ")")
  end
end

jt("null", nil)
jt("bool true", true)
jt("int", 42)
jt("float", 3.14)
jt("string", "hello")
jt("escapes", 'a\nb\t"c"\\d')
jt("array", {1,2,3})
jt("object", {key="value", num=42})
jt("nested", {a={b={c=1}}})

-- Test decode of API-style JSON
local dec_ok, msg = pcall(json.decode, '{"role":"user","content":"hi","n":1,"arr":[1,2],"flag":true}')
if dec_ok then
  log("decode api json: OK role=" .. msg.role .. " n=" .. tostring(msg.n) .. " arr1=" .. tostring(msg.arr[1]) .. " flag=" .. tostring(msg.flag))
else
  log("decode api json: FAIL " .. tostring(msg))
end

-- Test tool execution
log("--- Tool tests ---")
local function tt(label, name, args)
  local r = execute_tool(name, args)
  log(label .. ": " .. tostring(r))
end

tt("exec_lua math", "execute_lua", '{"code":"return 2+2"}')
tt("exec_lua io", "execute_lua", '{"code":"io.write(\\"hello from lua\\")"}')
tt("exec_lua err", "execute_lua", '{"code":"error(\\"boom\\")"}')
-- v0.3.124: component_list 工具已删，改用 shell `components` 命令观察组件
tt("comp_list", "shell_execute", '{"command":"components"}')
tt("comp_list filter", "shell_execute", '{"command":"components internet"}')
tt("unknown", "unknown_tool", '{}')

-- component list full check
local comp = require("component")
local cnt = 0
for addr, typ in comp.list() do
  cnt = cnt + 1
end
log("component count: " .. cnt)

-- filesystem check
local fs = require("filesystem")
log("fs.exists /mnt/agent.lua: " .. tostring(fs.exists("/mnt/agent.lua")))
log("fs.exists /bin/ls: " .. tostring(fs.exists("/bin/ls")))

-- Write results
-- 必须写到挂载盘根目录（base 参数，如 /mnt/34c），host 侧 find tmp_t 才能
-- 抓到；文件名遵循 harness 约定: <stem>_result.txt（result_file_name()）。
-- 旧版硬编码 /mnt/test_result.txt（根盘不可写）+ /home/（VM 内 TMP 盘，
-- 不映射 host tmp_t）→ host 永远找不到 → NO RESULT FILE。
local f = io.open(base_dir .. "/vm_test_result.txt", "w")
if f then
  f:write(table.concat(results, "\n") .. "\n")
  f:close()
  log("Results written to " .. base_dir .. "/vm_test_result.txt")
else
  log("ERROR: could not write " .. base_dir .. "/vm_test_result.txt")
  -- try /home
  local f2 = io.open("/home/vm_test_result.txt", "w")
  if f2 then
    f2:write(table.concat(results, "\n") .. "\n")
    f2:close()
    log("Results written to /home/vm_test_result.txt")
  end
end
