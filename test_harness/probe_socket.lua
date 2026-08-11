-- probe_socket.lua — 探测 OC internet.socket 异步 API 行为
-- 用法: lua /mnt/<short>/probe_socket.lua /mnt/<short> <api_key> <model> <api_url>
-- 目的: 评估用 socket 轮询式读取替代同步迭代器（迭代器等待期 Lua 事件
-- 停摆, Ctrl+C 中断无效——v0.3.86 补丁在等待期跑不到）。若 socket 的
-- finishConnect/read 支持 timeout 且期间事件活性, 则可改造。
local base = ({...})[1] or "/mnt"
local api_key = ({...})[2] or "free"
local model = ({...})[3] or "deepseek-v4-flash-free"
local api_url = ({...})[4] or "https://opencode.ai/zen/v1/chat/completions"

local out = base .. "/probe_socket_result.txt"
local f = io.open(out, "w")
local function log(s)
  if f then f:write(s .. "\n"); f:flush() end
  print(s)
end

local ok_i, internet = pcall(require, "internet")
if not ok_i then log("FATAL: no internet lib"); return end
log("internet.socket exists: " .. tostring(internet.socket ~= nil))
if not internet.socket then
  log("internet.request exists: " .. tostring(internet.request ~= nil))
  log("probe done (no socket API)")
  return
end

-- 1) socket 建立连接（异步）
-- 注意: OpenOS internet.socket() 只接受 host:port（machine.lua 的
-- "address could not be parsed or no valid port given"），不接受完整 URL。
-- 解析 api_url → host:port + path。
local s_addr, s_path, s_host = api_url, "/", api_url
do
  local proto, rest = api_url:match("^(%w+)://(.*)$")
  if rest then
    s_path = rest:match("^[^/]*(/.*)$") or "/"
    local h, p = rest:match("^([^:/]+):(%d+)")
    if h then
      s_host, s_addr = h, h .. ":" .. p
    else
      s_host = rest:match("^([^/]+)")
      s_addr = (s_host or "") .. ":" .. ((proto == "https") and "443" or "80")
    end
  else
    -- 已是 host:port 形式
    local h, p = api_url:match("^([^:]+):(%d+)$")
    if h then
      s_host, s_addr = h, api_url
    else
      s_host, s_addr = api_url, api_url .. ":443"
    end
  end
end
local ok_s, sock = pcall(internet.socket, s_addr)
log("socket(" .. s_addr .. ") ok=" .. tostring(ok_s) .. " sock=" .. tostring(sock and type(sock)))
if not ok_s or not sock then
  log("socket error: " .. tostring(sock))
  log("probe done")
  return
end

-- 2) 连接建立异步性: 底层 C++ InternetConnection 有 finishConnect（轮询
--    连接状态）+ internet_ready 信号。OpenOS 包装层 socketStream 只暴露
--    close/seek/read/write——finishConnect 需经 sock.socket 底层 userdata。
local ok_ev, event = pcall(require, "event")
local raw = sock.socket  -- 底层 connection userdata
log("raw socket userdata: " .. tostring(raw ~= nil) .. " (" .. tostring(raw and type(raw)) .. ")")
-- 方法调用必须显式传 self（Lua 冒号语法展开为 sock.read(sock, ...)；
-- 点号调用会把第一个实参当 self，导致 self 为 number/string/nil 报错）
local ok_fc, fc_res
if raw then
  ok_fc, fc_res = pcall(raw.finishConnect, raw, 10)
  log("finishConnect(10) ok=" .. tostring(ok_fc) .. " res=" .. tostring(fc_res))
else
  ok_fc, fc_res = false, "no raw socket"
  log("finishConnect(10) skipped — no raw socket")
end
if not ok_fc then
  log("finishConnect failed: " .. tostring(fc_res))
end

-- 3) write POST 请求
local body = "{\"model\":\"" .. model .. "\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":8}"
local headers = "Content-Type: application/json\r\n"
if api_key ~= "" and api_key ~= "free" then
  headers = headers .. "Authorization: Bearer " .. api_key .. "\r\n"
end
local ok_w, w_res = pcall(sock.write, sock, "POST " .. s_path .. " HTTP/1.1\r\nHost: " .. s_host .. "\r\n" .. headers .. "Content-Length: " .. #body .. "\r\nConnection: close\r\n\r\n" .. body)
log("write ok=" .. tostring(ok_w) .. " res=" .. tostring(w_res))

-- 4) read(n, timeout): 非阻塞轮询式（C++ 实现: 设 _needs_data 后立即
--    返回当前 bytes_available()，空 buffer 也不阻塞）。超时参数被忽略。
local ok_r, r_res = pcall(sock.read, sock, 4096, 5)
log("read(4096,5) ok=" .. tostring(ok_r) .. " len=" .. tostring(r_res and #r_res or 0))
if not ok_r then
  log("read error: " .. tostring(r_res))
elseif r_res and #r_res > 0 then
  log("read head: " .. tostring(r_res):sub(1, 200))
end

-- 5) 等待期事件活性: 轮询读取循环中能否 event.pull 到事件（Ctrl+C 中断
--    依赖此活性）。read 非阻塞立即返回，循环用 os.sleep(0) 让出事件循环。
local deadline = os.clock() + 12
local events_seen = 0
local ready_seen = false
local total_got = 0
if ok_ev then
  while os.clock() < deadline do
    local ev = event.pull(0)
    if ev then
      events_seen = events_seen + 1
      if ev[1] == "internet_ready" then ready_seen = true end
    end
    local ok_r2, r2 = pcall(sock.read, sock, 4096)
    if ok_r2 and r2 and #r2 > 0 then
      total_got = total_got + #r2
    elseif ok_r2 and r2 == nil then
      log("read returned nil (EOF/closed) at t=" .. string.format("%.1f", os.clock()))
      break
    end
    os.sleep(0)
  end
end
log("poll loop: events_seen=" .. events_seen .. " internet_ready=" .. tostring(ready_seen) .. " bytes=" .. total_got)

local ok_c, c_res = pcall(sock.close, sock)
log("close ok=" .. tostring(ok_c) .. " res=" .. tostring(c_res))
log("probe done")
