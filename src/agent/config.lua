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
    -- 运行时自动显示上下文（每次响应后一行 [ctx]），可设 false 关闭
    if data.ctx_auto == nil then data.ctx_auto = true end
    -- 内存压力压缩阈值（字节）: freeMemory() 低于此值即强制折叠早期消息
    -- （真机 OOM→error 根因修复；默认 400KB——OC 1.4MB 内存下 encode
    -- 峰值 137-230KB，真机低谷 278KB 时 encode 必超限）
    if not data.mem_compact_threshold then data.mem_compact_threshold = 400000 end
    -- HTTP 重试总预算（秒）: 交互式 TUI 场景默认 300s（5 分钟）。原
    -- 3600s（1h）对端点持续故障是"无反馈挂起 1 小时"；300s 折中——
    -- 端点瞬态故障足够，超时返回最后结果让用户看到错误。需要长时间
    -- 容忍免费端点限流的用户可调大（上限不强制）。
    if not data.retry_budget then data.retry_budget = 300 end
    -- 单次请求响应读超时（秒）: 真机荒野大师 internet 迭代器可能连接
    -- 建立后流不结束（JVM 实现无 OS 超时），响应迭代无超时则无限等。
    -- 默认 120s。
    if not data.response_timeout then data.response_timeout = 120 end
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
