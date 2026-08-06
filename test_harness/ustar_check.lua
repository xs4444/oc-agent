-- ustar_check.lua: 验证 ustar 解析器（本地，Lua 5.4）
-- 用法: ../lua_portable/bin/lua.exe ustar_check.lua
-- 读取 docs_pack/oc-docs.tar，解析，与 Python tarfile 的 269 条目对比

-- ── ustar 解析器（与 docs.lua 内嵌版一致）──
local function parse_ustar(data)
  local entries = {}
  local pos = 1
  local ndata = #data
  while pos + 512 <= ndata do
    local block = data:sub(pos, pos + 511)
    if block == string.rep("\0", 512) then
      break  -- 结束标记
    end
    pos = pos + 512
    local name = block:sub(1, 100):match("^([^%z]+)") or ""
    local size_str = block:sub(125, 136):match("(%d+)")
    local size = tonumber(size_str or "0", 8) or 0
    local typeflag = block:sub(157, 157)
    local prefix = block:sub(346, 500):match("^([^%z]+)") or ""
    local full = (prefix ~= "" and prefix .. "/" .. name) or name
    if typeflag == "0" or typeflag == "\0" then
      local content = data:sub(pos, pos + size - 1)
      entries[#entries + 1] = {path = full, content = content}
    end
    pos = pos + math.ceil(size / 512) * 512
  end
  return entries
end

local f = io.open("../docs_pack/oc-docs.tar", "rb")
if not f then print("tar not found"); os.exit(1) end
local data = f:read("*a")
f:close()
print("tar size: " .. #data .. " bytes")

local entries = parse_ustar(data)
print("parsed entries: " .. #entries)

-- 校验: 与期望一致（269 文件）
local api_robot, gtnh_oc, comp_gpu, crlf = nil, nil, nil, 0
for _, e in ipairs(entries) do
  if e.path == "api/robot.md" then api_robot = e end
  if e.path == "gtnh/open_computers.md" then gtnh_oc = e end
  if e.path == "component/gpu.md" then comp_gpu = e end
  if e.content:find("\r") then crlf = crlf + 1 end
end
print("api/robot.md: " .. tostring(api_robot ~= nil))
print("gtnh/open_computers.md: " .. tostring(gtnh_oc ~= nil))
print("component/gpu.md: " .. tostring(comp_gpu ~= nil))
print("entries with CRLF: " .. crlf)
if api_robot then
  print("robot.md head: " .. api_robot.content:sub(1, 80):gsub("\n", "|"))
end
print(entries and #entries == 269 and "CHECK: 269 OK" or "CHECK: MISMATCH")
