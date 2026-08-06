-- ═══════════════════════════════════════════════════════════════
-- agent.tools — tool registry for the OC Agent (Phase 1 plugin split).
--
-- Loads every tool module under this module's own tools/ directory
-- (src/agent/tools/*.lua) and registers its declarations. Each module
-- exports {tools = {<tool decls>}, exec = function(name, args, deps)}.
--
-- Self-bootstrapping extension point: an LLM can write a new module
-- into the tools/ directory via write_file; on the next start it is
-- auto-registered here (no agent.lua edit needed).
--
-- NOTE (plugin bootstrap): writing a custom tool module to tools/ works
-- in multi-file mode; the single-file build embeds modules via
-- package.preload and cannot require new files.
--
-- Directory enumeration falls back to the builtin module list when the
-- filesystem cannot be scanned (e.g. host-side test env without a real
-- filesystem). Both paths are exercised by the test harness.
-- ═══════════════════════════════════════════════════════════════

local fs = require("filesystem")

-- name → exec function (name, args, deps)
local REGISTRY = {}
-- name → raw declaration table ({type="function", ["function"]={...}})
local DECLS = {}
-- ordered declaration list returned by list()
local ORDER = {}

-- Builtin core tool modules, always loaded (canonical order).
local BUILTIN = {
  "agent.tools.file",
  "agent.tools.data",
  "agent.tools.component",
  "agent.tools.search",
  "agent.tools.shell",
  "agent.tools.subagent",
  "agent.tools.question",
}

-- Names already loaded by the BUILTIN loop (below). scan_dir skips these
-- so the directory scan does not re-require the six core modules.
-- This is a per-instance local table, NOT package.loaded: ocvm tests
-- clear package.loaded and re-require the registry fresh, giving the
-- reload semantics we want without double-loading builtins.
local loaded_names = {}

-- Resolve this module's own directory from the loader source, never cwd.
-- Prefer AGENT_DIR exported by init.lua (entry script — its source is an
-- absolute path under OpenOS). Fall back to debug.getinfo for direct
-- require scenarios where the source lacks the "@" prefix.
local base = AGENT_DIR
if not base or base == "" then
  local src = debug.getinfo(1, "S").source or ""
  base = src:match("^@(.*)[/\\][^/\\]+$")
end
if not base or base == "" then base = "." end
local TOOLS_DIR = base .. "/tools"

local function register(name, decl, exec)
  if type(name) ~= "string" or type(decl) ~= "table" or type(exec) ~= "function" then
    return
  end
  REGISTRY[name] = exec
  if not DECLS[name] then
    DECLS[name] = decl
    ORDER[#ORDER + 1] = decl
  end
end

local function register_module(mod)
  if type(mod) ~= "table" or type(mod.exec) ~= "function" then return end
  for _, decl in ipairs(mod.tools or {}) do
    local def = decl["function"]
    local tname = def and def.name
    if tname then register(tname, decl, mod.exec) end
  end
end

local function require_module(req_name)
  local ok, mod = pcall(require, req_name)
  if ok and type(mod) == "table" then
    register_module(mod)
    return true
  end
  print("[tools] warning: failed to load module " .. tostring(req_name)
    .. ": " .. tostring(mod))
  return false
end

-- Enumerate *.lua module names in a directory, as require names.
-- Returns an ordered list; {} when enumeration fails or finds nothing.
local function collect_dir_names(dir)
  local names = {}
  local ok, it = pcall(fs.list, dir)
  if not ok or type(it) ~= "function" then return names end
  local guard = 0
  for entry in it do
    guard = guard + 1
    if guard > 1000 then break end  -- safety against runaway iterators
    if type(entry) == "string" and entry:match("%.lua$") then
      names[#names + 1] = "agent.tools." .. entry:gsub("%.lua$", "")
    end
  end
  return names
end

-- Scan a tools directory and register every module found there.
-- `names_override` lets callers (e.g. tests) supply the module file
-- names (e.g. "hello.lua", as fs.list would return) without relying on
-- a real filesystem enumeration.
-- loaded_names (populated by the BUILTIN loop) is skipped here: the six
-- core modules were already required, so the directory scan only loads
-- genuinely new/custom modules. register() dedupes on name so ORDER
-- stays stable across rescans.
local function scan_dir(dir, names_override)
  local scanned = names_override or collect_dir_names(dir)
  for _, entry in ipairs(scanned) do
    -- accept file names ("hello.lua") or full require names
    local req_name = entry
    if type(entry) == "string" and entry:match("%.lua$") and not entry:match("^agent%.") then
      req_name = "agent.tools." .. entry:gsub("%.lua$", "")
    end
    if type(req_name) == "string" and not loaded_names[req_name] then
      require_module(req_name)
      loaded_names[req_name] = true
    end
  end
end

-- Core load: builtin modules first (deterministic), then any custom
-- modules discovered by the directory scan. Builtins are recorded in
-- loaded_names so scan_dir does not re-require them; register() still
-- dedupes on name so ORDER stays stable on re-scan/reload.
for _, req_name in ipairs(BUILTIN) do
  require_module(req_name)
  loaded_names[req_name] = true
end
scan_dir(TOOLS_DIR)

return {
  list = function() return ORDER end,
  register = register,
  register_module = register_module,
  registry = function() return REGISTRY end,
  scan_dir = scan_dir,
  tools_dir = TOOLS_DIR,
}
