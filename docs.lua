-- docs.lua — 可选下载离线文档包（GTNH wiki markdown 纯文本版）
-- 用法:
--   lua docs.lua                交互引导：显示已安装/候选盘 → 选择安装或卸载
--   lua docs.lua install        同交互引导（安装模式）
--   lua docs.lua uninstall      卸载已安装文档（交互确认）
--   lua docs.lua status         只显示状态（已安装位置/版本/候选盘），不下载
--   lua docs.lua /mnt/9ab/doc   直接安装到指定目录（旧用法兼容）
-- 行为:
--   1. 查询 jsDelivr 最新 tag（不可变 URL，避免 @master 缓存过期）
--   2. 下载 docs.json（几十字节：版本 + tar 大小）→ 与本地 version.txt 对比
--   3. 版本相同 → "已是最新"，跳过下载（不重复下载大 tar）
--   4. 版本不同 → 下载 oc-docs.tar → 纯 Lua ustar 解压 → 写 version.txt
-- 目标目录示例: /mnt/<short>/doc/api/robot.md、/mnt/<short>/doc/gtnh/open_computers.md

local internet = require("internet")

local REPO = "xs4444/oc-agent"
local DATA_API = "https://data.jsdelivr.com/v1/packages/gh/" .. REPO
local BASE = "https://cdn.jsdelivr.net/gh/" .. REPO

-- ── 工具函数 ───────────────────────────────────────────────────

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

local function json_field(body, key)
  return body and body:match('"' .. key .. '"%s*:%s*"([^"]*)"')
end

local function read_version(dir)
  local f = io.open(dir .. "/version.txt", "r")
  if f then
    local v = f:read("*a"):gsub("%s", "")
    f:close()
    if v ~= "" then return v end
  end
  return nil
end

local function human_size(n)
  n = tonumber(n) or 0
  if n >= 1048576 then return string.format("%.1f MiB", n / 1048576) end
  if n >= 1024 then return string.format("%.1f KiB", n / 1024) end
  return n .. " B"
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

-- 递归删除（OpenOS fs.remove 不递归）
local function rm_rec(path)
  local fs = require("filesystem")
  if fs.isDirectory(path) then
    local ok_ls, iter = pcall(fs.list, path)
    if ok_ls then
      for item in iter do
        rm_rec(path .. "/" .. item)
      end
    end
  end
  return pcall(fs.remove, path)
end

-- 纯 Lua ustar 解析器（不依赖 OpenOS 的 tar 命令/库）
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
    local slash = e.path:match("^(.*)/[^/]+$")
    if slash and slash ~= "" then
      local dir = dest .. "/" .. slash
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

-- ── 磁盘/安装状态扫描 ─────────────────────────────────────────

