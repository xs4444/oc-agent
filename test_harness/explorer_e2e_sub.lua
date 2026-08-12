-- explorer_e2e_sub.lua — explorer 文件代理端到端（sub 侧）
-- 用法: lua /mnt/<mount>/explorer_e2e_sub.lua /mnt/<mount>
-- 流程: 以 --subagent 模式启动 agent.lua（监听 modem 9090），处理来自
-- master 的 explorer 任务。agent.lua 的 --subagent 处理会自动执行
-- explorer 模式的工具集过滤 + 文件代理。本脚本只负责以 subagent 模式
-- 加载并保持监听（不退出，等 master 发任务）。
-- 子代理回复后写 sub_result.txt（host 侧轮询确认处理完成）
local base = ({...})[1] or "/mnt"

local out = base .. "/explorer_e2e_sub_result.txt"
local f = io.open(out, "w")
local function log(s)
  if f then f:write(s .. "\n"); f:flush() end
  print(s)
end

package.path = base .. "/?.lua;" .. (package.path or "")
-- 注意: 不设 _TEST_MODE（保持 nil/false）——agent.lua 加载时检查
-- _TEST_MODE 决定是否自动跑 main()。sub 需要 main() 以 --subagent
-- 模式自动启动（监听 modem 9090）。

-- 模拟命令行: lua agent.lua -- --subagent（v0.3.92 subagent=true config 路径）
-- agent.lua 顶层: load_config() → nil 则 first_run_setup() 阻塞等输入——
-- sub 不能卡在 First Run Setup。方案: 预写 agent_config.txt（含
-- subagent=true）到所有候选可写位置（/home + 每个 /mnt/<mount>），
-- 保证 agent.lua 的 load_config（config_path = writable_base/agent_config.txt，
-- writable_base 探测 /home 优先、fallback 首个可写挂载盘）能读到 →
-- 7105 行 `cfg.subagent` 为真 → 自动进 subagent 监听，无需 --subagent 参数。
local fs_ok, fs = pcall(require, "filesystem")
local cfg_body = '{api_key="free",model="deepseek-v4-flash-free",api_url="https://opencode.ai/zen/v1/chat/completions",subagent=true}'
local function try_write_cfg(p)
  -- 归一化: 去掉重复斜杠（"/mnt//x" → "/mnt/x"）
  p = p:gsub("/+", "/")
  local f = io.open(p, "w")
  if f then f:write(cfg_body); f:close(); log("config -> " .. p) end
end
-- 写所有可写挂载的 agent_config.txt。关键: agent.lua 的
-- find_writable_base() 取 fs.mounts() 第一个可写挂载（实测 ocvm 是 /tmp，
-- 不是 /home 也不是 /mnt/<mount>!）→ config_path = <writable_base>/agent_config.txt。
-- 必须写到 agent.lua 实际读的那个位置才能让 load_config() 成功。
try_write_cfg("/home/agent_config.txt")
try_write_cfg("/tmp/agent_config.txt")
if fs_ok and fs then
  local ok_list, it = pcall(fs.list, "/mnt")
  if ok_list and it then
    for item in it do
      try_write_cfg("/mnt/" .. item .. "/agent_config.txt")
    end
  end
  -- 兜底: 遍历 mounts 写所有可写挂载（含非 /mnt 的如 /tmp）
  if fs.mounts then
    for _, m in fs.mounts() do
      local f2 = io.open(m .. "/wprobe.txt", "w")
      if f2 then
        f2:close()
        os.remove(m .. "/wprobe.txt")
        try_write_cfg(m .. "/agent_config.txt")
      end
    end
  end
end

local chunk, lerr = loadfile(base .. "/agent.lua")
if not chunk then
  log("FATAL: agent.lua loadfile: " .. tostring(lerr))
  f:close()
  return
end
-- 不传 --subagent（config.subagent=true 触发）；chunk 顶层 vararg 留空即可
local ok_run, run_err = pcall(chunk)
if not ok_run then
  log("FATAL: agent.lua run: " .. tostring(run_err))
  f:close()
  return
end
-- main() 已由 agent.lua 自动调用（--subagent 分支，进入监听循环）
-- 该循环永不返回（除非退出）。此脚本加载后即进入监听，
-- master 发任务 → explorer 模式处理 → modem 回复。
-- 结果判定在 master 侧（收到回复即 PASS）。
-- 本脚本的 log 只确认"启动成功进入监听"。
log("subagent mode launched (listening on modem 9090)")
f:close()
