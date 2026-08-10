-- ═══════════════════════════════════════════════════════════════
-- OC Agent 安装脚本（小型引导程序）
-- 用法（任选其一，游戏内 OpenOS shell 执行）：
--   1) jsDelivr CDN（国内可达，推荐）:
--      wget https://cdn.jsdelivr.net/gh/xs4444/oc-agent@master/install.lua install.lua
--   2) GitHub raw（需服务器可访问 GitHub）:
--      wget https://raw.githubusercontent.com/xs4444/oc-agent/master/install.lua install.lua
--   然后:           lua install.lua
--   可选参数:       lua install.lua [目录] [ref]
--                   ref 默认 master，可用 <sha> 精确锁版（v2 新增）
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
--   * 四盘场景引导（v0.3.63）:
--      - 选择 agent 安装盘（无参数时引导式列盘选择，不再自动取首个可写盘）
--      - 选择 swap 盘（折叠归档/history 数据盘——写 config.data_dir 引导，
--        agent 首次启动自动把数据落 swap 盘）
--      - docs 盘识别（扫描各盘 /doc/version.txt，显示已安装状态，
--        docs.lua 负责实际安装/卸载）
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

-- 可写探测
local function is_writable(dir)
  local probe = dir .. "/.writetest"
  local f = io.open(probe, "w")
  if f then f:close(); os.remove(probe); return true end
  return false
end

