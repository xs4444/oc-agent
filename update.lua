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

-- 超时常量（v0.3.93 双源+超时）:
-- OC internet.request 连接阶段无超时（v0.3.73 /debug 卡死教训: 连接
-- 挂起时 Lua 层不运行）——单源整体用 thread + waitForAll 兜底，迭代
-- 阶段用 deadline 双保险。检测阶段两源并行，最坏耗时 ~FETCH_TIMEOUT。
local FETCH_TIMEOUT = 15   -- 单源整体超时（连接+读取）
local READ_DEADLINE = 20   -- 迭代阶段 deadline（秒，兜底线程不可用时）

local function fetch(url)
  local ok, handle = pcall(internet.request, url)
  if not ok or not handle then return nil end
  local chunks = {}
  local deadline = os.clock() + READ_DEADLINE
  for chunk in handle do
    chunks[#chunks + 1] = chunk
    os.sleep(0.02)
    -- 迭代超时（响应流永不结束保护——挂起时提前放弃）
    if os.clock() > deadline then return nil end
  end
  return table.concat(chunks)
end

-- 线程包装: 连接阶段挂起（internet.request 无超时）用 thread +
-- waitForAll 兜底——超时放弃该线程（后台继续，不影响主流程; 结果
-- 由 http 层迭代 deadline 最终兜底）。thread 不可用时回退同步
-- （迭代 deadline 仍生效）。
local function fetch_timeout(url)
  local ok_th, thread = pcall(require, "thread")
  if not ok_th or not thread or not thread.create or not thread.waitForAll then
    return fetch(url)
  end
  local result = {}
  local t = thread.create(function()
    result.body = fetch(url)
  end)
  local ok_w, werr = pcall(thread.waitForAll, {t}, FETCH_TIMEOUT)
  if not ok_w or not werr then
    -- 超时: 放弃（线程后台继续, 连接最终由响应超时兜底）
    return nil
  end
  return result.body
end

-- 从 jsDelivr data API JSON 提取最新版本 tag（versions 数组里排前的 "version" 值）
local function latest_tag()
  local body = fetch_timeout(DATA_API)
  if not body then return nil end
  -- {"versions":[{"version":"0.2.0",...},...]}
  local ver = body:match('"versions"%s*:%s*%[%s*{%s*"version"%s*:%s*"([^"]+)"')
  if ver and ver ~= "" then return ver end
  return nil
end

-- 从 GitHub tags API 提取最新 tag（实时权威源；jsDelivr data API 索引
-- 滞后是已知问题——v0.3.19~29 连续多版 watch 未检出，必须双源检测）
local function github_tag()
  local body = fetch_timeout("https://api.github.com/repos/" .. REPO .. "/tags")
  if not body then return nil end
  -- [{"name":"v0.3.29","zipball_url":...},...] 第一个即最新（按时间倒序）
  return body:match('"name"%s*:%s*"([^"]+)"')
end

-- 双源并行版本检测（v0.3.93）: jsDelivr 会滞后（索引更新慢），GitHub
-- 有时可达——两个源都查，取较新者。并行（thread）最坏耗时 = 单源
-- 超时 FETCH_TIMEOUT；thread 不可用回退串行（每源仍各自超时）。
-- 返回两源 tag（js, gh），由调用方比较取新。
local function parallel_latest_tags()
  local ok_th, thread = pcall(require, "thread")
  if not ok_th or not thread or not thread.create or not thread.waitForAll then
    -- 串行回退（各源内部已有超时）
    return latest_tag(), github_tag()
  end
  local r1, r2 = {}, {}
  local t1 = thread.create(function() r1.v = latest_tag() end)
  local t2 = thread.create(function() r2.v = github_tag() end)
  local ok_w, werr = pcall(thread.waitForAll, {t1, t2}, FETCH_TIMEOUT)
  return r1.v, r2.v
end

-- tag 归一化比较（v0.3.93）: jsDelivr 返回 "0.3.66"（无 v 前缀），
-- GitHub 返回 "v0.3.70"（有 v）——去 v 前缀 + 数字分段比较取新者。
local function norm_tag(t)
  if not t then return nil end
  local n = tostring(t):gsub("^v", ""):gsub("%s", "")
  return n ~= "" and n or nil
end
local function tag_parts(s)
  local t = {}
  for x in s:gmatch("%d+") do t[#t + 1] = tonumber(x) end
  return t
end
-- 返回较新的 tag（相等取 a）
local function newer_tag(a, b)
  local na, nb = norm_tag(a), norm_tag(b)
  if not na then return b end
  if not nb then return a end
  local pa, pb = tag_parts(na), tag_parts(nb)
  for i = 1, math.max(#pa, #pb) do
    local x, y = pa[i] or 0, pb[i] or 0
    if x ~= y then return (x > y) and a or b end
  end
  return a
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
  -- 双源并行（v0.3.93）: jsDelivr 滞后 + GitHub 可达时取 GitHub 新值
  local tag_js, tag_gh = parallel_latest_tags()
  print("  jsDelivr 源: " .. tostring(tag_js or "?"))
  print("  GitHub 源: " .. tostring(tag_gh or "?"))
  local tag = newer_tag(tag_js, tag_gh)
  if not tag then
    print("  ⚠️  无法自动获取最新版本（两源均超时/不可达，各 15s）。")
    print("  用法: lua update.lua <ref>   例如: lua update.lua v0.3.70")
    return
  end
  -- 两源都通且不一致时提示（信息性）
  if tag_js and tag_gh and norm_tag(tag_js) ~= norm_tag(tag_gh) then
    print("  双源不一致，取较新: " .. tostring(tag))
  end
  ref = tag
end
print("  ref: " .. ref)

local latest
do
  local manifest_body = fetch_timeout(BASE .. "@" .. ref .. "/files.json")
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
-- 双源（v0.3.93）: jsDelivr CDN 优先，GitHub raw 回退（jsDelivr 索引
-- 滞后时 GitHub 仍可达）。每源 fetch_timeout 超时保护（15s），
-- 不会卡住。
local code, code_err
for _, base in ipairs({
  BASE .. "@" .. ref,
  "https://raw.githubusercontent.com/" .. REPO .. "/" .. ref,
}) do
  local body = fetch_timeout(base .. "/install.lua")
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
