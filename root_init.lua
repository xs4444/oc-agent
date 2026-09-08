-- ============================================================================
-- root_init.lua — 真机根盘的 /init.lua（OpenOS 开机引导脚本）
--
-- 部署位置: 真机根盘 /init.lua（4MB 安装盘，/mnt/32d 为其双挂载）。
--           不是 agent 树（/mnt/bb7/agent/）的一部分，update.lua 不管理它；
--           改动需经远控 lua op 上传（见 AGENTS.md「真机部署同步」）。
-- 备份:     真机上 /init.lua.bak（系统原版 817B）、/init.lua.bak2（v0.3.126
--           自启动无日志版 1416B）。本文件 = 当前部署版（dofile + boot log）。
--
-- 职责:
--   1. 加载 /lib/core/boot.lua 完成 OpenOS 系统初始化（mount/boot 脚本/runlevel）。
--   2. 写一条开机日志到 /mnt/bb7/boot_log.txt（重启诊断用；append，不截断）。
--   3. dofile("/mnt/bb7/agent/agent.lua") 自动拉起 agent（远控重启闭环）。
--      agent 正常退出 -> 回落交互 shell；agent 崩溃 -> 提示 + 等按键进 shell。
--
-- 关键坑（真机实证）:
--   * OpenOS 的 os.time() 返回浮点（如 203610232.8），string.format("%d") 会
--     崩「bad argument #2 to 'format' (number has no integer representation)」
--     -> 日志时间戳一律用字符串拼接 "[" .. os.time() .. "]"，勿用 %d。
--   * require("shell") 模块无顶层 run 函数（run 是 getShell() 实例的方法）->
--     自动启动用 dofile，不依赖 shell API。
--   * 本脚本顶层崩溃 = OpenOS 蓝屏「Unrecoverable Error」(GraphicsCard.scala:
--     559 背景 0x0000FF) 且无 shell 可救 -> 改动务必先 loadfile 编译校验。
-- ============================================================================
do
  local addr, invoke = computer.getBootAddress(), component.invoke
  local function loadfile(file)
    local handle = assert(invoke(addr, "open", file))
    local buffer = ""
    repeat
      local data = invoke(addr, "read", handle, math.maxinteger or math.huge)
      buffer = buffer .. (data or "")
    until not data
    invoke(addr, "close", handle)
    return load(buffer, "=" .. file, "bt", _G)
  end
  loadfile("/lib/core/boot.lua")(loadfile)
end

-- boot log to /mnt/bb7/boot_log.txt (records boot time + agent auto-start
-- outcome for reboot diagnosis). os.time() 是浮点 -> 字符串拼接，勿用 %d。
local function blog(msg)
  local f = io.open("/mnt/bb7/boot_log.txt", "a")
  if f then
    f:write("[" .. os.time() .. "] " .. msg .. "\n")
    f:close()
  end
end

blog("=== boot start (auto-start agent.lua) ===")

while true do
  local agent_ok, agent_reason = xpcall(function()
    dofile("/mnt/bb7/agent/agent.lua")
  end, function(msg)
    return tostring(msg) .. "\n" .. debug.traceback()
  end)
  if agent_ok then
    blog("agent exited cleanly -> interactive shell")
  else
    blog("agent CRASHED: " .. tostring(agent_reason):sub(1, 500))
    io.stderr:write(tostring(agent_reason) .. "\n")
    io.write("agent exited or crashed; press any key for shell\n")
    os.sleep(0.5)
    require("event").pull("key")
  end
  local result, reason = xpcall(require("shell").getShell(), function(msg)
    return tostring(msg).."\n"..debug.traceback()
  end)
  if not result then
    blog("shell error: " .. tostring(reason):sub(1,300))
    io.stderr:write((reason ~= nil and tostring(reason) or "unknown error") .. "\n")
    io.write("Press any key to continue.\n")
    os.sleep(0.5)
    require("event").pull("key")
  end
end