-- 扫描已安装位置: 返回 {path=..., version=...} 列表（/mnt/*/doc + /doc）
local function scan_installed()
  local fs = require("filesystem")
  local found = {}
  local ok_ls, iter = pcall(fs.list, "/mnt")
  if ok_ls then
    for item in iter do
      -- fs.list 的目录项可能带尾斜杠（ocvm 等实现差异），先去掉
      local name = tostring(item):gsub("/$", "")
      local full = "/mnt/" .. name .. "/doc"
      local v = read_version(full)
      if v then found[#found + 1] = {path = full, version = v} end
    end
  end
  local v_root = read_version("/doc")
  if v_root then found[#found + 1] = {path = "/doc", version = v_root} end
  return found
end

-- 扫描候选盘（/mnt 下可写目录）: 返回 {path=..., cap=...} 列表
local function scan_disks()
  local fs = require("filesystem")
  local disks = {}
  local ok_ls, iter = pcall(fs.list, "/mnt")
  if ok_ls then
    for item in iter do
      local name = tostring(item):gsub("/$", "")
      local full = "/mnt/" .. name
      if fs.isDirectory(full) then
        local probe = io.open(full .. "/.doc_probe", "w")
        if probe then
          probe:close()
          os.remove(full .. "/.doc_probe")
          local cap = nil
          local ok_sz, sz = pcall(fs.size, full)
          if ok_sz then cap = sz end
          disks[#disks + 1] = {path = full, cap = cap}
        end
      end
    end
  end
  return disks
end

-- ── 安装/卸载执行 ─────────────────────────────────────────────

-- 下载并解压到指定目录（含版本跳过）；返回 true/错误信息
local function install_to(dest, ref, manifest)
  local latest = manifest and json_field(manifest, "version") or nil
  local cur = read_version(dest)
  print("  目标: " .. dest .. "（当前 " .. tostring(cur or "未安装") .. "）")
  print("  最新: " .. tostring(latest or "?"))
  if latest and cur == latest then
    print("该位置文档已是最新，跳过下载。")
    return true
  end

  local tar_name = manifest and json_field(manifest, "tar") or "oc-docs.tar"
  print("下载文档包: " .. tar_name .. " ...")
  local tar_data = fetch(BASE .. "@" .. ref .. "/docs_pack/" .. tar_name)
  if not tar_data or #tar_data < 10000 then
    print("文档包下载异常（" .. tostring(#(tar_data or "")) .. " 字节），可能是 CDN 缓存延迟，稍后再试")
    return false
  end

  if not mkdir_rec(dest) then
    print("创建目录失败: " .. dest)
    return false
  end
  local entries = parse_ustar(tar_data)
  if #entries == 0 then
    print("文档包解析失败（0 个文件）")
    return false
  end
  local written, werr = extract_all(dest, entries)
  if not written then
    print("解压失败: " .. tostring(werr))
    return false
  end

  local vf = io.open(dest .. "/version.txt", "w")
  if vf then
    vf:write(latest or "?")
    vf:close()
  end
  print("文档已更新到 " .. dest .. "（版本 " .. tostring(latest) .. "，" .. written .. " 个文件）")
  print("查阅示例: read_file " .. dest .. "/api/robot.md")
  return true
end

local function uninstall(target)
  print("卸载 " .. target .. " ...")
  local ok_rm, rerr = rm_rec(target)
  if ok_rm then
    print("已卸载: " .. target)
  else
    print("卸载失败: " .. tostring(rerr))
  end
end

-- ── 交互引导 ──────────────────────────────────────────────────

local function interactive()
  local fs = require("filesystem")
  print("")
  print("=== 离线文档管理 ===")

  -- 已安装
  local installed = scan_installed()
  if #installed > 0 then
    print("已安装:")
    for i, ins in ipairs(installed) do
      print("  [" .. i .. "] " .. ins.path .. " — 版本 " .. ins.version)
    end
  else
    print("已安装: (无)")
  end

  -- 候选盘
  local disks = scan_disks()
  print("候选盘（可写挂载）:")
  if #disks == 0 then
    print("  (未发现可写挂载盘，将使用根目录 /doc)")
  end
  for i, d in ipairs(disks) do
    local tag = ""
    for _, ins in ipairs(installed) do
      if ins.path == d.path .. "/doc" then tag = "（已安装）" end
    end
    print("  [" .. i .. "] " .. d.path .. " — " .. human_size(d.cap) .. tag)
  end

  print("")
  print("操作: 1) 安装  2) 卸载  3) 只查看状态  4) 退出")
  io.write("选择 [1]: ")
  local choice = io.read()
  if not choice then choice = "1" end
  choice = choice:gsub("%s", "")

  if choice == "2" then
    -- 卸载
    if #installed == 0 then
      print("没有已安装的文档，无需卸载。")
      return
    end
    print("选择要卸载的位置:")
    for i, ins in ipairs(installed) do
      print("  [" .. i .. "] " .. ins.path .. " — 版本 " .. ins.version)
    end
    io.write("输入编号 [1]: ")
    local pick = io.read()
    local idx = tonumber(pick and pick:gsub("%s", "")) or 1
    local target = installed[idx] and installed[idx].path or installed[1].path
    io.write("确认删除 " .. target .. "？(y/N): ")
    local confirm = io.read()
    if confirm and confirm:gsub("%s", ""):lower() == "y" then
      uninstall(target)
    else
      print("已取消。")
    end
    return
  elseif choice == "3" or choice == "4" then
    print("未做任何修改。")
    return
  end

  -- 安装
  local tag = latest_tag()
  local ref = tag or "master"
  print("")
  print("检查离线文档版本...")
  print("  ref: " .. (tag and ("@" .. tag .. " (tag)") or "@master (回退)"))
  local manifest = fetch(BASE .. "@" .. ref .. "/docs_pack/docs.json")
  if not manifest then
    print("无法获取文档元数据（网络/CDN 问题），稍后再试。")
    return
  end

  local dest
  if #disks > 0 then
    print("选择安装位置:")
    for i, d in ipairs(disks) do
      local rec = ""
      if i == 1 then rec = "（推荐: 剩余空间最大）" end
      print("  [" .. i .. "] " .. d.path .. "/doc — " .. human_size(d.cap) .. rec)
    end
    print("  [0] 根目录 /doc（不推荐: 系统盘空间紧张）")
    io.write("选择 [1]: ")
    local pick = io.read()
    local idx = tonumber(pick and pick:gsub("%s", "")) or 1
    if idx == 0 then
      dest = "/doc"
    else
      dest = (disks[idx] and disks[idx].path or disks[1].path) .. "/doc"
    end
  else
    dest = "/doc"
  end

  print("")
  install_to(dest, ref, manifest)
end

-- ── 入口 ──────────────────────────────────────────────────────

local args = {...}
local mode = args[1]

if mode == "uninstall" then
  local installed = scan_installed()
  if #installed == 0 then
    print("没有已安装的文档，无需卸载。")
  else
    print("已安装:")
    for i, ins in ipairs(installed) do
      print("  [" .. i .. "] " .. ins.path .. " — 版本 " .. ins.version)
    end
    io.write("选择要卸载的位置 [1]: ")
    local pick = io.read()
    local idx = tonumber(pick and pick:gsub("%s", "")) or 1
    local target = installed[idx] and installed[idx].path or installed[1].path
    io.write("确认删除 " .. target .. "？(y/N): ")
    local confirm = io.read()
    if confirm and confirm:gsub("%s", ""):lower() == "y" then
      uninstall(target)
    else
      print("已取消。")
    end
  end
elseif mode == "status" then
  local installed = scan_installed()
  if #installed > 0 then
    for _, ins in ipairs(installed) do
      print("已安装: " .. ins.path .. " — 版本 " .. ins.version)
    end
  else
    print("已安装: (无)")
  end
  for _, d in ipairs(scan_disks()) do
    print("候选盘: " .. d.path .. " — " .. human_size(d.cap))
  end
elseif mode and mode:sub(1, 1) == "/" then
  -- 直接指定目录（旧用法兼容）
  local tag = latest_tag()
  local ref = tag or "master"
  print("检查离线文档版本... ref: " .. (tag and ("@" .. tag .. " (tag)") or "@master (回退)"))
  local manifest = fetch(BASE .. "@" .. ref .. "/docs_pack/docs.json")
  if manifest then
    install_to(mode, ref, manifest)
  else
    print("无法获取文档元数据（网络/CDN 问题），稍后再试。")
  end
else
  -- 交互引导（无参 / install）
  interactive()
end
