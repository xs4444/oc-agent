-- ═══════════════════════════════════════════════════════════════
-- scripts/make_manifest.lua — multi-file install manifest generator
-- (Phase 3b).
--
-- Usage (from the repo root):
--   lua_portable/bin/lua.exe scripts/make_manifest.lua
--
-- Scans src/agent/ recursively (including tools/) for every .lua file
-- and writes files.json at the repo root:
--   { "files": { "init.lua": <bytes>, "json.lua": <bytes>,
--                ..., "tools/file.lua": <bytes> }, "version": "YYYY-MM-DD" }
--
-- Byte counts are computed on LF-normalized content (what GitHub raw
-- serves after git line-ending normalization), so install.lua's size
-- check matches the downloaded bytes. Every source file is syntax
-- checked with load() before the manifest is written.
--
-- Push order: run make_manifest.lua, then commit files.json together
-- with the src/agent/ changes.
-- ═══════════════════════════════════════════════════════════════

local script_dir = debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]+$") or "."
local ROOT = script_dir .. "/.."
local SRC = ROOT .. "/src/agent"

local VERSION = os.date("%Y-%m-%dT%H%M")

local function lf_normalize(content)
  return (content:gsub("\r\n", "\n"):gsub("\r", "\n"))
end

local function read_file(path)
  local f = assert(io.open(path, "rb"), "cannot open " .. path)
  local content = f:read("*a")
  f:close()
  return content
end

-- Recursively list *.lua files under root, returning relpaths (forward
-- slashes). Cross-platform (2026-09-03: 项目迁移到 Linux 主机后原
-- `dir /B` 不可用)——优先 Unix `find`，回退 Windows `dir /S /B`。
local function scan_lua_files(root)
  -- 依次尝试各命令，取第一个产出匹配者（Windows 有 find.exe 但语义不同，
  -- 会空输出，故不能只看 popen 是否成功）。
  for _, cmd in ipairs({
    'find "' .. root .. '" -type f -name "*.lua"',
    'dir /S /B "' .. root .. '*.lua"',
  }) do
    local ok, p = pcall(io.popen, cmd)
    if ok and p then
      local out = {}
      for line in p:lines() do
        local rel = line:sub(#root + 2):gsub("\\", "/")
        if rel:match("%.lua$") then out[#out + 1] = rel end
      end
      p:close()
      if #out > 0 then return out end
    end
  end
  return {}
end

local relpaths = scan_lua_files(SRC)
table.sort(relpaths)

if #relpaths == 0 then
  print("NO .lua files found under " .. SRC .. " — aborting.")
  os.exit(1)
end

-- Read + LF-normalize + syntax-check every module, collecting sizes.
local entries = {}
local total = 0
for _, rel in ipairs(relpaths) do
  local content = lf_normalize(read_file(SRC .. "/" .. rel))
  local chunk, err = load(content, "@" .. rel)
  if not chunk then
    print("SYNTAX ERROR in src/agent/" .. rel .. ":")
    print(tostring(err))
    os.exit(1)
  end
  entries[#entries + 1] = { rel = rel, bytes = #content }
  total = total + #content
end

-- 根目录分发文件（install.lua 以 "/" 前缀下载，装到 agent 目录）
for _, extra in ipairs({ "docs.lua" }) do
  local content = lf_normalize(read_file(ROOT .. "/" .. extra))
  local chunk, err = load(content, "@" .. extra)
  if not chunk then
    print("SYNTAX ERROR in " .. extra .. ":")
    print(tostring(err))
    os.exit(1)
  end
  entries[#entries + 1] = { rel = extra, bytes = #content }
  total = total + #content
end

-- Build the JSON by hand (deterministic order for clean diffs).
local out = {
  "{",
  "  \"files\": {",
}
for i, e in ipairs(entries) do
  out[#out + 1] = '    "' .. e.rel .. '": ' .. e.bytes .. (i < #entries and "," or "")
end
out[#out + 1] = "  },"
out[#out + 1] = '  "version": "' .. VERSION .. '"'
out[#out + 1] = "}"
local json = table.concat(out, "\n") .. "\n"

local target = ROOT .. "/files.json"
local f = assert(io.open(target, "wb"), "cannot write " .. target)
f:write(json)
f:close()

print("Wrote " .. target .. ":")
print("  " .. #entries .. " files, " .. total .. " bytes total, version " .. VERSION)
print("  bytes normalized to LF (matches what GitHub raw serves)")
