-- ═══════════════════════════════════════════════════════════════
-- agent.tools.disk — 磁盘管理与数据迁移工具（2026-08-10 新增）。
--
-- 背景: OC 数据盘通常 <1MB，append-only history JSONL 跨会话累积
-- 会写满；盘满 → append 静默失败 → 会话内存膨胀 → encode OOM
-- （真机 2026-08-10 现场）。用户只需自然语言（"数据迁移到其他盘"
-- /"清理磁盘"），由 LLM 自主调用本模块工具。
--
-- 工具:
--   list_storage   扫描各挂载盘容量/剩余 + agent 数据占用（决策依据）
--   cleanup_disk   删旧会话（保留最近 keep 个）+ 截断超限 history
--   relocate_data  把 config/history/sessions 迁移到目标盘，写
--                  data_dir 引导（重启自动切盘），本进程内立即切换
--
-- Module contract: exports {tools = {...}, exec = function(name, args,
-- deps)}. exec returns nil for tool names it does not handle.
--
-- deps 注入（init.lua DEPS 表）:
--   json, load_config, save_config, session (session_mod 引用),
--   get_writable_base（WRITABLE_BASE）——disk 工具在 tools/ 目录加载，
--   拿不到 init.lua 的局部变量，路径常量由 DEPS 传入。
-- ═══════════════════════════════════════════════════════════════

local tools = {
  {type="function", ["function"]={
    name="list_storage",
    description="Scan all mounted filesystems and report capacity, free space, and the agent's own data footprint (config/history/sessions sizes). Use BEFORE deciding whether or where to relocate/clean up disk data. Returns one line per mount plus an agent-data summary.",
    parameters={type="object", properties={}, required={}}
  }},
  {type="function", ["function"]={
    name="cleanup_disk",
    description="Free disk space: delete old session files (keeps the most recent `keep` sessions, default 5, current session always kept) and truncate the history file to the in-memory table if it exceeds mem_history_max_bytes (default 256KB). Returns what was deleted and bytes freed. Use when the user reports a full disk, when list_storage shows a full disk, or before a data migration.",
    parameters={type="object", properties={keep={type="number", description="Number of recent sessions to keep (default 5, 0 = only the current one)"}}, required={}}
  }},
  {type="function", ["function"]={
    name="relocate_data",
    description="Migrate the agent's data directory (config, history, sessions) to a different, writable filesystem — e.g. a larger disk. Copies all data files (chunked, memory-safe), writes a data_dir bootstrap into the original config so future starts automatically use the new disk, and switches the current session paths immediately. Use when the current disk is full/small and another writable mount exists. Verify the target with list_storage first.",
    parameters={type="object", properties={path={type="string", description="Target directory on the destination filesystem, e.g. /mnt/abcd (must be writable)"}}, required={"path"}}
  }},
}

-- 字节数 → 可读格式
local function fmt_bytes(n)
  if not n or type(n) ~= "number" then return "?" end
  if n >= 1048576 then return string.format("%.1fMB", n / 1048576) end
  if n >= 1024 then return string.format("%.1fKB", n / 1024) end
  return n .. "B"
end

-- 文件大小（标准库 io.open+seek；OpenOS filesystem 库无 size 函数）
local function file_size(path)
  local f = io.open(path, "r")
  if not f then return 0 end
  local sz = f:seek("end") or 0
  f:close()
  return sz
end

-- 目录总大小（递归，只统计文件）
local function dir_size(path)
  local fs = require("filesystem")
  local ok, it = pcall(fs.list, path)
  if not ok or type(it) ~= "function" then return 0 end
  local total = 0
  for entry in it do
    local p = path .. "/" .. entry
    local ok_isdir, isdir = pcall(fs.isDirectory, p)
    if ok_isdir and isdir then
      total = total + dir_size(p)
    else
      total = total + file_size(p)
    end
  end
  return total
end

