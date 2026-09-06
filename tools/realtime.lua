-- realtime: 真实墙钟（OC 的 `date`/`os.date` 默认参数是 Minecraft 游戏钟，
-- 1976 年那种；本命令经 timeapi.io 取宿主侧真实时间）。
-- 部署：真机 /home/bin/realtime.lua（PATH 默认含 /home/bin，见
-- opencomputers loot boot/02_os.lua:33）。用法：realtime [-u]
-- 依赖：出口网络可达 timeapi.io（https，真机 Java TLS 实证可用；
-- Cloudflare 系端点 worldtimeapi/httpbin 被服务器出口封禁）。
local shell = require("shell")
local internet = require("internet")
local args, options = shell.parse(...)

local utc = options.u -- OpenOS shell 把 -u 解析成短选项（options.u），不是位置参数
local tz = utc and "UTC" or "Asia/Shanghai"
local label = utc and "UTC" or "CST (UTC+8)"

local ok, err = pcall(function()
  local url = "https://timeapi.io/api/time/current/zone?timeZone=" .. tz
  local chunks = {}
  for chunk in internet.request(url) do
    chunks[#chunks + 1] = chunk
    os.sleep(0.01)
  end
  local body = table.concat(chunks)
  -- timeapi.io 返回 {"year":2026,"month":9,...} ——逐字段独立匹配，抗格式变化
  local y = body:match('"year":(%d+)')
  local mo = body:match('"month":(%d+)')
  local d = body:match('"day":(%d+)')
  local h = body:match('"hour":(%d+)')
  local mi = body:match('"minute":(%d+)')
  local s = body:match('"seconds":(%d+)')
  if not (y and mo and d and h and mi and s) then
    io.stderr:write("realtime: timeapi parse failed: " .. body:sub(1, 120) .. "\n")
    os.exit(1)
  end
  -- 关键：用 io.stdout:write 而非 print()——print 写 io.output()（机器 TTY，
  -- 会泄漏到游戏内屏幕），io.stdout 才是 popen 管道（远控捕获通道）
  io.stdout:write(('%04d-%02d-%02d %02d:%02d:%02d %s\n'):format(
    tonumber(y), tonumber(mo), tonumber(d), tonumber(h), tonumber(mi), tonumber(s), label))
end)

if not ok then
  io.stderr:write("realtime: " .. tostring(err) .. "\n")
  os.exit(1)
end
