-- docs.lua — 可选下载离线文档包（GTNH wiki markdown 纯文本版）
-- 用法: lua docs.lua [dest_dir]     （默认自动选可写挂载盘 → /mnt/<x>/doc）
-- 行为:
--   1. 查询 jsDelivr 最新 tag（不可变 URL，避免 @master 缓存过期）
--   2. 下载 docs.json（几十字节：版本 + tar 大小）→ 与本地 version.txt 对比
--   3. 版本相同 → "已是最新"，跳过下载（不重复下载大 tar）
--   4. 版本不同 → 下载 oc-docs.tar → tar 解压到 dest_dir → 写 version.txt → 删除 tar
--
-- 目标目录示例: /mnt/<short>/doc/api/robot.md、/mnt/<short>/doc/gtnh/open_computers.md
-- agent 可通过 read_file/list_directory 查阅离线文档

local internet = require("internet")

local REPO = "xs4444/oc-agent"
local DATA_API = "https://data.jsdelivr.com/v1/packages/gh/" .. REPO
local BASE = "https://cdn.jsdelivr.net/gh/" .. REPO

-- 自动选第一个可写挂载盘（真实 OC 的数据盘 / ocvm 挂载盘；根盘可能只读）
local function default_dest()
  local fs = require("filesystem")
  for item in fs.list("/mnt") do
    local full = "/mnt/" .. item
    if fs.isDirectory(full) then
      local probe = io.open(full .. "/.doc_probe", "w")
      if probe then
        probe:close()
        os.remove(full .. "/.doc_probe")
        return full .. "/doc"
      end
    end
  end
  return "/doc"
end

local DEST = ({...})[1] or default_dest()
local VERSION_FILE = DEST .. "/version.txt"

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

local function latest_tag()
  local body = fetch(DATA_API)
  if not body then return nil end
  local ver = body:match('"versions"%s*:%s*%[%s*{%s*"version"%s*:%s*"([^"]+)"')
  if ver and ver ~= "" then return ver end
  return nil
end

local function read_local_version()
  local f = io.open(VERSION_FILE, "r")
  if f then
    local v = f:read("*a"):gsub("%s", "")
    f:close()
    if v ~= "" then return v end
  end
  return "(未安装)"
end

local function json_field(body, key)
  return body and body:match('"' .. key .. '"%s*:%s*"([^"]*)"')
end

-- 递归创建目录（OpenOS fs.makeDirectory 不递归）
local function mkdir_rec(path)
  local fs = require("filesystem")
  local parts = {}
  for seg in path:gmatch("[^/]+") do parts[#parts + 1] = seg end
  local cur = ""
  for i = 1, #parts do
    cur = cur .. "/" .. parts[i]
    if not fs.exists(cur) then
      local ok = pcall(fs.makeDirectory, cur)
      if not ok then return false end
    end
  end
  return true
end

-- 纯 Lua ustar 解析器（不依赖 OpenOS 的 tar 命令/库——ocvm 精简镜像无 tar，
-- 真实 OC 也可能缺；包格式仍是标准 ustar tar，本地用 tarfile 生成/验证）
local function parse_ustar(data)
  local entries = {}
  local pos = 1
  local ndata = #data
  while pos + 512 <= ndata do
    local block = data:sub(pos, pos + 511)
    if block == string.rep("\0", 512) then
      break  -- tar 结束标记（零块）
    end
    pos = pos + 512
    local name = block:sub(1, 100):match("^([^%z]+)") or ""
    local size = tonumber(block:sub(125, 136):match("(%d+)") or "0", 8) or 0
    local typeflag = block:sub(157, 157)
    local prefix = block:sub(346, 500):match("^([^%z]+)") or ""
    local full = (prefix ~= "" and prefix .. "/" .. name) or name
    if typeflag == "0" or typeflag == "\0" then
      entries[#entries + 1] = {path = full, content = data:sub(pos, pos + size - 1)}
    end
    pos = pos + math.ceil(size / 512) * 512
  end
  return entries
end

local function extract_all(dest, entries)
  local fs = require("filesystem")
  local written = 0
  for _, e in ipairs(entries) do
    local dir = dest
    local slash = e.path:match("^(.*)/[^/]+$")
    if slash and slash ~= "" then
      dir = dest .. "/" .. slash
      if not fs.exists(dir) and not mkdir_rec(dir) then
        return nil, "目录创建失败: " .. dir
      end
    end
    local f, ferr = io.open(dest .. "/" .. e.path, "wb")
    if not f then
      return nil, "写入失败: " .. dest .. "/" .. e.path .. " (" .. tostring(ferr) .. ")"
    end
    f:write(e.content)
    f:close()
    written = written + 1
  end
  return written
end

local tag = latest_tag()
local ref = tag or "master"
print("检查离线文档版本...")
print("  ref: " .. (tag and ("@" .. tag .. " (tag)") or "@master (回退)"))

-- 1) 元数据对比，决定是否下载
local manifest = fetch(BASE .. "@" .. ref .. "/docs_pack/docs.json")
local latest = manifest and json_field(manifest, "version") or nil
local cur = read_local_version()
print("  当前文档版本: " .. cur)
print("  最新文档版本: " .. tostring(latest or "?"))
if latest and cur == latest then
  print("文档已是最新版本，无需下载。")
  return
end

local tar_name = manifest and json_field(manifest, "tar") or "oc-docs.tar"
print("")
print("下载文档包: " .. tar_name .. " ...")
local tar_data = fetch(BASE .. "@" .. ref .. "/docs_pack/" .. tar_name)
if not tar_data or #tar_data < 10000 then
  print("文档包下载异常（" .. tostring(#(tar_data or "")) .. " 字节），可能是 CDN 缓存延迟，稍后再试")
  return
end

-- 2) 解析 ustar → 解压到 DEST（内存中解析，910KB 包 ~1MB 峰值，可接受）
if not mkdir_rec(DEST) then
  print("创建目录失败: " .. DEST)
  return
end

local entries = parse_ustar(tar_data)
if #entries == 0 then
  print("文档包解析失败（0 个文件）")
  return
end
local written, werr = extract_all(DEST, entries)
if not written then
  print("解压失败: " .. tostring(werr))
  return
end

-- 3) 写版本标记
local vf = io.open(VERSION_FILE, "w")
if vf then
  vf:write(latest or "?")
  vf:close()
end
print("")
print("文档已更新到 " .. DEST .. "（版本 " .. tostring(latest) .. "，" .. #entries .. " 个文件，临时包不落盘）")
print("查阅示例: read_file " .. DEST .. "/api/robot.md")
