-- explorer_e2e_master.lua — explorer 文件代理端到端（master 侧）
-- 用法: lua /mnt/<mount>/explorer_e2e_master.lua /mnt/<mount>
-- 流程（v0.3.92 修复验证）:
--   1. 配置 agent（api_key/model/api_url）
--   2. subagent_discover 找到 sub 实例
--   3. 手动 subagent_call（不依赖 execute_tool 的 DEPS.file_serve——
--      _TEST_MODE 下 main() 未跑，DEPS.file_serve=nil，subagent_call 等待
--      期收到的 FILE_PORT 文件请求会被 on_other 静默丢弃 → 子代理 60s
--      超时。这里手动实现: open REPLY_PORT+FILE_PORT → 发请求 → 轮询
--      分流: REPLY_PORT 收回复 / FILE_PORT 调 handle_file_message 处理）
--   4. 断言: 回复含真实文件内容（不是空 / 不是错误串）
-- 结果写 master_result.txt（host 侧轮询）
local base = ({...})[1] or "/mnt"
local api_key = ({...})[2] or "free"
local model = ({...})[3] or "deepseek-v4-flash-free"
local api_url = ({...})[4] or "https://opencode.ai/zen/v1/chat/completions"

local out = base .. "/explorer_e2e_master_result.txt"
local f = io.open(out, "w")
local function log(s)
  if f then f:write(s .. "\n"); f:flush() end
  print(s)
end

package.path = base .. "/?.lua;" .. (package.path or "")
_TEST_MODE = true
-- agent.lua 在挂载根（/mnt/<mount>/agent.lua），不在 agent/ 子目录
local agent_path = base .. "/agent.lua"
if not _G.fs or not _G.fs.exists then
  local fs_ok, fs_mod = pcall(require, "filesystem")
  if fs_ok and fs_mod and fs_mod.exists then
    if not fs_mod.exists(agent_path) then
      for item in fs_mod.list("/mnt") do
        local full = "/mnt/" .. item
        if fs_mod.exists(full .. "/agent.lua") then agent_path = full .. "/agent.lua" break end
      end
    end
  end
end
local ok_load, load_err = pcall(dofile, agent_path)
if not ok_load then log("FATAL: agent.lua load: " .. tostring(load_err)); return end
log("agent.lua loaded from " .. agent_path)

local ok_comp, comp = pcall(require, "component")
local ok_ev, event = pcall(require, "event")
local ok_sub, sub_mod = pcall(require, "agent.subagent")
if not (ok_comp and ok_ev and ok_sub and comp.modem) then
  log("FATAL: component/event/agent.subagent missing")
  f:close()
  return
end
local modem = comp.modem
local FILE_PORT = sub_mod.FILE_PORT  -- 9092

-- 文件服务 exec 包装（与 init.lua FILE_EXEC 同语义）
local function fsrv_exec(name, args)
  local ok2, res = pcall(execute_tool, name, json.encode(args))
  if not ok2 then return false, tostring(res) end
  if type(res) == "string" and res:sub(1, 6) == "Error:" then return false, res end
  return true, res
end

-- 1) discover
log("--- discover ---")
local ok_d, d_res = pcall(execute_tool, "subagent_discover", "{}")
log("discover: " .. tostring(d_res))
if not ok_d or not tostring(d_res):find("found", 1, true) then
  log("FAIL: no subagent found")
  f:close()
  return
end
-- 解析子代理地址（完整 UUID 8-4-4-4-12）
local addr = tostring(d_res):match("(%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x)")
if not addr then log("FAIL: cannot parse address from: " .. tostring(d_res)); f:close(); return end
log("subagent address: " .. addr)

-- 2) explorer call（手动实现，含等待期文件服务分流）
log("--- explorer call ---")
local task = "List the / root directory (first 20 entries). Then read file /mnt/"
  .. tostring(base:match("/mnt/(%w+)")) .. "/init.lua first 10 lines."
local REPLY_PORT = 9091
local request = json.encode({v = 1, id = string.format("%x", os.time()),
  role = "explorer", task = task, session = "", context = ""})
log("request: " .. request:sub(1, 200))

local ok_open_r = pcall(modem.open, REPLY_PORT)
local ok_open_f = pcall(modem.open, FILE_PORT)
log("open reply port: " .. tostring(ok_open_r) .. " file port: " .. tostring(ok_open_f))

-- 发请求到 sub 的监听端口 9090
local ok_send = pcall(modem.send, addr, 9090, request)
log("send to " .. addr .. ": " .. tostring(ok_send))
if not ok_send then log("FAIL: modem.send failed"); f:close(); return end

-- 等待回复（最长 120s），期间分流处理文件请求
local timeout = 120
local deadline = os.time() + timeout
local reply = nil
local file_calls = 0
local file_ok = 0
while os.time() < deadline do
  local sig = {event.pull(0.5)}
  if sig[1] == "modem_message" then
    local sender = sig[3]
    local port = sig[4]
    local payload = sig[6]
    if port == REPLY_PORT then
      reply = payload
      log("got reply from " .. tostring(sender))
      break
    elseif port == FILE_PORT then
      file_calls = file_calls + 1
      local ok_h = pcall(sub_mod.handle_file_message, fsrv_exec, sender, port, payload)
      if ok_h then file_ok = file_ok + 1 end
    end
  elseif sig[1] == "interrupted" then
    log("interrupted during wait")
    break
  end
end
pcall(modem.close, REPLY_PORT)
pcall(modem.close, FILE_PORT)

local dt = os.time() - (deadline - timeout)
log("call finished after ~" .. tostring(dt) .. "s (file requests served: " .. file_calls .. ", ok: " .. file_ok .. ")")
log("reply: " .. tostring(reply))

-- 3) 断言
local res_str = tostring(reply or "")
local ok_json_reply, decoded = pcall(json.decode, res_str)
local content = ""
if ok_json_reply and type(decoded) == "table" then
  if decoded.ok then
    content = tostring(decoded.result or "")
  else
    content = "subagent error: " .. tostring(decoded.error or "unknown")
  end
else
  content = res_str
end
log("content: " .. content:sub(1, 400))

local has_content = content:find("etc/", 1, true) ~= nil or content:find("home/", 1, true)
  or content:find("mnt/", 1, true) or content:find("init.lua", 1, true)
  or content:find("bin/", 1, true) or content:find("usr/", 1, true)
local has_error = content:find("Error", 1, true) ~= nil or content:find("timeout", 1, true)
  or content:find("no reply", 1, true)
if file_calls > 0 and file_ok > 0 and has_content and not has_error then
  log("PASS: explorer file proxy returned real content (file requests served: " .. file_calls .. ")")
elseif file_calls == 0 then
  log("FAIL: no file requests received from subagent — proxy link broken")
elseif has_error then
  log("FAIL: explorer reply has error marker: " .. content:sub(1, 200))
else
  log("FAIL: no content and no error — empty result: " .. content:sub(1, 200))
end
log("--- done ---")
f:close()
