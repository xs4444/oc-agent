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

-- 内存自适应缩放（2026-08-10，真机升级 4MB 后）: 全部内存类默认阈值
-- 按 totalMemory/2MB 缩放（2MB 基准调校值 × scale）——4MB 机器
-- scale=2: 阈值翻倍（更大历史/更大响应体/更晚折叠），2MB 机器
-- scale=1 行为不变；同一 agent.lua 免改配置。显式配置优先
--（load() 中 `if not data.X` 只在缺省时填缩放值）。
-- 探测失败（精简/测试环境无 totalMemory）→ scale=1 安全回退。
local function detect_mem_scale()
  local ok_c, computer = pcall(require, "computer")
  if ok_c and computer and computer.totalMemory then
    local ok_t, total = pcall(computer.totalMemory)
    if ok_t and type(total) == "number" and total > 0 then
      return total / 2097152
    end
  end
  return 1
end
local MEM_SCALE = detect_mem_scale()

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
    -- 模型上下文窗口（token）: /ctx 显示、60% 压缩引导、80% 硬保护、
    -- 请求估算的基准。**窗口是模型属性，与硬件无关，不随内存自动缩放**
    -- ——在 4MB 机器跑 256K 上下文需 /preset-256k（context_window=262144）
    --（字节类阈值已按内存 scale² 放大：4MB 下 byte_budget/prefold/
    -- load_budget=800KB，足以承载 200K tokens ≈700KB 中文历史）。
    if not data.context_window then data.context_window = 128000 end
    -- 运行时自动显示上下文（每次响应后一行 [ctx]），可设 false 关闭
    if data.ctx_auto == nil then data.ctx_auto = true end
    -- 内存压力压缩阈值（字节）: freeMemory() 低于此值即强制折叠早期消息
    -- （真机 OOM→error 根因修复；默认 400KB×scale——OC 1.4MB 内存下
    -- encode 峰值 137-230KB，真机低谷 278KB 时 encode 必超限；4MB
    -- 机器 800KB，内存充裕时更晚触发）
    if not data.mem_compact_threshold then
      data.mem_compact_threshold = math.floor(400000 * MEM_SCALE)
    end
    -- 内存压力物理裁剪阈值（字节）: mem_pressure 触发时历史表裁剪到该值
    -- 以下（真机第二次 OOM 修复——折叠只缩请求体不释放内存；默认
    -- 60KB×scale，裁剪后 encode 峰值大幅下降，缓存前缀 miss 一次保命）
    if not data.mem_trim_bytes then
      data.mem_trim_bytes = math.floor(60000 * MEM_SCALE)
    end
    -- 历史加载内存上限（字节）: load_history 解析后表裁剪到该值以下
    -- （93.6KB JSONL 全量加载 → 表 ~300KB；默认 200KB×scale²——4MB
    -- 机器 800KB：足以装载 200K tokens 中文历史（≈700KB）进内存表；
    -- JSONL 文件 append-only 完整保留，只限内存表）
    if not data.mem_load_budget then
      data.mem_load_budget = math.floor(200000 * MEM_SCALE * MEM_SCALE)
    end
    -- 传统自动压缩字节阈值（mem_prefold_bytes）: 表字节超此值即系统自动
    -- 折叠（opencode 传统模式——不等模型调 compact_history 工具；模型
    -- 需 ≥60% 窗口才自觉压缩，OC 内存下永远到不了）。默认 200KB×scale²
    --（2026-08-10: 内存翻倍 → 可承载请求体 4 倍——4MB 机器 800KB 才
    -- 折叠，配合 /preset-256k（262144）中文长史可跑至 ~230K tokens；
    -- 2MB 机器 scale=1 时 200KB 略高于旧 100KB——2MB 下编码峰值
    -- 137-230KB 实测仍安全，且 byte_budget 兜底裁剪），先于 mem_pressure
    -- 裁剪触发（宽裕期保上下文）；折叠段物理回收后表字节真实下降。
    if not data.mem_prefold_bytes then
      data.mem_prefold_bytes = math.floor(200000 * MEM_SCALE * MEM_SCALE)
    end
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
    -- 2-3x 单次就爆（真机 2MB 内存）；默认 131072×scale（2MB=128KB，
    -- 4MB=256KB）——合法响应 ≈60KB 足够容纳且防爆。超限返回明确 error
    -- （不静默截断）。
    if not data.response_body_limit then
      data.response_body_limit = math.floor(131072 * MEM_SCALE)
    end
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

