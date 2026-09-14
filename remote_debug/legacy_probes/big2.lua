-- 累积拼接方式传大文件：/tmp 里始终只有 accum + cur 两个文件
-- 样板层已由 tools/retrofit_v5_scripts.py 替换 (2026-09-15):
-- v5 直连 modem(端口 8001) 已退役; 现经 /home/v5shim.lua 走 v6(8100)。
-- 业务逻辑(cmd(...) 调用)保持原样, 返回值仍是 "ok|..."/"err|..."。
local cmd = dofile("/home/v5shim.lua")

local log = io.open("/home/big2.out", "w")
local function lg(s) log:write(s .. "\n"); log:flush() end


-- 远端累积脚本（写到 /home，避开 /tmp）
local accum_script = [[
local fh = io.open("/home/asm_args", "r")
if not fh then print("ERR: no asm_args") return end
local target = fh:read("*l")
local is_last = fh:read("*l") == "1"
fh:close()
local ok, err = pcall(function()
  local accum = ""
  local af = io.open("/home/accum", "rb")
  if af then accum = af:read("*a") af:close() end
  local cf = io.open("/home/cur", "rb")
  if not cf then error("no cur") end
  local cur = cf:read("*a")
  cf:close()
  local new_accum = accum .. cur
  if is_last then
    local e = new_accum
    e = e:gsub("\\|", "\001")
    e = e:gsub("\\\\", "\\")
    e = e:gsub("\001", "|")
    local serialization = require("serialization")
    local content = serialization.unserialize(e)
    local out = io.open(target, "wb")
    if not out then error("CANNOT_OPEN " .. target) end
    out:write(content)
    out:close()
    os.remove("/home/accum")
    os.remove("/home/cur")
    print("OK " .. #content .. " bytes -> " .. target)
  else
    local out = io.open("/home/accum", "wb")
    if not out then error("CANNOT_OPEN accum") end
    out:write(new_accum)
    out:close()
    os.remove("/home/cur")
    print("ACCUM " .. #new_accum)
  end
end)
if not ok then print("ERR: " .. tostring(err)) end
]]
local enc_asm = serialization.serialize(accum_script):gsub("\\", "\\\\"):gsub("|", "\\|")
local r_asm = cmd("write|/home/accum.lua|" .. enc_asm)
lg("WRITE accum.lua: " .. tostring(r_asm))

-- 清理远端 /home 残留
cmd("exec|rm -f /home/accum /home/cur /home/asm_args")

local files = {
  {"/home/beemaster/mutations.lua", "mutations.lua"},
  {"/home/beemaster/strategy.lua", "strategy.lua"},
}
local REMOTE_DIR = "/home/beemaster"
local CHUNK_SIZE = 3500
local ok_count, fail_count = 0, 0

for _, f in ipairs(files) do
  local local_path, remote_rel = f[1], f[2]
  local remote_path = REMOTE_DIR .. "/" .. remote_rel

  local fh = io.open(local_path, "rb")
  if not fh then
    lg("FAIL read " .. local_path .. ": not found")
    fail_count = fail_count + 1
    goto continue
  end
  local content = fh:read("*a")
  fh:close()

  local enc = serialization.serialize(content)
  enc = enc:gsub("\\", "\\\\"):gsub("|", "\\|")

  local chunks = {}
  local pos = 1
  while pos <= #enc do
    chunks[#chunks + 1] = enc:sub(pos, pos + CHUNK_SIZE - 1)
    pos = pos + CHUNK_SIZE
  end
  local nchunks = #chunks
  lg("=== " .. remote_rel .. " " .. #content .. " bytes, " .. nchunks .. " chunks ===")

  -- 清空累积
  cmd("exec|rm -f /home/accum /home/cur")

  local all_ok = true
  for i, chunk in ipairs(chunks) do
    local idx = i - 1
    local is_last = (i == nchunks) and "1" or "0"
    local args = remote_path .. "\n" .. is_last .. "\n"
    local eargs = serialization.serialize(args):gsub("\\", "\\\\"):gsub("|", "\\|")
    cmd("write|/home/asm_args|" .. eargs)
    local enc_chunk = serialization.serialize(chunk):gsub("\\", "\\\\"):gsub("|", "\\|")
    local r = cmd("write|/home/cur|" .. enc_chunk)
    if not r or not r:find("^ok|") then
      lg("FAIL write cur #" .. idx .. ": " .. tostring(r))
      all_ok = false
      break
    end
    local r_exec = cmd("exec|lua /home/accum.lua", 30)
    if is_last then
      if r_exec and r_exec:find("^ok|OK ") then
        lg("OK " .. remote_rel .. " (" .. #content .. " bytes)")
        ok_count = ok_count + 1
      else
        lg("FAIL exec " .. remote_rel .. ": " .. tostring(r_exec))
        fail_count = fail_count + 1
      end
    else
      if not r_exec or not r_exec:find("^ok|ACCUM") then
        lg("FAIL accum #" .. idx .. ": " .. tostring(r_exec))
        all_ok = false
        break
      end
    end
  end

  if not all_ok then fail_count = fail_count + 1 end
  ::continue::
end

lg(string.format("BIG DONE: %d ok, %d fail", ok_count, fail_count))
log:close()
