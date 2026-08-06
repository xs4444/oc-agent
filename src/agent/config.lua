-- ═══════════════════════════════════════════════════════════════
-- agent.config — configuration + writable-base detection (Phase 2
-- split).
--
-- Verbatim move of the old agent.lua Section 6 config parts:
-- find_writable_base / load_config / save_config / first_run_setup.
-- find_writable_base() runs ONCE at module load (top-level side
-- effect, same order as the old single-file Section 6) and the
-- resolved paths are exported for agent.lua (and tests).
--
-- Depends on require("filesystem").
-- ═══════════════════════════════════════════════════════════════

-- Paths. If /home is not writable (OpenOS not installed to a writeable
-- medium), fall back to the first writable mount (tmpfs/hdd).
local function find_writable_base()
  local fs = require("filesystem")
  -- probe /home first
  local f = io.open("/home/agent_write_probe.txt", "w")
  if f then f:close(); os.remove("/home/agent_write_probe.txt"); return "/home" end
  -- iterate mounts: iterator yields (proxy, mount_path)
  for _, mount in fs.mounts() do
    if mount and mount ~= "/" then
      local probe = mount .. "/agent_write_probe.txt"
      local f2 = io.open(probe, "w")
      if f2 then
        f2:close()
        os.remove(probe)
        return mount
      end
    end
  end
  return "/home"  -- give up; callers will handle write errors
end

-- Top-level side effect (module load time): probe the writable base once.
local writable_base = find_writable_base()
local config_path = writable_base .. "/agent_config.txt"
local history_path = writable_base .. "/agent_history.txt"
local sessions_dir = writable_base .. "/sessions"

local function load()
  local fs = require("filesystem")
  if not fs.exists(config_path) then return nil end
  local f = io.open(config_path, "r")
  if not f then return nil end
  local content = f:read("*a")
  f:close()
  local ser = require("serialization")
  local ok, data = pcall(ser.unserialize, content)
  if ok and type(data) == "table" then
    -- 默认值（/ctx 上下文显示用；模型窗口按实际配置）
    if not data.context_window then data.context_window = 128000 end
    return data
  end
  return nil
end

local function save(config)
  local ser = require("serialization")
  local f = io.open(config_path, "w")
  if not f then error("cannot save config") end
  f:write(ser.serialize(config))
  f:close()
end

local function first_run()
  print("OC Agent - First Run Setup")
  io.write("API Key (empty for free OpenCode Zen model, or any OpenAI-compatible key): ")
  local api_key = io.read():gsub("\n", "")
  io.write("Model [deepseek-v4-flash-free]: ")
  local model = io.read():gsub("\n", "")
  if model == "" then model = "deepseek-v4-flash-free" end
  io.write("API URL [https://opencode.ai/zen/v1/chat/completions]: ")
  local api_url = io.read():gsub("\n", "")
  if api_url == "" then api_url = "https://opencode.ai/zen/v1/chat/completions" end

  local config = {api_key = api_key, model = model, api_url = api_url}
  save(config)
  print("Configuration saved to " .. config_path)
  return config
end

return {
  load = load,
  save = save,
  first_run = first_run,
  writable_base = writable_base,
  config_path = config_path,
  history_path = history_path,
  sessions_dir = sessions_dir,
}
