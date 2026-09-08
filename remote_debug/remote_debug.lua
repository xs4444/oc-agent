-- remote_debug.lua v5.1 — 纯文本协议 (避免 JSON 解析 bug)
-- 运行在目标设备上, 通过 modem 接收主控机的调试指令并返回结果
-- 协议格式 (纯文本, 用 | 分隔):
--   请求: op|param1|param2
--     ping        -> 回 pong
--     info        -> 回设备信息
--     exec|cmd    -> 执行命令, 回输出
--     read|path   -> 读文件, 回内容
--     write|path|escaped_content -> 写文件 (serialization + | 转义)
--     delete|path -> 删除文件 (v5.1 新增, 用于远程清理 /tmp)
--   回复: ok|data  或  err|message
-- 端口: 8001
-- 关键: modem_message 事件参数 (subagent.lua:162 真机验证):
--   sig[1]=事件名 sig[2]=本地 sig[3]=远程 sig[4]=端口 sig[5]=距离 sig[6]=数据
-- v5.1: exec 重定向路径 /tmp -> /home (避开 /tmp 目录文件数上限)

local component = require("component")
local event = require("event")

-- 找 modem
local modemAddr = nil
for addr, ctype in pairs(component.list()) do
  if ctype == "modem" then
    modemAddr = addr
    break
  end
end
if not modemAddr then
  print("ERROR: no modem found")
  os.exit(1)
end

local PORT = 8001
component.invoke(modemAddr, "open", PORT)
local isWireless = component.invoke(modemAddr, "isWireless")
print("Remote Debug v5.1: " .. (isWireless and "wireless" or "wired"))
print("Addr: " .. modemAddr)
print("Port " .. PORT .. " open: " .. tostring(component.invoke(modemAddr, "isOpen", PORT)))
print("Waiting for commands... (Ctrl+C to stop)")

-- 回复最大字节 (subagent FILE_REPLY_MAX 经验: 8192-512)
local REPLY_MAX = 7680

local function send_reply(sender, port, payload)
  local s = payload
  if #s > REPLY_MAX then
    s = s:sub(1, REPLY_MAX) .. "...[TRUNCATED]"
  end
  pcall(component.invoke, modemAddr, "send", sender, port, s)
end

-- 执行 shell 命令 (v5.1: 重定向到 /home 而非 /tmp, 避开 /tmp 文件数上限)
local function exec_cmd(cmd)
  local outpath = "/home/exec_out_" .. tostring(os.time()) .. "_" .. tostring(math.random(100000))
  local ok, result = pcall(function()
    local shell = require("shell")
    local ok2, err2 = shell.execute(cmd .. " > " .. outpath)
    if not ok2 then return "Error: " .. tostring(err2) end
    local f = io.open(outpath, "r")
    if not f then
      return "(no output)"
    end
    local content = f:read("*a")
    f:close()
    local fs = require("filesystem")
    pcall(fs.delete, outpath)
    return content
  end)
  if ok then
    return "ok|" .. result
  else
    return "err|" .. tostring(result)
  end
end

-- 读取文件
local function read_file(path)
  local f = io.open(path, "r")
  if not f then
    return "err|cannot open " .. path
  end
  local content = f:read("*a")
  f:close()
  return "ok|" .. content
end

-- 写入文件 (write 指令) — serialization + '|' 转义
-- 协议: write|path|escaped_content
--   发送端: enc = serialization.serialize(content)
--           enc = enc:gsub("\\", "\\\\"):gsub("|", "\\|")  -- 转义
--   接收端: 先还原转义 (| → \001, \\ → \, \001 → |), 再 unserialize
local function write_file(path, escaped)
  local serialization = require("serialization")
  local ok, content = pcall(function()
    local unesc = escaped:gsub("\\|", "\001"):gsub("\\\\", "\\"):gsub("\001", "|")
    return serialization.unserialize(unesc)
  end)
  if not ok or type(content) ~= "string" then
    return "err|decode failed: " .. tostring(content)
  end
  local f = io.open(path, "w")
  if not f then
    return "err|cannot open " .. path .. " for write"
  end
  f:write(content)
  f:close()
  return "ok|" .. #content .. " bytes written to " .. path
end

-- 删除文件 (v5.1 新增)
local function delete_file(path)
  local fs = require("filesystem")
  local ok, err = pcall(fs.delete, path)
  if ok then
    return "ok|deleted " .. path
  else
    return "err|cannot delete " .. path .. ": " .. tostring(err)
  end
end

-- 系统信息
local function get_info()
  local computer = require("computer")
  local comps = {}
  for addr, ctype in pairs(component.list()) do
    comps[#comps+1] = ctype
  end
  table.sort(comps)
  local info = "id=" .. tostring(computer.address())
    .. "|uptime=" .. string.format("%.1f", computer.uptime())
    .. "|freeMem=" .. tostring(computer.freeMemory())
    .. "|totalMem=" .. tostring(computer.totalMemory())
    .. "|components=" .. table.concat(comps, ",")
  return "ok|" .. info
end

-- 主循环
while true do
  local sig = {event.pull(0.5)}
  if sig[1] == "modem_message" then
    local sender = sig[3]
    local port = sig[4]
    local data = sig[6]
    if port == PORT and type(data) == "string" then
      -- 解析纯文本协议: op|param1|param2
      -- 关键: 只在未转义的 '|' 处分割 (转义形式为 '\|')
      local function split_unescaped(s)
        local parts, cur = {}, {}
        local i = 1
        while i <= #s do
          local ch = s:sub(i, i)
          if ch == "\\" and i < #s and s:sub(i+1, i+1) == "|" then
            -- 转义的 '|', 保留原样 (两个字符)
            cur[#cur+1] = ch
            cur[#cur+1] = s:sub(i+1, i+1)
            i = i + 2
          elseif ch == "|" then
            -- 未转义的 '|', 分隔符
            parts[#parts+1] = table.concat(cur)
            cur = {}
            i = i + 1
          else
            cur[#cur+1] = ch
            i = i + 1
          end
        end
        parts[#parts+1] = table.concat(cur)
        return parts
      end
      local parts = split_unescaped(data)
      local op = parts[1] or ""
      local reply
      if op == "ping" then
        reply = "ok|pong"
      elseif op == "info" then
        reply = get_info()
      elseif op == "exec" then
        reply = exec_cmd(parts[2] or "")
      elseif op == "read" then
        reply = read_file(parts[2] or "")
      elseif op == "write" then
        -- write|path|escaped_content — parts[3] 是转义后的 serialization
        reply = write_file(parts[2] or "", parts[3] or "")
      elseif op == "delete" then
        reply = delete_file(parts[2] or "")
      else
        reply = "err|unknown op: " .. op
      end
      send_reply(sender, port, reply)
      print("CMD [" .. op .. "] -> replied " .. #reply .. " bytes")
    end
  elseif sig[1] == "interrupted" then
    print("Interrupted, exiting")
    break
  end
end