-- 可写挂载盘列表: {path, label, free_kb, writable}（df.lua 同款组件 API）
local function scan_writable_mounts()
  local out = {}
  local ok_m, iter = pcall(fs.mounts)
  if not ok_m or type(iter) ~= "function" then return out end
  for proxy, path in iter do
    if path ~= "/" and is_writable(path) then
      local label = ""
      local ok_l, l = pcall(function() return proxy.getLabel() end)
      if ok_l and l then label = l end
      local free_kb = 0
      local ok_t, total = pcall(function() return proxy.spaceTotal() end)
      local ok_u, used = pcall(function() return proxy.spaceUsed() end)
      if ok_t and ok_u and type(total) == "number" and type(used) == "number"
          and total ~= math.huge then
        free_kb = math.floor((total - used) / 1024)
      end
      -- 识别线索: 根目录前几个文件名（区分各盘）
      local samples = {}
      local ok_s, s_iter = pcall(fs.list, path)
      if ok_s and type(s_iter) == "function" then
        local n = 0
        for entry in s_iter do
          n = n + 1
          if n > 3 then break end
          samples[#samples + 1] = tostring(entry)
        end
      end
      out[#out + 1] = {path = path, label = label, free_kb = free_kb,
        samples = samples}
    end
  end
  return out
end

-- 选择引导（可写盘列表 → 编号选择/取消）。prompt 说明用途；
-- 返回盘路径或 nil（取消）。
local function choose_disk(prompt, mounts, skip_path)
  print("")
  print(prompt)
  local shown = {}
  local idx = 0
  for _, m in ipairs(mounts) do
    if m.path ~= skip_path then
      idx = idx + 1
      local info = "  " .. idx .. ") " .. m.path
      if m.label ~= "" then info = info .. "  (" .. m.label .. ")" end
      if m.free_kb > 0 then info = info .. "  free=" .. m.free_kb .. "KB" end
      if #m.samples > 0 then info = info .. "  files: " .. table.concat(m.samples, ", ") end
      print(info)
      shown[idx] = m.path
    end
  end
  if idx == 0 then
    print("  (没有可选的盘)")
    return nil
  end
  io.write("输入编号（回车取消）: ")
  local answer = io.read() or ""
  -- gsub 双返回值（同上方 agent 安装盘选择处）——包括号取首个
  local n = tonumber((answer:gsub("%s", "")))
  if not n or n < 1 or n > #shown then
    return nil
  end
  return shown[n]
end

-- docs 已安装状态扫描（docs.lua 同款: /mnt/*/doc/version.txt + /doc/version.txt）
-- 返回 {path=..., version=...} 列表
local function scan_docs_installed()
  local found = {}
  local ok_m, iter = pcall(fs.mounts)
  if ok_m and type(iter) == "function" then
    for _, path in iter do
      if path ~= "/" then
        local full = path .. "/doc/version.txt"
        local f = io.open(full, "r")
        if f then
          local v = f:read("*a"):gsub("%s", "")
          f:close()
          if v ~= "" then found[#found + 1] = {path = path .. "/doc", version = v} end
        end
      end
    end
  end
  local f_root = io.open("/doc/version.txt", "r")
  if f_root then
    local v = f_root:read("*a"):gsub("%s", "")
    f_root:close()
    if v ~= "" then found[#found + 1] = {path = "/doc", version = v} end
  end
  return found
end

-- 目标目录: 命令行参数优先 (lua install.lua /mnt/xxx)；否则引导式
-- 列出可写盘让用户选择 agent 安装盘（四盘场景: 不再盲目取首个可写盘）
local mounts = scan_writable_mounts()
if not DEST_DIR or DEST_DIR == "" then
  if #mounts == 0 then
    if is_writable("/home") then
      DEST_DIR = "/home"
    else
      DEST_DIR = "."
    end
  elseif #mounts == 1 and mounts[1].path ~= "/home" then
    DEST_DIR = mounts[1].path
    print("检测到唯一可写盘: " .. DEST_DIR)
  else
    -- 引导: /home 优先作为默认选项（传统路径），其余盘编号选择
    print("")
    print("选择 agent 安装盘:")
    local idx = 0
    local shown = {}
    local home_shown = false
    if is_writable("/home") then
      -- /home 在根盘（系统盘）上，可写时单独列为 0 号选项
      home_shown = true
      print("  0) /home  (系统盘用户目录)")
    end
    for _, m in ipairs(mounts) do
      idx = idx + 1
      local info = "  " .. idx .. ") " .. m.path
      if m.label ~= "" then info = info .. "  (" .. m.label .. ")" end
      if m.free_kb > 0 then info = info .. "  free=" .. m.free_kb .. "KB" end
      if #m.samples > 0 then info = info .. "  files: " .. table.concat(m.samples, ", ") end
      print(info)
      shown[idx] = m.path
    end
    io.write("输入编号（回车 = /home）: ")
    local answer = io.read() or ""
    -- gsub 返回两个值（字符串+替换次数）——不包括号会把次数当
    -- tonumber 的 base 参数（空输入次数=0 → "base out of range"，
    -- ocvm 实测踩中）。包一层括号取第一个返回值。
    local n = tonumber((answer:gsub("%s", "")))
    if n and n >= 1 and n <= #shown then
      DEST_DIR = shown[n]
    elseif home_shown then
      DEST_DIR = "/home"
    elseif #shown > 0 then
      DEST_DIR = shown[1]
    else
      DEST_DIR = "."
    end
    print("agent 安装盘: " .. DEST_DIR)
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
-- url_prefix: 仓库内相对路径前缀（src/agent 模块用 "/src/agent/"；根目录
-- 工具如 docs.lua 用 "/"）
local function download_verified(relpath, dest, expected, attempts, url_prefix)
  local source_count = #SOURCES
  url_prefix = url_prefix or "/src/agent/"
  for attempt = 1, attempts do
    local i = ((attempt - 1) % source_count) + 1
    local url = SOURCES[i] .. url_prefix .. relpath
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
  -- 同时提取 version 字符串（JSON 回退时保留，供安装后显示）
  local ver = body:match('"version"%s*:%s*"([^"]+)"')
  if next(files) then
    local m = { files = files }
    if ver then m.version = ver end
    return m
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
      print("  最新版本: " .. tostring(manifest.version or "?"))
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
  print("按清单检查 " .. #relpaths .. " 个模块（增量更新，未变动的文件跳过）")
  local installed, skipped, failed = 0, 0, 0
  for _, relpath in ipairs(relpaths) do
    local expected = manifest.files[relpath]
    local dest
    if relpath == "init.lua" then
      dest = AGENT_DIR .. "/agent.lua"  -- 入口改名
    else
      dest = AGENT_DIR .. "/" .. relpath
    end
    -- 增量判断: 本地文件已存在且字节数 == manifest 期望值 → 跳过
    local up_to_date = false
    do
      local ok_size, sz = pcall(fs.size, dest)
      if ok_size and sz == expected then up_to_date = true end
    end
    if up_to_date then
      skipped = skipped + 1
    else
      print("更新 " .. relpath .. " (期望 " .. expected .. " 字节)")
      -- 根目录工具（docs.lua）用根前缀下载
      local prefix = (relpath == "docs.lua") and "/" or nil
      local ok = download_verified(relpath, dest, expected, 3, prefix)
      if ok then
        installed = installed + 1
      else
        failed = failed + 1
      end
    end
  end

  if failed > 0 then
    print("")
    print("有 " .. failed .. " 个文件下载失败。请检查网络后重新运行 install.lua；")
    print("已下载的文件会被幂等覆盖，无需清理。")
    return
  end

  -- 记录已安装版本（update.lua 据此判断是否需要更新）
  do
    local vf = io.open(AGENT_DIR .. "/version.txt", "w")
    if vf then
      vf:write(tostring(manifest.version or "?"))
      vf:close()
    end
  end

  ask_subagent()

  -- ── 四盘场景引导（v0.3.63）──────────────────────────
  -- 1) swap 盘选择: 折叠归档/history/sessions 数据盘。写入 agent_config.txt
  --    的 data_dir 字段——agent 启动时 probe_data_dir 探测到该字段即把
  --    数据路径切到 swap 盘（等价于部署后手动 /relocate，安装期一步完成）。
  do
    local swap = choose_disk("选择 swap 盘（agent 数据盘: 历史/折叠归档/会话；回车跳过）",
      mounts, DEST_DIR)
    if swap then
      local ser = require("serialization")
      local cfg_path = DEST_DIR .. "/agent_config.txt"
      local cfg = {}
      local cf = io.open(cfg_path, "r")
      if cf then
        local ok_c, parsed = pcall(ser.unserialize, cf:read("*a"))
        cf:close()
        if ok_c and type(parsed) == "table" then cfg = parsed end
      end
      cfg.data_dir = swap
      -- 无 config 时补默认模型配置（首次运行直接可用）
      if not cfg.api_key then cfg.api_key = "" end
      if not cfg.model then cfg.model = "deepseek-v4-flash-free" end
      if not cfg.api_url then
        cfg.api_url = "https://opencode.ai/zen/v1/chat/completions"
      end
      local f = io.open(cfg_path, "w")
      if f then
        f:write(ser.serialize(cfg))
        f:close()
        print("swap 盘已配置: " .. swap .. "（data_dir 引导写入 " .. cfg_path .. "）")
      else
        print("无法写入配置文件: " .. cfg_path)
      end
    else
      print("未选择 swap 盘（数据将落在安装盘）。部署后可用 /relocate 迁移。")
    end
  end

  -- 2) docs 盘识别（只显示状态；安装/卸载由 lua docs.lua install/uninstall）
  do
    local docs = scan_docs_installed()
    if #docs > 0 then
      for _, d in ipairs(docs) do
        print("docs 已安装: " .. d.path .. "  (版本 " .. d.version .. ")")
      end
    else
      print("docs 未安装（如需离线文档:  lua docs.lua install）")
    end
  end

  -- ── PATH 集成: 创建 /home/bin/agent + update 启动器（OpenOS 默认
  -- PATH 含 /home/bin）──
  -- update 启动器同样注册: 否则用户只能 lua update.lua（update.lua
  -- 需从 GitHub 下载到当前目录——install 后直接敲 update 找不到命令，
  -- 2026-08-10 用户实测反馈）。启动器自下载/复用同名脚本。
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
    -- update 启动器（更新脚本本体由安装流程下载到 AGENT_DIR 父目录）
    local up_dir = AGENT_DIR:match("^(.*)/agent$") or "/home"
    local up_script = up_dir .. "/update.lua"
    local up_launcher = "/home/bin/update.lua"
    local uf = io.open(up_launcher, "w")
    if uf then
      uf:write("-- update launcher (created by install.lua)\n")
      uf:write("local script = " .. string.format("%q", up_script) .. "\n")
      uf:write("local fs_mod = require('filesystem')\n")
      uf:write("if not fs_mod.exists(script) then\n")
      uf:write("  print('update.lua 未安装到 ' .. script)\n")
      uf:write("  print('请先运行: lua install.lua（会下载 update.lua）')\n")
      uf:write("  return\n")
      uf:write("end\n")
      uf:write("local chunk = assert(loadfile(script))\n")
      uf:write("chunk(...)\n")
      uf:close()
      -- 下载 update.lua 本体到 AGENT_DIR 父目录（与 agent/ 同盘，供
      -- 启动器引用；用与 install 自身相同的双源 fallback）
      if not fs.exists(up_script) then
        local f_up = io.open(up_script, "w")
        if f_up then
          for _, base in ipairs(SOURCES) do
            local handle = pcall(internet.request, base .. "/update.lua")
            local ok_h, h = handle
            if ok_h and h then
              local ok_w = true
              for chunk_data in h do
                if not f_up:write(chunk_data) then ok_w = false break end
              end
              h:close()
              if ok_w then break end
            end
          end
          f_up:close()
        end
      end
    end
  end

  print("")
  print("安装完成！")
  print("  模块数: " .. installed .. " 个（版本 " .. tostring(manifest.version or "?") .. "）")
  print("  本次更新: " .. installed .. " 个文件" .. (skipped > 0 and ("，" .. skipped .. " 个未变化已跳过") or ""))
  print("  安装路径: " .. AGENT_DIR)
  print("  启动方式:")
  print("    agent                    -- 任意目录直接运行（PATH 集成）")
  print("    agent -- --subagent      -- 子代理模式")
  if not launcher_ok then
    print("  ⚠️  无法写入 " .. launcher_path .. "（PATH 启动器创建失败）")
    print("     可手动: lua " .. AGENT_DIR .. "/agent.lua")
  end
  print("  更新方式:  update           -- 任意目录直接运行（PATH 集成）")
  print("             或 lua update.lua")
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
