-- update.lua — 一键更新 agent（永不需要更新此文件）
-- 用法: lua update.lua
-- 行为: 下载最新 install.lua 并自动执行

local internet = require("internet")

local URL = "https://cdn.jsdelivr.net/gh/xs4444/oc-agent@master/install.lua"

print("下载最新安装器...")
local ok, handle = pcall(internet.request, URL)
if not ok or not handle then
  print("下载失败，请检查网络")
  return
end

local chunks = {}
for chunk in handle do
  chunks[#chunks + 1] = chunk
  os.sleep(0.02)
end
local code = table.concat(chunks)
if #code < 100 then
  print("安装器下载异常（" .. #code .. " 字节），可能是 CDN 缓存延迟")
  return
end

local f = io.open("install.lua", "w")
f:write(code)
f:close()
print("安装器已更新（" .. #code .. " 字节），开始安装...")
print("")

-- 执行下载的安装器
dofile("install.lua")