-- v0.3.125r6: setup merge（实证坑 r5）: boot 时 writable base 漂移
-- （fs.mounts() 顺序不稳/每 boot 新盘目录）使已存在的 config "找不到"
-- → 旧 first_run 无条件只写 3 字段 → mem_exec_min_free/remote_url/
-- remote_token 全丢（护栏回默认 + 远控守护不自启 + /remote on 拒）。
-- 对策: 全盘查一份现存可解析 config，其字段全部继承；3 个 setup 字段
-- 仅被非空答案覆盖。
local function find_existing_config()
  local ok_fs, fs = pcall(require, "filesystem")
  local ser = require("serialization")
  local seen = {}
  local candidates = {"/home", writable_base}
  if ok_fs and type(fs.mounts) == "function" then
    local ok_m, mounts = pcall(fs.mounts)
    if ok_m then
      for _, mount in mounts do
        if type(mount) == "string" and mount ~= "/" then
          candidates[#candidates + 1] = mount
        end
      end
    end
  end
  for _, base in ipairs(candidates) do
    if not seen[base] then
      seen[base] = true
      local f = io.open(base .. "/agent_config.txt", "r")
      if f then
        local content = f:read("*a")
        f:close()
        local ok, data = pcall(ser.unserialize, content)
        if ok and type(data) == "table" and next(data) ~= nil then
          return data
        end
      end
    end
  end
  return nil
end

-- 3 字段合并规则: 非空答案胜出; 空答案继承旧值; 无旧值走默认。
-- 其余字段（mem_exec_min_free/remote_url/remote_token/data_dir/…）
-- 原样继承。纯函数——first_run 调用，单测直接打。
local function merge_setup(prev, api_key, model, api_url)
  local config = {}
  if type(prev) == "table" then
    for k, v in pairs(prev) do config[k] = v end
  end
  if type(api_key) == "string" and api_key ~= "" then
    config.api_key = api_key
  end
  if type(config.api_key) ~= "string" then config.api_key = "" end
  -- v0.3.x: 默认不提供模型/端点（避免硬编码某免费端点过时）。空答案且无旧值
  -- 则留空——用户须经 /model /url 或首次 setup 显式提供 OpenAI 兼容端点。
  if type(model) == "string" and model ~= "" then config.model = model end
  if type(config.model) ~= "string" then config.model = "" end
  if type(api_url) == "string" and api_url ~= "" then
    config.api_url = api_url
  end
  if type(config.api_url) ~= "string" then config.api_url = "" end
  return config
end

local function first_run()
  print("OC Agent - First Run Setup")
  io.write("API Key (any OpenAI-compatible key, or empty): ")
  local api_key = io.read():gsub("\n", "")
  io.write("Model (OpenAI-compatible model name): ")
  local model = io.read():gsub("\n", "")
  io.write("API URL (OpenAI-compatible /chat/completions endpoint): ")
  local api_url = io.read():gsub("\n", "")
  -- v0.3.125r6: 继承现存配置（此前无条件 3 字段覆盖——实证坑 r5）
  local prev = find_existing_config()
  if prev then
    print("Found existing config — merging (existing fields preserved)")
  end
  local config = merge_setup(prev, api_key, model, api_url)
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
  -- 内存自适应缩放系数（totalMemory/2MB）: session.lua/init.lua 硬常量
  -- 同步缩放（MAX_HISTORY/MAX_HISTORY_BYTES/MAX_LOAD_HISTORY 等）
  mem_scale = MEM_SCALE,
  -- v0.3.125r6: 测试钩子（_TEST_MODE 才暴露）
  _internal = _TEST_MODE and {
    find_existing_config = find_existing_config,
    merge_setup = merge_setup,
  } or nil,
}
