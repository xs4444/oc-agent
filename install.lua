-- ═══════════════════════════════════════════════════════════════
-- OC Agent 安装脚本（小型引导程序）
-- 用法（任选其一，游戏内 OpenOS shell 执行）：
--   1) jsDelivr CDN（国内可达，推荐）:
--      wget https://cdn.jsdelivr.net/gh/xs4444/oc-agent@master/install.lua install.lua
--   2) GitHub raw（需服务器可访问 GitHub）:
--      wget https://raw.githubusercontent.com/xs4444/oc-agent/master/install.lua install.lua
--   然后:           lua install.lua
--   可选参数:       lua install.lua [目录] [ref]
--                   ref 默认 main，可用 <sha> 精确锁版（v2 新增）
--
-- 功能:
--   * 多文件模式（Phase 3b，默认）: 下载 files.json 清单，将 src/agent/
--     全部模块安装到 <目录>/agent/（init.lua → agent.lua），每个文件
--     按清单字节数校验，失败重试 ×3，已下载文件幂等覆盖
--   * 回退模式（v1 兼容）: 清单下载/解析失败时，下载单文件 agent.lua
--     到当前目录（老路径完全可用）
--   * 双源 fallback（jsDelivr CDN 优先 + GitHub raw 备用）
--   * 自动探测可写目录 / 命令行指定目录
--   * 可选: 写子代理配置文件（subagent = true）
-- ═══════════════════════════════════════════════════════════════

-- 命令行参数: [1]=目标目录, [2]=Git ref（默认 master，可用 <sha>）
local DEST_DIR = select(1, ...)
local REF = select(2, ...)
if not REF or REF == "" then REF = "master" end

-- jsDelivr 排首位（国内可达性好），GitHub raw 作为 fallback
local SOURCES = {
  "https://cdn.jsdelivr.net/gh/xs4444/oc-agent@" .. REF,
  "https://raw.githubusercontent.com/xs4444/oc-agent/" .. REF,
}
local EXPECTED_MIN = 60000  -- 回退模式: 单文件 agent.lua 应至少 60KB

local fs = require("filesystem")

-- 目标目录: 优先取命令行参数 (lua install.lua /mnt/xxx)，否则自动找可写位置
if not DEST_DIR or DEST_DIR == "" then
  local function is_writable(dir)
    local probe = dir .. "/.writetest"
    local f = io.open(probe, "w")
    if f then f:close(); os.remove(probe); return true end
    return false
  end
  if is_writable("/home") then
    DEST_DIR = "/home"
  else
    for _, mount in fs.mounts() do
      if mount and mount ~= "/" and is_writable(mount) then
        DEST_DIR = mount
        break
      end
    end
  end
end
if not DEST_DIR or DEST_DIR == "" then DEST_DIR = "." end

