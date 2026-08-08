-- printhistory_test.lua: ocvm 真机验证 printHistory 完整渲染（v0.3.22 不截断）
-- 用真实存在的长文本（本机 agent.lua 自身内容 ~4.4K 行）验证:
--   1) 内容区 history 非空且渲染到真实 GPU 不崩
--   2) 去空白规范化后 == 原文（wrapText 折行不丢非空白字符）
--   3) 无 UTF-8 替换字符乱码（�）
--   4) 摘要消息 dim 显示不崩（含 [对话摘要] system）
-- 钩子版（无协程 event.pull）：直接调 printHistory + history() 读内容区，
-- 结果写结果文件不 print 屏幕（黑盒断言读屏幕字符，打印会污染）。
-- 用法: lua /mnt/<short>/printhistory_test.lua /mnt/<short>
local base = ({...})[1] or "/mnt"
local PASS, FAIL = 0, 0
local RESULT_NAME = "printhistory_test_result.txt"
local function log(...)
  local parts = {}
  for i = 1, select("#", ...) do parts[i] = tostring(select(i, ...)) end
  local line = table.concat(parts, " ")
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
end

local fs = require("filesystem")
local agent_path = fs.exists(base .. "/agent.lua") and (base .. "/agent.lua") or nil
if not agent_path then
  for item in fs.list("/mnt") do
    local full = "/mnt/" .. item
    if fs.exists(full .. "/agent.lua") then agent_path = full .. "/agent.lua" break end
  end
end
log("agent at " .. tostring(agent_path))
_TEST_MODE = true
local ok, err = pcall(dofile, agent_path)
check("agent loads", ok, err)
if not ok then log("RESULT: " .. PASS .. " pass, " .. FAIL .. " fail") return end

local ok_tui, tui = pcall(require, "agent.tui")
check("tui module available", ok_tui and type(tui) == "table", tostring(ok_tui))
if not (ok_tui and type(tui) == "table") then log("RESULT: " .. PASS .. " fail") return end

local ok_init = pcall(function() tui.init({}) end)
check("tui init on real gpu", ok_init, tostring(ok_init))
if not ok_init then log("RESULT: " .. PASS .. " pass, " .. FAIL .. " fail") return end

-- 真实语料: 本机 agent.lua 全文（真实存在，非假字符串）
local real_text = ""
do
  local f = io.open(agent_path, "r")
  if f then real_text = f:read("*a") or "" f:close() end
end
log("real corpus len: " .. tostring(#real_text))

-- 长 assistant 消息 + 摘要消息混合
local h0 = #tui.history()
local ok_ph = pcall(tui.printHistory, {
  {role = "system", content = "[对话摘要] 摘要内容（真实摘要）"},
  {role = "user", content = "真机测试问题"},
  {role = "assistant", content = real_text},
  {role = "user", content = "折叠消息", folded = true},
})
check("printHistory call safe", ok_ph, tostring(ok_ph))

local hist = tui.history()
local joined = ""
for i = h0 + 1, #hist do joined = joined .. tostring(hist[i].text or "") end
check("history has content", #joined > 0, "#=" .. tostring(#joined))
check("summary rendered", joined:find("摘要内容", 1, true) ~= nil, joined:sub(1, 80))
check("folded skipped", joined:find("折叠消息", 1, true) == nil, joined:sub(1, 120))

-- 完整显示: 去空白规范化后 real_text 是 joined 的**子串**（joined 前置了
-- 摘要+问题两条消息，全等比较恒假；且 wrapText 折行会归一化连续空白，
-- 因此以"非空白字符零丢失"为判据：real norm ⊆ joined norm）
local norm = function(s) return tostring(s):gsub("%s+", "") end
local full_kept = norm(joined):find(norm(real_text), 1, true) ~= nil
check("printHistory full content kept", full_kept,
  "real=" .. tostring(#real_text) .. " shown=" .. tostring(#joined))
-- 无 UTF-8 替换字符乱码（� = EF BF BD）
check("no replacement char", joined:find("\239\191\189") == nil, joined:sub(-30))
-- 真机渲染路径: 重绘不崩（drawHeader/drawStatus/drawInput 已由 resolution 测试覆盖，
-- 这里验证 redrawContent 对超长历史安全）
local ok_rd = pcall(tui.redrawContent)
check("redrawContent safe", ok_rd, tostring(ok_rd))
local ok_sc = pcall(tui.scrollToTop)
check("scrollToTop safe", ok_sc, tostring(ok_sc))

pcall(tui.cleanup)
log("")
log("RESULT: " .. PASS .. " pass, " .. FAIL .. " fail")
