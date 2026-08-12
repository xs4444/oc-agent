-- probe_base.lua — 决定性: 检查 agent.lua 的 find_writable_base 会选哪个目录
local fs = require("filesystem")
local f = io.open("/home/agent_write_probe.txt", "w")
if f then
  f:close()
  os.remove("/home/agent_write_probe.txt")
  print("HOME_WRITABLE")
else
  print("HOME_READONLY")
end
for _, m in fs.mounts() do
  print("MOUNT: " .. tostring(m))
  local w = io.open(m .. "/wprobe.txt", "w")
  if w then
    w:close()
    os.remove(m .. "/wprobe.txt")
    print("  WRITABLE")
  else
    print("  RO")
  end
end
print("done")
