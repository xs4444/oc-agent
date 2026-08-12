-- probe_mounts2.lua — 打印 fs.mounts() 输出 + 每个挂载可写性
local fs = require("filesystem")
for _, m in fs.mounts() do
  local mark = "RO"
  local f = io.open(m .. "/wprobe.txt", "w")
  if f then
    f:close()
    os.remove(m .. "/wprobe.txt")
    mark = "W"
  end
  print("MOUNT: " .. tostring(m) .. " [" .. mark .. "]")
end
print("done")
