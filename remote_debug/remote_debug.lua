-- remote_debug.lua v5.2.2 — 纯文本协议 (避免 JSON 解析 bug)
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
-- v5.2: 回复消歧 (治"信息困惑导致重复循环", 见 agent_history_162903596.4
--   尾部 doom-loop: 主控侧 LLM 把远端 /home 路径当本机 ls + 空载荷 ok| 无法
--   区分"成功但无数据"与故障, 同命令重复 3 轮触发护栏):
--   - 空载荷永不出现: exec 无输出 -> "ok|(no output)"; read 空文件 ->
--     "ok|(empty file)"。主控侧拿到 ok| 即保证 data 非空。
--   - exec 失败走 err 信封 (旧版 shell.execute 失败回 "ok|Error: nil" ——
--     错误语义走 ok 通道, 主控侧无法区分): "err|exec failed: <err>" /
--     "err|exec redirect failed: cannot open <outpath>"。
--   - write/delete 回复加 "remote: " 前缀, 明确文件在远端设备 (旧版
--     "ok|N bytes written to /home/x.lua" 被主控侧 LLM 当本机路径 ls,
--     必然 No such file or directory -> 困惑循环)。
--   - exec 追加 "2>&1" 捕获 stderr —— 脚本崩溃信息此前被吞 (只重定向
--     stdout), 主控侧只能看到 "EXEC: ok|" 空载荷, 永远不知道远端脚本
--     为什么没产出数据。
-- v5.2.1: exec 命令体取第一个 '|' 之后的原文 —— 旧版 split_unescaped
--   重切后只取 parts[2], 命令含 shell 管道 '|' 时第一个 '|' 之后的内容
--   静默丢失 (ls | grep x → 只跑 ls)。read/write/delete 不受影响。
-- v5.2.2: exec 失败时附上已捕获的输出 —— 旧版失败只回 "exec failed: nil",
--   2>&1 已捕获的 stderr (ls 报错/脚本崩溃行) 被丢弃。对照 ssh: 流数据
--   先于 exit-status 帧到达 (session.c:2344)。

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
print("Remote Debug v5.2.2: " .. (isWireless and "wireless" or "wired"))
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
-- v5.2: 失败走 err 信封 (旧版 shell.execute 失败回 "ok|Error: nil" —— 错误
--   语义走 ok 通道, 主控侧 LLM 无法区分"成功无输出"与"执行失败");
--   空输出显式标记 "(no output)" (旧版 "ok|" 空载荷同样歧义);
--   追加 "2>&1" 捕获 stderr (关键: 脚本崩溃信息走 stderr, 旧版只重定向
--   stdout 把崩溃吞掉 → "EXEC: ok|" 空载荷, 主控侧永远看不到探针为什么没
--   数据。实证: agent_history_162903596.4 的 probe_env 脚本用 pairs(comp)
--   迭代 component 表 (返回 22 个 方法名=function, 而非 地址=类型) →
--   table.sort 比较 function 崩溃 → io.open("w") 已创建空文件但首行 w()
--   未执行 → 每轮都留下空 /home/probe_out.txt → 主控侧 10 轮困惑循环)。
local function exec_cmd(cmd)
  local outpath = "/home/exec_out_" .. tostring(os.time()) .. "_" .. tostring(math.random(100000))
  local ok, result = pcall(function()
    local shell = require("shell")
    local ok2, err2 = shell.execute(cmd .. " > " .. outpath .. " 2>&1")
    if not ok2 then
      error("exec failed: " .. tostring(err2))
    end
    local f = io.open(outpath, "r")
    local content = f and f:read("*a") or ""
    if f then f:close() end
    local fs = require("filesystem")
    pcall(fs.remove or fs.delete, outpath)  -- 新版 OpenOS 是 fs.remove (旧版 fs.delete)
    if not ok2 then
      -- v5.2.2: 失败时附上已捕获的输出 (对照 ssh: 流数据先于 exit-status
      -- 帧到达, session.c:2344 —— 旧版只回 "exec failed: nil", 已捕获的
      -- stderr (ls 报错/脚本崩溃行) 被丢弃, 主控侧仍看不到失败原因。
      -- 实测: T2_EXEC_FAIL ls 不存在的目录 → "exec failed: nil")
      error("exec failed: " .. tostring(err2)
        .. (content ~= "" and (" | output: " .. content) or ""))
    end
    if not f then
      -- 命令成功但重定向文件打不开 (如目录文件数上限) —— 与"命令无输出"区分
      error("exec redirect failed: cannot open " .. outpath)
    end
    if #content == 0 then
      return "(no output)"
    end
    return content
  end)
  if ok then
    return "ok|" .. result
  else
    return "err|" .. tostring(result)
  end
end

-- 读取文件 (v5.2: 空文件显式标记 "(empty file)" —— 旧版 "ok|" 空载荷,
-- 主控侧无法区分"文件存在但为空"与其他异常; 文件不存在仍回 err 信封)
local function read_file(path)
  local f = io.open(path, "r")
  if not f then
    return "err|cannot open " .. path
  end
  local content = f:read("*a")
  f:close()
  if #content == 0 then
    return "ok|(empty file)"
  end
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
  -- v5.2: "remote: " 前缀 —— 文件在远端设备, 明确提示主控侧 LLM 勿对本机 ls
  return "ok|remote: " .. #content .. " bytes written to " .. path
end

-- 删除文件 (v5.1 新增; v5.2: "remote: " 前缀同 write)
-- 注意: 新版 OpenOS 的删除函数是 filesystem.remove (旧版叫 delete) ——
-- 用 or 兜底跨版本。首次部署后真机 delete op 报 "attempt to call a nil
-- value" 即此因 (OpenOS 1.8.9, full_filesystem.lua:241 filesystem.remove)。
local function delete_file(path)
  local fs = require("filesystem")
  local del = fs.remove or fs.delete
  local ok, err = pcall(del, path)
  if ok then
    return "ok|remote: deleted " .. path
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
        -- v5.2.1: 命令体取第一个 '|' 之后的原文 (不再用 split_unescaped 重切):
        -- 命令含 shell 管道 '|' 时旧版只取 parts[2] → 第一个 '|' 后的内容静默
        -- 丢失。第一个 '|' 必为分隔符 (客户端恒以 "exec|" 前缀发送)。
        local raw = data:sub(6)  -- 剥掉 "exec|" (5 字符)
        reply = exec_cmd(raw or "")
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

