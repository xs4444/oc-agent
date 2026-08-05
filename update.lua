-- update.lua — 一键更新 agent（永不需要更新此文件）
-- 用法: lua update.lua
-- 行为: 检查最新版本 → 显示当前 vs 最新 → 下载最新 install.lua 并自动执行

local internet = require("internet")

local BASE = "https://cdn.jsdelivr.net/gh/xs4444/oc-agent@master"

local function fetch(url)
  local ok, handle = pcall(internet.request, url)
  if not ok or not handle then return nil end
  local chunks = {}
  for chunk in handle do
    chunks[#chunks + 1] = chunk
    os.sleep(0.02)
  end
  return table.concat(chunks)
end

-- 读取本地已安装版本（agent 安装目录下的 version.txt，由 install.lua 写入）
local function current_version()
  local base = "/home/agent"
  local f = io.open(base .. "/version.txt", "r")
  if f then
    local v = f:read("*a"):gsub("%s", "")
    f:close()
    if v ~= "" then return v end
  end
  -- 回退: 检查 config 里是否记录过
  return "(未知)"
end

print("检查最新版本...")
local manifest_body = fetch(BASE .. "/files.json")
if not manifest_body then
  print("无法获取版本信息，请检查网络")
  return
end
local latest = manifest_body:match('"version"%s*:%s*"([^"]+)"') or "?"

local cur = current_version()
print("  当前版本: " .. cur)
print("  最新版本: " .. latest)

if latest ~= "?" and cur == latest then
  print("已是最新版本，无需更新。")
  return
end
print("")

print("下载最新安装器...")
local code = fetch(BASE .. "/install.lua")
if not code or #code < 100 then
  print("安装器下载异常（" .. tostring(#(code or "")) .. " 字节），可能是 CDN 缓存延迟")
  return
end

local f = io.open("install.lua", "w")
f:write(code)
f:close()
print("安装器已更新（" .. #code .. " 字节），开始安装...")
print("")

-- 执行下载的安装器
dofile("install.lua")
