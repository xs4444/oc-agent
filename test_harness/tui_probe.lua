-- tui_probe.lua: 最小 TUI 阻塞定位探针 v2（先加载 agent.lua）
local base = ({...})[1] or "/mnt"
print("A: start")
local fs = require("filesystem")
local agent_path = fs.exists(base .. "/agent.lua") and (base .. "/agent.lua") or nil
if not agent_path then
  for item in fs.list("/mnt") do
    local full = "/mnt/" .. item
    if fs.exists(full .. "/agent.lua") then agent_path = full .. "/agent.lua" break end
  end
end
print("A1: agent at " .. tostring(agent_path))
_TEST_MODE = true
local ok, err = pcall(dofile, agent_path)
print("B: dofile agent=" .. tostring(ok) .. (ok and "" or (" err=" .. tostring(err))))
if not ok then return end
local ok2, tui = pcall(require, "agent.tui")
print("C: require tui=" .. tostring(ok2) .. " type=" .. tostring(type(tui)))
if not ok2 then print("C err: " .. tostring(tui)) return end
print("D: before init")
local ok3, err3 = pcall(function() tui.init({}) end)
print("E: init=" .. tostring(ok3) .. " err=" .. tostring(err3))
print("F: before print")
local ok4, err4 = pcall(function() tui.print("hello tui") end)
print("G: print=" .. tostring(ok4) .. " err=" .. tostring(err4))
local ok5 = pcall(tui.cleanup)
print("H: cleanup=" .. tostring(ok5) .. " ALL DONE")
