-- ═══════════════════════════════════════════════════════════════
-- OC Agent 安装脚本（小型引导程序）
-- 用法（任选其一，游戏内 OpenOS shell 执行）：
--   1) wget 下载:   wget https://raw.githubusercontent.com/xs4444/oc-agent/main/install.lua install.lua
--   2) 或 jsDelivr: wget https://cdn.jsdelivr.net/gh/xs4444/oc-agent@main/install.lua install.lua
--   然后:           lua install.lua
--
-- 功能:
--   * 从 GitHub（或 jsDelivr CDN 备选）下载 agent.lua 到当前目录
--   * 校验文件大小（应约 70KB）与首行内容
--   * 可选: 写子代理配置文件（subagent = true）
--   * 提示下一步
-- ═══════════════════════════════════════════════════════════════

local SOURCES = {
  "https://raw.githubusercontent.com/xs4444/oc-agent/main/agent.lua",
  "https://cdn.jsdelivr.net/gh/xs4444/oc-agent@main/agent.lua",
}
local EXPECTED_MIN = 60000  -- agent.lua 应至少 60KB
local DEST = "agent.lua"

local function fetch(url, dest)
  local internet = require("internet")
  local ok, handle = pcall(function()
    return internet.request(url)
  end)
  if not ok then return nil, "connection failed: " .. tostring(handle) end

  local chunks = {}
  local iter_ok, iter_err = pcall(function()
    for chunk in handle do
      chunks[#chunks + 1] = chunk
      os.sleep(0.02)  -- yield: avoid "too long without yielding"
    end
  end)
  if not iter_ok then return nil, "read failed: " .. tostring(iter_err) end
  local body = table.concat(chunks)
  if #body == 0 then return nil, "empty response" end
  -- strip trailing newline from OpenOS wget-style save
  local f = io.open(dest, "w")
  if not f then return nil, "cannot open " .. dest .. " for writing" end
  f:write(body)
  f:close()
  return body
end

print("OC Agent 安装器")
print("===============")

local body, err
for i, url in ipairs(SOURCES) do
  print("尝试源 " .. i .. "/" .. #SOURCES .. ": " .. url)
  body, err = fetch(url, DEST)
  if body then
    print("  下载成功: " .. #body .. " 字节")
    break
  end
  print("  失败: " .. tostring(err))
end

if not body then
  print("所有下载源均失败。请检查互联网卡，或手动安装 agent.lua。")
  return
end

-- 校验
if #body < EXPECTED_MIN then
  print("警告: 文件偏小 (" .. #body .. " 字节)，可能下载不完整")
end
local first_line = body:match("^([^\n]*)")
if first_line:find("OC Agent") or body:find("json%.encode") then
  print("校验通过: 文件内容符合 agent.lua 预期")
else
  print("警告: 文件内容与预期不符，请人工检查")
end

-- 是否配置为子代理
print("")
io.write("将此机器配置为子代理 (监听模式)? [y/N]: ")
local answer = io.read() or ""
if answer:gsub("%s", ""):lower() == "y" then
  local ser = require("serialization")
  local fs = require("filesystem")
  -- 找到可写目录（/home 只读时用挂载盘）
  local function writable_base()
    local f = io.open("/home/agent_write_probe.txt", "w")
    if f then f:close(); os.remove("/home/agent_write_probe.txt"); return "/home" end
    for _, mount in fs.mounts() do
      if mount and mount ~= "/" then
        local p2 = io.open(mount .. "/agent_write_probe.txt", "w")
        if p2 then p2:close(); os.remove(mount .. "/agent_write_probe.txt"); return mount end
      end
    end
    return "/home"
  end
  local base = writable_base()
  local cfg_path = base .. "/agent_config.txt"
  local cfg = {api_key = "", model = "deepseek-v4-flash-free", api_url = "https://opencode.ai/zen/v1/chat/completions", subagent = true}
  local f = io.open(cfg_path, "w")
  if f then
    f:write(ser.serialize(cfg))
    f:close()
    print("子代理配置已写入 " .. cfg_path)
  else
    print("无法写入配置文件: " .. cfg_path)
  end
end

print("")
print("安装完成！")
print("  启动方式:")
print("    主代理:   lua " .. DEST)
print("    子代理:   lua " .. DEST .. " -- --subagent   (或已配置 subagent=true 时直接 lua " .. DEST .. ")")
print("  更新方式:  重新运行本脚本即可覆盖为最新版")
