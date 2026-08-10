-- base_probe.lua: 探明 ocvm 中 config.lua find_writable_base 的实际行为
-- 用法: lua /mnt/<short>/base_probe.lua /mnt/<short>
local base = ({...})[1] or "/mnt"
local RESULT = "base_probe_result.txt"
local function log(...)
  local parts = {}
  for i = 1, select("#", ...) do parts[i] = tostring(select(i, ...)) end
  local line = table.concat(parts, " ")
  print(line)
  local fs_ok, fs = pcall(require, "filesystem")
  if fs_ok and fs.list then
    for item in fs.list("/mnt") do
      local f = io.open("/mnt/" .. item .. "/" .. RESULT, "a")
      if f then f:write(line .. "\n") f:close() end
    end
  end
end
io.open(base .. "/" .. RESULT, "w"):close()

log("[probe] start")
log("[probe] _VERSION=" .. _VERSION)
local ok, fs = pcall(require, "filesystem")
log("[probe] fs require ok=" .. tostring(ok) .. (ok and "" or " err=" .. tostring(fs)))

-- 1) mounts() 迭代: proxy 与 path 分别是什么
local count = 0
local okm, err = pcall(function()
  for proxy, path in fs.mounts() do
    count = count + 1
    log("[probe] mount " .. count .. ": proxy_type=" .. type(proxy)
      .. " proxy_tostring=" .. tostring(proxy) .. " path=" .. tostring(path))
  end
end)
log("[probe] mounts loop ok=" .. tostring(okm) .. " count=" .. count
  .. (okm and "" or " err=" .. tostring(err)))

-- 2) /home 可写?
local f = io.open("/home/agent_write_probe.txt", "w")
if f then
  f:close(); os.remove("/home/agent_write_probe.txt")
  log("[probe] /home WRITABLE")
else
  log("[probe] /home readonly")
end

-- 3) 复刻 find_writable_base: 用 proxy 拼接路径（预期报错?）
local function replica_proxy()
  for _, mount in fs.mounts() do
    if mount and mount ~= "/" then
      local probe = mount .. "/agent_write_probe.txt"
      local f2 = io.open(probe, "w")
      if f2 then f2:close(); os.remove(probe); return mount end
    end
  end
  return "/home"
end
local okp, res = pcall(replica_proxy)
log("[probe] replica(proxy concat) ok=" .. tostring(okp)
  .. (okp and (" base=" .. tostring(res)) or " err=" .. tostring(res)))

-- 4) 正确实现: 用 path 拼接
local function replica_path()
  for _, path in fs.mounts() do
    if path and path ~= "/" then
      local probe = path .. "/agent_write_probe.txt"
      local f2 = io.open(probe, "w")
      if f2 then f2:close(); os.remove(probe); return path end
    end
  end
  return "/home"
end
local okr, res2 = pcall(replica_path)
log("[probe] replica(path concat) ok=" .. tostring(okr)
  .. (okr and (" base=" .. tostring(res2)) or " err=" .. tostring(res2)))

-- 5) 显式路径: /mnt/<短名>/agent_config.txt 存在性
for item in fs.list("/mnt") do
  local full = "/mnt/" .. item
  local has_cfg = fs.exists(full .. "/agent_config.txt")
  log("[probe] /mnt/" .. item .. " has agent_config.txt=" .. tostring(has_cfg))
end

log("[probe] done")
