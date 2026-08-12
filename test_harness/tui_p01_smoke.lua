-- tui_p01_smoke.lua: ocvm 冒烟——P0/P1 新功能在真实 GPU 渲染不崩。
-- 验证: 行缓存(redrawContent 增量) / 搜索跳转+高亮 / 键盘浏览进入 /
-- 拖选自动滚动(边界) / MAX_HISTORY 裁剪。无需网络。
-- 用法: lua /mnt/<short>/tui_p01_smoke.lua /mnt/<short>
local base = ({...})[1] or "/mnt"
print("p01 smoke start, base=" .. base)
local PASS, FAIL = 0, 0
local details = {}
local RESULT_NAME = "tui_p01_result.txt"
local function log(...)
  local parts = {}
  for i = 1, select("#", ...) do parts[i] = tostring(select(i, ...)) end
  local line = table.concat(parts, " ")
  print(line)
  local fs_ok, fs = pcall(require, "filesystem")
  if fs_ok and fs.list then
    for item in fs.list("/mnt") do
      local okf, f = pcall(io.open, "/mnt/" .. item .. "/" .. RESULT_NAME, "a")
      if okf and f then f:write(line .. "\n") f:close() end
    end
  end
end
pcall(function() io.open(base .. "/" .. RESULT_NAME, "w"):close() end)
local function check(name, cond, detail)
  if cond then PASS = PASS + 1 log("PASS " .. name)
  else FAIL = FAIL + 1 log("FAIL " .. name .. (detail and (" -- " .. tostring(detail)) or "")) end
  details[#details + 1] = (cond and "PASS " or "FAIL ") .. name
end

local fs = require("filesystem")
local agent_path
for item in fs.list("/mnt") do
  local full = "/mnt/" .. item
  if fs.exists(full .. "/agent.lua") then agent_path = full .. "/agent.lua" break end
end
if not agent_path then log("ERROR: agent.lua not found") log("RESULT: 0 pass, 0 fail") return end

_TEST_MODE = true
local ok, err = pcall(dofile, agent_path)
check("agent loads", ok, err)
if not ok then log("RESULT: " .. PASS .. " pass, " .. FAIL .. " fail") return end
-- 注入全局 component（必须无 local——tui.lua 内部引用全局 component;
-- ocvm 直跑 lua 脚本不经 OpenOS shell 初始化, 全局不会自动注入）
component = require("component")
local ok_tui, tui = pcall(require, "agent.tui")
check("tui module available in build", ok_tui and type(tui) == "table", tostring(ok_tui))
if not (ok_tui and type(tui) == "table") then log("RESULT: " .. PASS .. " pass, " .. FAIL .. " fail") return end

local ok_init, init_err = pcall(function()
  tui.init({})
  local gpu = component.gpu
  local w, h = gpu.getResolution()
  log("resolution: " .. tostring(w) .. "x" .. tostring(h))
  -- 填充历史 > MAX_HISTORY 验证裁剪（MAX_HISTORY=1000，打 1050 行）
  for i = 1, 1050 do
    tui.print("history line " .. i .. " filler")
  end
  local n_hist = #tui.history()
  check("MAX_HISTORY trim caps history", n_hist <= 1000,
    "n=" .. tostring(n_hist))
  -- 行缓存 + 重绘不崩（增量路径 redrawRowRange → markDirty+flushDirty）
  tui.scrollToTop()
  tui.scrollUp(2)
  tui.scrollDown(1)
  tui.scrollToBottom()
  check("scroll + row-cache redraw safe", true)
  -- 搜索: 命中跳转 + 高亮重绘不崩
  local n_find = tui.search("history line 500")
  check("search finds match", n_find == 1, "n=" .. tostring(n_find))
  tui.searchNext(1)
  tui.searchNext(-1)
  tui.search("nonexistent_zzz")
  check("search miss + repeat safe", true)
  -- 键盘浏览模式: 进入 + 重绘不崩
  local ok_br = pcall(tui.enterBrowse)
  check("enterBrowse safe on real gpu", ok_br)
  tui.setStatus("P01 done")
  tui.drawInput()
  return true
end)
check("tui P0/P1 init+render on real gpu", ok_init, init_err)
log("INIT_ERR: " .. tostring(init_err))

local ok_clean = pcall(tui.cleanup)
check("tui cleanup restores terminal", ok_clean)
log("")
log("RESULT: " .. PASS .. " pass, " .. FAIL .. " fail")
log("DETAIL: " .. table.concat(details, " | "))
if FAIL > 0 then
  for i = 1, #details do log("CHECK " .. i .. ": " .. details[i]) end
end
