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

-- Recursively list *.lua files under dir, returning relpaths (forward
-- slashes) prefixed with `prefix`. Uses Windows `dir /B` (files) and
-- `dir /B /AD` (subdirectories); falls back to an explicit two-level
-- walk if popen is unavailable.
local function scan_lua_files(dir, prefix)
  local out = {}
  local ok, p = pcall(io.popen, 'dir /B "' .. dir .. '"')
  if ok and p then
    local listing = p:read("*a")
    p:close()
    for entry in listing:gmatch("[^\r\n]+") do
      if entry:match("%.lua$") then
        out[#out + 1] = prefix .. entry
      end
    end
  else
    -- fallback: explicit known layout (src/agent/*.lua + src/agent/tools/*.lua)
    for _, name in ipairs({ "init", "json", "http", "config", "session",
                            "tools", "execute", "chat", "subagent" }) do
      out[#out + 1] = prefix .. name .. ".lua"
    end
    for _, name in ipairs({ "file", "data", "component", "search",
                            "shell", "subagent" }) do
      out[#out + 1] = prefix .. "tools/" .. name .. ".lua"
    end
  end
  local okd, pd = pcall(io.popen, 'dir /B /AD "' .. dir .. '"')
  if okd and pd then
    local sub = pd:read("*a")
    pd:close()
    for entry in sub:gmatch("[^\r\n]+") do
      if entry ~= "." and entry ~= ".." then
        local nested = scan_lua_files(dir .. "/" .. entry, prefix .. entry .. "/")
        for _, f in ipairs(nested) do
          out[#out + 1] = f
        end
      end
    end
  end
  return out
end

local relpaths = scan_lua_files(SRC, "")
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