-- list_storage: 各挂载盘容量 + agent 数据占用
local function list_storage_code(deps)
  local fs = require("filesystem")
  local lines = {}
  -- 各挂载盘（df.lua 同款组件 API: proxy.spaceTotal()/spaceUsed()）
  local ok_m, iter = pcall(fs.mounts)
  if not ok_m or type(iter) ~= "function" then
    return "Error: fs.mounts unavailable"
  end
  for proxy, path in iter do
    local label = "(no label)"
    local ok_l, l = pcall(function() return proxy.getLabel() end)
    if ok_l and l then label = l end
    local ok_t, total = pcall(function() return proxy.spaceTotal() end)
    local ok_u, used = pcall(function() return proxy.spaceUsed() end)
    local avail = "?"
    if ok_t and ok_u and type(total) == "number" and type(used) == "number" then
      if total == math.huge then
        avail = "unlimited"
      else
        avail = fmt_bytes(total - used)
      end
    end
    lines[#lines + 1] = path .. "  (" .. label .. ")  used=" .. fmt_bytes(ok_u and used or "?")
      .. "  free=" .. avail
  end
  -- agent 数据占用
  local wb = deps.get_writable_base and deps.get_writable_base() or "/home"
  local cfg_size = file_size(wb .. "/agent_config.txt")
  local hist_size = 0
  if deps.session and deps.session.current_path then
    hist_size = file_size(deps.session.current_path())
  end
  local sessions_size = 0
  if deps.session and deps.session.get_sessions_dir then
    sessions_size = dir_size(deps.session.get_sessions_dir())
  end
  lines[#lines + 1] = "agent data: config=" .. fmt_bytes(cfg_size)
    .. " history=" .. fmt_bytes(hist_size)
    .. " sessions=" .. fmt_bytes(sessions_size)
  lines[#lines + 1] = "tip: use cleanup_disk to free space, relocate_data to move data to another disk"
  return table.concat(lines, "\n")
end

-- 分块复制文件（2MB 内存约束下避免整文件读入）
local function copy_file_chunked(src, dst)
  local fi = io.open(src, "rb")
  if not fi then return nil end
  local fo = io.open(dst, "wb")
  if not fo then fi:close() return false end
  while true do
    local chunk = fi:read(4096)
    if not chunk then break end
    fo:write(chunk)
  end
  fi:close()
  fo:close()
  return true
end

-- cleanup_disk: 删旧会话 + 截断超限 history
local function cleanup_disk_code(args, deps)
  local keep = 5
  if type(args) == "table" and args.keep ~= nil then
    local n = tonumber(args.keep)
    if n and n >= 0 then keep = n end
  end
  local out = {}
  local session = deps.session
  -- 1) 旧会话清理
  if session and session.cleanup_sessions then
    local deleted, freed = session.cleanup_sessions(keep)
    out[#out + 1] = "deleted " .. deleted .. " old session file(s), freed " .. fmt_bytes(freed)
  end
  -- 2) history 截断
  if session and session.current_path then
    local hp = session.current_path()
    local hsz = file_size(hp)
    local max_file = 256000
    local ok_c, cfg = pcall(deps.load_config)
    if ok_c and cfg and cfg.mem_history_max_bytes then
      max_file = tonumber(cfg.mem_history_max_bytes) or max_file
    end
    if hsz > max_file then
      out[#out + 1] = "history " .. fmt_bytes(hsz) .. " exceeded limit " .. fmt_bytes(max_file)
        .. ", truncated to in-memory table"
      -- 截断动作: 内存表规模写回（rebuild_current 需要消息表参数，
      -- 由 DEPS.get_context 提供——与 compact_history 工具同机制）
      if deps.rebuild_current and deps.get_context then
        deps.rebuild_current(deps.get_context())
        out[#out + 1] = "history file rebuilt (truncated)"
      end
    else
      out[#out + 1] = "history " .. fmt_bytes(hsz) .. " (within " .. fmt_bytes(max_file) .. " limit)"
    end
  end
  return table.concat(out, "\n")
end

-- relocate_data: 迁移数据目录到目标盘
local function relocate_data_code(args, deps)
  local target = args and args.path
  if type(target) ~= "string" or target == "" then
    return "Error: path argument required (target directory, e.g. /mnt/abcd)"
  end
  local fs = require("filesystem")
  local session = deps.session
  local wb = deps.get_writable_base and deps.get_writable_base() or "/home"

  -- 1) 校验目标可写
  local probe = io.open(target .. "/wprobe.txt", "w")
  if not probe then
    return "Error: target not writable: " .. target .. " (use list_storage to find writable mounts)"
  end
  probe:close()
  os.remove(target .. "/wprobe.txt")

  local moved = 0
  local failed = {}
  local function copy(src, dst)
    local r = copy_file_chunked(src, dst)
    if r == false then failed[#failed + 1] = dst end
    if r ~= nil then moved = moved + 1 end
  end

  -- 2) config
  copy(wb .. "/agent_config.txt", target .. "/agent_config.txt")
  -- 3) history（当前会话 + 默认路径兜底）
  if session and session.current_path then
    local cur = session.current_path()
    copy(cur, target .. "/agent_history.txt")
    if cur ~= wb .. "/agent_history.txt" then
      copy(wb .. "/agent_history.txt", target .. "/agent_history.txt")
    end
  else
    copy(wb .. "/agent_history.txt", target .. "/agent_history.txt")
  end
  -- 4) sessions 目录（*.jsonl 会话；归档 .txt 保留原盘）
  local ok_l, it = pcall(fs.list, wb .. "/sessions")
  if ok_l and type(it) == "function" then
    for name in it do
      if name:sub(-6) == ".jsonl" then
        copy(wb .. "/sessions/" .. name, target .. "/sessions/" .. name)
      end
    end
  end
  -- 5) data_dir 引导写原盘 config
  local ok_c, cfg = pcall(deps.load_config)
  local cfg_data = ok_c and cfg or {}
  cfg_data.data_dir = target
  local ok_s, err_s = pcall(deps.save_config, cfg_data)
  if not ok_s then
    failed[#failed + 1] = "data_dir bootstrap: " .. tostring(err_s)
  end
  -- 6) 本进程内立即切换
  if session then
    if session.set_paths then session.set_paths(target .. "/agent_history.txt") end
    if session.set_sessions_dir then session.set_sessions_dir(target .. "/sessions") end
  end

  local out = "migrated " .. moved .. " file(s) to " .. target
    .. ", data_dir bootstrap written to original config"
  if #failed > 0 then
    out = out .. "; FAILED: " .. table.concat(failed, ", ")
  end
  out = out .. ". Current session paths switched immediately; after restart the data_dir bootstrap makes all paths land on the new disk."
  return out
end

local function exec(name, args, deps)
  if name == "list_storage" then
    local ok, result = pcall(list_storage_code, deps)
    return ok and result or ("Error: " .. tostring(result))

  elseif name == "cleanup_disk" then
    local ok, result = pcall(cleanup_disk_code, args, deps)
    return ok and result or ("Error: " .. tostring(result))

  elseif name == "relocate_data" then
    local ok, result = pcall(relocate_data_code, args, deps)
    return ok and result or ("Error: " .. tostring(result))
  end

  return nil  -- not handled by this module
end

return {tools = tools, exec = exec}
