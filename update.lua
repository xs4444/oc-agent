-- update.lua — 一键更新 agent
-- 用法: lua update.lua
-- 行为:
--   1. 查询 jsDelivr data API 获取最新发布 tag（不可变 URL，避免 @master 缓存过期）
--   2. 显示当前版本 vs 最新版本
--   3. 用 @<tag> 下载最新 install.lua
--   4. 以 <tag> 为 REF 执行 install.lua（其内部所有下载都用 @<tag> 不可变 URL）

local internet = require("internet")

local REPO = "xs4444/oc-agent"
local DATA_API = "https://data.jsdelivr.com/v1/packages/gh/" .. REPO
local BASE = "https://cdn.jsdelivr.net/gh/" .. REPO

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

-- 从 data API JSON 提取最新版本 tag（versions 数组里排前的 "version" 值）
local function latest_tag()
  local body = fetch(DATA_API)
  if not body then return nil end
  -- {"versions":[{"version":"0.2.0",...},...]}
  local ver = body:match('"versions"%s*:%s*%[%s*{%s*"version"%s*:%s*"([^"]+)"')
  if ver and ver ~= "" then return ver end
  return nil
end

-- 读取本地已安装版本（agent 安装目录下的 version.txt，由 install.lua 写入）
local function current_version()
  local f = io.open("/home/agent/version.txt", "r")
  if f then
    local v = f:read("*a"):gsub("%s", "")
    f:close()
    if v ~= "" then return v end
  end
  return "(未知)"
end

-- 确定目标 ref: 优先最新 tag，查不到则回退 @master
local tag = latest_tag()
local ref = tag or "master"

print("检查最新版本...")
print("  ref: " .. (tag and ("@" .. tag .. " (tag)") or "@master (回退)"))

local latest
do
  local manifest_body = fetch(BASE .. "@" .. ref .. "/files.json")
  if manifest_body then
    latest = manifest_body:match('"version"%s*:%s*"([^"]+)"') or "?"
  end
end
local cur = current_version()
print("  当前版本: " .. cur)
print("  最新版本: " .. tostring(latest or "?"))

if latest and latest ~= "?" and cur == latest then
  print("已是最新版本，无需更新。")
  return
end
print("")

print("下载最新安装器...")
local code = fetch(BASE .. "@" .. ref .. "/install.lua")
if not code or #code < 100 then
  print("安装器下载异常（" .. tostring(#(code or "")) .. " 字节），可能是 CDN 缓存延迟")
  return
end

local f = io.open("install.lua", "w")
f:write(code)
f:close()
print("安装器已更新（" .. #code .. " 字节），开始安装...")
print("")

-- 执行安装器，把 ref 传给 install.lua（DEST_DIR=nil 自动检测，REF=ref）
local chunk = assert(loadfile("install.lua"))
chunk(nil, ref)
