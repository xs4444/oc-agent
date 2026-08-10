-- update.lua — 一键更新 agent
-- 用法: lua update.lua
-- 行为:
--   1. 查询 jsDelivr data API 获取最新发布 tag（不可变 URL，避免 @master 缓存过期）
--   2. 显示当前版本 vs 最新版本
--   3. 用 @<tag> 下载最新 install.lua
--   4. 以 <tag> 为 REF、**实际安装目录**为 DEST_DIR 执行 install.lua
--      （其内部所有下载都用 @<tag> 不可变 URL）
-- 四盘场景（v0.3.63）: 不再假设 /home/agent——扫描各挂载盘的
-- agent/version.txt 定位实际安装目录（agent 盘可能在任何挂载上）。

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

-- 从 jsDelivr data API JSON 提取最新版本 tag（versions 数组里排前的 "version" 值）
local function latest_tag()
  local body = fetch(DATA_API)
  if not body then return nil end
  -- {"versions":[{"version":"0.2.0",...},...]}
  local ver = body:match('"versions"%s*:%s*%[%s*{%s*"version"%s*:%s*"([^"]+)"')
  if ver and ver ~= "" then return ver end
  return nil
end

-- 从 GitHub tags API 提取最新 tag（实时权威源；jsDelivr data API 索引
-- 滞后是已知问题——v0.3.19~29 连续多版 watch 未检出，必须双源检测）
local function github_tag()
  local body = fetch("https://api.github.com/repos/" .. REPO .. "/tags")
  if not body then return nil end
  -- [{"name":"v0.3.29","zipball_url":...},...] 第一个即最新（按时间倒序）
  return body:match('"name"%s*:%s*"([^"]+)"')
end

-- 定位实际安装目录 + 当前版本（四盘场景: 扫描各挂载盘的
-- agent/version.txt 与 /home/agent/version.txt；多个时取版本最新者）
-- 返回 {dir=安装目录(含 /agent 段), version=...} 或 nil
local function locate_install()
  local fs = require("filesystem")
  local candidates = {}
  local function probe(base)
    local full = base .. "/agent/version.txt"
    local f = io.open(full, "r")
    if f then
      local v = f:read("*a"):gsub("%s", "")
      f:close()
      if v ~= "" then candidates[#candidates + 1] = {dir = base .. "/agent", version = v} end
    end
  end
  probe("/home")
  local ok_m, iter = pcall(fs.mounts)
  if ok_m and type(iter) == "function" then
    for _, path in iter do
      if path ~= "/" and path ~= "/home" then
        probe(path)
      end
    end
  end
  if #candidates == 0 then return nil end
  -- 版本号比较（v0.3.62 > v0.3.61）取最新者
  local function parts(v)
    local t = {}
    for x in tostring(v):gmatch("%d+") do t[#t + 1] = tonumber(x) end
    return t
  end
  table.sort(candidates, function(a, b)
    local pa, pb = parts(a.version), parts(b.version)
    for i = 1, math.max(#pa, #pb) do
      local x, y = pa[i] or 0, pb[i] or 0
      if x ~= y then return x > y end
    end
    return false
  end)
  return candidates[1]
end

-- 读取本地已安装版本（定位实际安装目录后取其 version.txt）
local install_info = locate_install()
local INSTALL_DIR = install_info and install_info.dir or "/home/agent"
local function current_version()
  return install_info and install_info.version or "(未知)"
end

-- 确定目标 ref: 双源检测（GitHub tags API 实时权威，jsDelivr data API
-- 回退——jsDelivr 索引滞后是已知问题），两者都取最新，取较新者
local function pick_newer(a, b)
  if not a then return b end
  if not b then return a end
  -- 版本号比较: 数字段逐段比（v0.3.29 > v0.3.28）
  local function parts(v)
    local t = {}
    for x in tostring(v):gmatch("%d+") do t[#t + 1] = tonumber(x) end
    return t
  end
  local pa, pb = parts(a), parts(b)
  for i = 1, math.max(#pa, #pb) do
    local x, y = pa[i] or 0, pb[i] or 0
    if x ~= y then return x > y and a or b end
  end
  return a
end

local tag_gh = github_tag()
local tag_js = latest_tag()
local tag = pick_newer(tag_gh, tag_js)
local ref = tag or "master"

print("检查最新版本...")
print("  GitHub 源:  " .. tostring(tag_gh or "?"))
print("  jsDelivr 源: " .. tostring(tag_js or "?"))
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
print("  安装位置: " .. INSTALL_DIR)
print("  最新版本: " .. tostring(latest or "?"))

if latest and latest ~= "?" and cur == latest then
  print("已是最新版本，无需更新。")
  return
end
print("")

print("下载最新安装器...")
-- 双源: jsDelivr CDN 优先，GitHub raw 回退（jsDelivr 索引滞后时 GitHub 仍可达）
local code, code_err
for _, base in ipairs({
  BASE .. "@" .. ref,
  "https://raw.githubusercontent.com/" .. REPO .. "/" .. ref,
}) do
  local body = fetch(base .. "/install.lua")
  if body and #body >= 100 then
    code = body
    print("  来源: " .. base .. "/install.lua")
    break
  end
  code_err = code_err or tostring(#(body or ""))
end
if not code then
  print("安装器下载异常（" .. tostring(code_err) .. " 字节），请检查网络或稍后重试")
  return
end

local f = io.open("install.lua", "w")
f:write(code)
f:close()
print("安装器已更新（" .. #code .. " 字节），开始安装...")
print("")

-- 执行安装器，把 ref 与**实际安装目录**传给 install.lua——
-- （DEST_DIR=实际安装盘的 /agent 上级目录；四盘场景下 install 不会
-- 重新引导选盘或装错盘。locate_install 未找到时传 nil 走 install
-- 自身的引导式选盘）
local chunk = assert(loadfile("install.lua"))
chunk(INSTALL_DIR ~= "/home/agent" and INSTALL_DIR:match("^(.*)/agent$") or nil, ref)