-- 拉取 URL 全文并返回 body（写入由调用方决定）
local function fetch(url)
  local internet = require("internet")
  local ok, handle = pcall(function()
    return internet.request(url)
  end)
  if not ok then return nil, "connection failed: " .. tostring(handle) end

  local chunks = {}
  local iter_ok, iter_err = pcall(function()
    for chunk in handle do
      chunks[#chunks + 1] = chunk
      os.sleep(0.02)  -- yield: avoid "too long without yielding"
    end
  end)
  if not iter_ok then return nil, "read failed: " .. tostring(iter_err) end
  local body = table.concat(chunks)
  if #body == 0 then return nil, "empty response" end
  return body
end

-- 写文件（幂等覆盖）
local function write_file(path, content)
  local f = io.open(path, "w")
  if not f then return false, "cannot open " .. path .. " for writing" end
  f:write(content)
  f:close()
  return true
end

-- 子代理配置（v1 逻辑: 回答 y 则写 subagent=true 到 config）
local function ask_subagent()
  print("")
  io.write("将此机器配置为子代理 (监听模式)? [y/N]: ")
  local answer = io.read() or ""
  if answer:gsub("%s", ""):lower() == "y" then
    local ser = require("serialization")
    local cfg_path = DEST_DIR .. "/agent_config.txt"
    local cfg = {api_key = "", model = "deepseek-v4-flash-free", api_url = "https://opencode.ai/zen/v1/chat/completions", subagent = true}
    local f = io.open(cfg_path, "w")
    if f then
      f:write(ser.serialize(cfg))
      f:close()
      print("子代理配置已写入 " .. cfg_path)
    else
      print("无法写入配置文件: " .. cfg_path)
    end
  end
end

print("OC Agent 安装器")
print("===============")
print("目标目录: " .. DEST_DIR .. "   ref: " .. REF)

-- 下载并校验单个文件: attempts 次尝试（按源轮换），字节数必须 == expected
local function download_verified(relpath, dest, expected, attempts)
  local source_count = #SOURCES
  for attempt = 1, attempts do
    local i = ((attempt - 1) % source_count) + 1
    local url = SOURCES[i] .. "/src/agent/" .. relpath
    print("  尝试源 " .. i .. "/" .. source_count .. " (第 " .. attempt .. " 次): " .. url)
    local body, err = fetch(url)
    if body then
      if #body == expected then
        local ok, werr = write_file(dest, body)
        if not ok then return nil, werr end
        return true
      end
      -- 容错: 字节数不符但内容合法（CDN 缓存/行尾差异），验证 Lua 可编译即通过
      local chk = load(body)
      if chk and #body >= expected * 0.8 then
        print("  字节数不符 (" .. #body .. " vs " .. expected .. ")，但 Lua 编译通过，接受")
        local ok, werr = write_file(dest, body)
        if not ok then return nil, werr end
        return true
      end
      print("  字节数不符: 期望 " .. expected .. "，实际 " .. #body)
    else
      print("  失败: " .. tostring(err))
    end
  end
  return nil, "download failed after " .. attempts .. " attempts: " .. relpath
end

-- ── 多文件模式: 尝试下载并解析 files.json ──────────────────────
-- files.json 是标准 JSON（"key": value）。真实 OpenOS 的
-- serialization.unserialize 只认 OC 的 key=value 格式，解析 JSON 会
-- 失败，因此先试 unserialize，失败则回退到 JSON 模式提取
-- （清单结构固定: {"files": {"relpath": 字节数, ...}}）。
local function parse_manifest(body)
  local ser = require("serialization")
  local ok, parsed = pcall(ser.unserialize, body)
  if ok and type(parsed) == "table" and type(parsed.files) == "table" then
    return parsed
  end
  -- JSON 回退: 提取所有 "relpath": <数字> 键值对（排除 "version" 等非文件键）
  local files = {}
  for relpath, size in body:gmatch('"([^"]+)"%s*:%s*(%d+)') do
    if relpath ~= "version" then
      files[relpath] = tonumber(size)
    end
  end
  if next(files) then
    return { files = files }
  end
  return nil
end

local manifest
for i, base in ipairs(SOURCES) do
  local url = base .. "/files.json"
  print("尝试清单源 " .. i .. "/" .. #SOURCES .. ": " .. url)
  local body = fetch(url)
  if body then
    print("  清单下载成功: " .. #body .. " 字节")
    manifest = parse_manifest(body)
    if manifest then
      break
    else
      print("  清单解析失败，尝试下一个源")
    end
  else
    print("  失败: 清单不可用")
  end
end

if manifest then
  -- ── 多文件安装流程 ──────────────────────────────────────
  local AGENT_DIR = DEST_DIR .. "/agent"
  -- OpenOS fs.makeDirectory can raise (not just return false) when the
  -- parent is not writable, so guard both creates.
  local mk_ok, mk_err = pcall(function()
    fs.makeDirectory(AGENT_DIR)
    fs.makeDirectory(AGENT_DIR .. "/tools")
  end)
  if not mk_ok then
    print("无法创建安装目录 " .. AGENT_DIR .. ": " .. tostring(mk_err))
    print("请检查父目录是否可写，然后重新运行 install.lua。")
    return
  end

  local relpaths = {}
  for relpath in pairs(manifest.files) do
    relpaths[#relpaths + 1] = relpath
  end
  table.sort(relpaths)

  print("")
  print("按清单安装 " .. #relpaths .. " 个模块到 " .. AGENT_DIR)
  local installed, failed = 0, 0
  for _, relpath in ipairs(relpaths) do
    local expected = manifest.files[relpath]
    local dest
    if relpath == "init.lua" then
      dest = AGENT_DIR .. "/agent.lua"  -- 入口改名
    else
      dest = AGENT_DIR .. "/" .. relpath
    end
    print("下载 " .. relpath .. " (期望 " .. expected .. " 字节)")
    local ok = download_verified(relpath, dest, expected, 3)
    if ok then
      installed = installed + 1
    else
      failed = failed + 1
    end
  end

  if failed > 0 then
    print("")
    print("有 " .. failed .. " 个文件下载失败。请检查网络后重新运行 install.lua；")
    print("已下载的文件会被幂等覆盖，无需清理。")
    return
  end

  ask_subagent()

  -- ── PATH 集成: 创建 /home/bin/agent 启动器（OpenOS 默认 PATH 含 /home/bin）──
  local launcher_ok = false
  local launcher_path = "/home/bin/agent.lua"
  do
    local mk_ok, mk_err = pcall(function()
      local fs_mod = require("filesystem")
      fs_mod.makeDirectory("/home/bin")
    end)
    local lf = io.open(launcher_path, "w")
    if lf then
      lf:write("-- agent launcher (created by install.lua)\n")
      lf:write("AGENT_DIR = " .. string.format("%q", AGENT_DIR) .. "\n")
      lf:write("package.path = " .. string.format("%q", AGENT_DIR .. "/../?.lua;") .. " .. (package.path or '')\n")
      lf:write("local chunk = assert(loadfile(AGENT_DIR .. '/agent.lua'))\n")
      lf:write("chunk(...)\n")
      lf:close()
      launcher_ok = true
    end
  end

  print("")
  print("安装完成！")
  print("  模块数: " .. installed .. " 个（版本 " .. tostring(manifest.version or "?") .. "）")
  print("  安装路径: " .. AGENT_DIR)
  print("  启动方式:")
  print("    agent                    -- 任意目录直接运行（PATH 集成）")
  print("    agent -- --subagent      -- 子代理模式")
  if not launcher_ok then
    print("  ⚠️  无法写入 " .. launcher_path .. "（PATH 启动器创建失败）")
    print("     可手动: lua " .. AGENT_DIR .. "/agent.lua")
  end
  print("  更新方式:  lua update.lua")
else
  -- ── 回退模式 (v1 单文件流程，完全兼容) ─────────────────
  print("")
  print("未找到 files.json，回退到 v1 单文件模式。")
  local DEST = DEST_DIR .. "/agent.lua"

  local body, err
  for i, url in ipairs(SOURCES) do
    print("尝试源 " .. i .. "/" .. #SOURCES .. ": " .. url .. "/agent.lua")
    body, err = fetch(url .. "/agent.lua")
    if body then
      print("  下载成功: " .. #body .. " 字节")
      break
    end
    print("  失败: " .. tostring(err))
  end

  if not body then
    print("所有下载源均失败。请检查互联网卡，或手动安装 agent.lua。")
    return
  end

  local ok, werr = write_file(DEST, body)
  if not ok then
    print("无法写入: " .. werr)
    return
  end

  -- 校验
  if #body < EXPECTED_MIN then
    print("警告: 文件偏小 (" .. #body .. " 字节)，可能下载不完整")
  end
  local first_line = body:match("^([^\n]*)")
  if first_line:find("OC Agent") or body:find("json%.encode") then
    print("校验通过: 文件内容符合 agent.lua 预期")
  else
    print("警告: 文件内容与预期不符，请人工检查")
  end

  ask_subagent()

  print("")
  print("安装完成！")
  print("  启动方式:")
  print("    主代理:   lua " .. DEST)
  print("    子代理:   lua " .. DEST .. " -- --subagent   (或已配置 subagent=true 时直接 lua " .. DEST .. ")")
  print("  更新方式:  重新运行本脚本即可覆盖为最新版")
end
