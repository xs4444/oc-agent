-- update.lua — 一键更新 agent
-- 用法: lua update.lua [ref]
--   ref 可选: 指定版本（如 v0.3.69）——**推荐**（jsDelivr data API 索引
--   滞后 + GitHub 不可达时自动检测拿不到最新，手动指定最可靠）
-- 行为:
--   1. 有 ref 参数 → 直接用（跳过网络检测）
--   2. 无参数 → 查询 jsDelivr data API 获取最新 tag（GitHub tags API
--      作为回退，但 GitHub 不可达时该路失败）
--   3. 显示当前版本 vs 目标版本
--   4. 用 @<tag> 下载最新 install.lua（不可变 URL，避免 @master 缓存过期）
--   5. 以 <tag> 为 REF、**实际安装目录**为 DEST_DIR 执行 install.lua
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

-- 确定目标 ref: 手动参数优先（2026-08-10: data API 索引滞后到 0.3.66、
-- GitHub 不可达时自动检测拿不到 v0.3.69——用户实测 update 装不到最新；
-- `update v0.3.69` 直接锁定目标，最可靠）。无参数时 jsDelivr data API
-- 优先（国内可达），仅当 jsDelivr 失败时回退 GitHub tags API。
print("检查最新版本...")
local ref_arg = select(1, ...)
local ref
if ref_arg and ref_arg ~= "" then
  ref = ref_arg
  print("  手动指定: " .. ref)
else
  local tag_js = latest_tag()
  print("  jsDelivr 源: " .. tostring(tag_js or "?"))
  local tag = tag_js
  if not tag_js then
    print("  (jsDelivr 无结果，尝试 GitHub 源...)")
    local tag_gh = github_tag()
    print("  GitHub 源: " .. tostring(tag_gh or "?"))
    tag = tag_gh
  end
  if not tag then
    print("  ⚠️  无法自动获取最新版本（网络受限）。")
    print("  用法: lua update.lua <ref>   例如: lua update.lua v0.3.69")
    return
  end
  ref = tag
end
print("  ref: " .. ref)

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

-- 反向更新守卫（2026-08-10 用户实测: jsDelivr data API 索引滞后返回
-- 0.3.66，把已装 v0.3.69（T2002）降级到 T1733——update 无版本比较就
-- 执行）。latest 与 cur 均为 files.json 的 version（ISO 时间戳
-- YYYY-MM-DDTHHMM，字典序 = 时间序），直接字符串比较即可。
-- 触发时中止并提示手动 ref（自动检测不可信——GitHub 不可达 + data
-- API 滞后，唯一可靠路径是 lua update.lua <ref>）。
if latest and latest ~= "?" and cur and cur ~= "(未知)" and cur ~= "?" then
  if latest < cur then
    print("")
    print("  ⚠️  检测到的版本 " .. latest .. " 不新于当前 " .. cur)
    print("  （jsDelivr 索引滞后——自动检测不可信）")
    print("  已中止，避免反向更新。请手动指定版本:")
    print("  lua update.lua <ref>   例如: lua update.lua v0.3.70")
    return
  end
end

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

-- install.lua 落点 = 与 update.lua 同目录（PATH 启动器下 cwd 不固定，
-- 不能写相对 "install.lua"——2026-08-10 用户实测：update 不在 PATH、
-- 且 cwd 任意时脚本会装错位置）。
local script_dir = arg and arg[0] and arg[0]:match("^(.*)[/\\][^/\\]+$") or "."
local f = io.open(script_dir .. "/install.lua", "w")
f:write(code)
f:close()
print("安装器已更新（" .. #code .. " 字节），开始安装...")
print("")

-- 执行安装器，把 ref 与**实际安装目录**传给 install.lua——
-- （DEST_DIR=实际安装盘的 /agent 上级目录；四盘场景下 install 不会
-- 重新引导选盘或装错盘。locate_install 未找到时传 nil 走 install
-- 自身的引导式选盘）
local install_script = script_dir .. "/install.lua"
local chunk = assert(loadfile(install_script))
chunk(INSTALL_DIR ~= "/home/agent" and INSTALL_DIR:match("^(.*)/agent$") or nil, ref)
