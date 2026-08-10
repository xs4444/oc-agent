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
-- data_dir 引导（2026-08-10 磁盘迁移功能）: 原盘 config 里若有 data_dir
-- 且该目录可写（/relocate 迁移后写入的引导项），则所有数据路径
-- （config/history/sessions）切换到目标盘。目标盘不可写（盘被拔/只读）
-- 时回退原盘——自动容错。
-- 验证（2026-08-10 ocvm）: ①m01467 首次启动 + config 含 data_dir →
--   /relocate 显示"当前数据目录: /tmp"切换生效；②独立探针复刻
--   find_writable_base+probe_data_dir 全部步骤通过（base 探测 → config
--   读取 → unserialize → 目标可写）。此前"重启后未切换"均为测试驱动
--   假象（tmux capture-pane 含屏幕历史，"Goodbye!/home #"是旧残留，
--   lua agent.lua 被旧 TUI 当聊天消息——进程从未真正重启）。
local function probe_data_dir(base)
  local fs = require("filesystem")
  local f = io.open(base .. "/agent_config.txt", "r")
  if not f then return base end
  local content = f:read("*a")
  f:close()
  local ser = require("serialization")
  local ok, d = pcall(ser.unserialize, content)
  if not ok or type(d) ~= "table" or type(d.data_dir) ~= "string" or d.data_dir == "" then
    return base
  end
  local target = d.data_dir
  if target == base then return base end
  local probe = io.open(target .. "/wprobe.txt", "w")
  if probe then
    probe:close()
    os.remove(target .. "/wprobe.txt")
    print("[relocate] 数据目录由 " .. base .. " 切换到 " .. target .. "（config.data_dir）")
    return target
  end
  return base
end
local writable_base = probe_data_dir(find_writable_base())
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
    -- 内存压力物理裁剪阈值（字节）: mem_pressure 触发时历史表裁剪到该值
    -- 以下（真机第二次 OOM 修复——折叠只缩请求体不释放内存；默认 60KB，
    -- 裁剪后 encode 峰值大幅下降，缓存前缀 miss 一次保命）
    if not data.mem_trim_bytes then data.mem_trim_bytes = 60000 end
    -- 历史加载内存上限（字节）: load_history 解析后表裁剪到该值以下
    -- （93.6KB JSONL 全量加载 → 表 ~300KB；默认 100KB 内存表，
    -- JSONL 文件 append-only 完整保留，只限内存表）
    if not data.mem_load_budget then data.mem_load_budget = 100000 end
    -- 传统自动压缩字节阈值（mem_prefold_bytes）: 表字节超此值即系统自动
    -- 折叠（opencode 传统模式——不等模型调 compact_history 工具；模型
    -- 需 ≥60% 窗口才自觉压缩，OC 内存下永远到不了）。默认 100KB，先于
    -- mem_pressure 裁剪触发（宽裕期保上下文）；折叠段物理回收后表字节
    -- 真实下降（默认 100KB < byte_budget 150KB → 自动折叠先于裁剪）。
    if not data.mem_prefold_bytes then data.mem_prefold_bytes = 100000 end
    -- 摘要请求专用输出预算（summary_max_tokens）: deepseek 强思考模型下
    -- opencode 的 4096 不够——reasoning 先吃大部分输出预算，可见摘要
    -- content 被挤掉 → 摘要残缺 → 上下文没压住 → 重复压缩。默认 16384。
    -- 摘要响应**不持久化**（只提取 content 写入摘要消息），128KB 响应体
    -- 上限（response_body_limit）已保护——与主请求 max_tokens 8192（长
    -- reasoning 进历史 → 下次请求 encode 体积暴涨 → OOM）不同场景，
    -- 专用大 max_tokens 无 OOM 风险。config 可调。
    if not data.summary_max_tokens then data.summary_max_tokens = 16384 end
    -- HTTP 重试总预算（秒）: 交互式 TUI 场景默认 300s（5 分钟）。原
    -- 3600s（1h）对端点持续故障是"无反馈挂起 1 小时"；300s 折中——
    -- 端点瞬态故障足够，超时返回最后结果让用户看到错误。需要长时间
    -- 容忍免费端点限流的用户可调大（上限不强制）。
    if not data.retry_budget then data.retry_budget = 300 end
    -- 单次请求响应读超时（秒）: 真机荒野大师 internet 迭代器可能连接
    -- 建立后流不结束（JVM 实现无 OS 超时），响应迭代无超时则无限等。
    -- 默认 120s。
    if not data.response_timeout then data.response_timeout = 120 end
    -- 单次请求响应体累积上限（字节）: 结构性内存护栏——OOM 无法预测
    -- （单次响应峰值不可知），硬上限保证任何单次峰值都落在安全线内。
    -- max_tokens 8192 的 reasoning 响应 JSON 可能 100KB+，decode 峰值
    -- 2-3x 单次就爆（真机 2MB 内存）；默认 131072（128KB）——合法响应
    -- ≈60KB 足够容纳且防爆。超限返回明确 error（不静默截断）。
    if not data.response_body_limit then data.response_body_limit = 131072 end
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
