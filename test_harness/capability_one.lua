-- capability_one.lua: run a single task, write result immediately
-- usage: lua capability_one.lua <task_num> <api_key> <model> <url>
local args = {...}
local task_num = tonumber(args[1] or "1")
local results = {}

local function flush()
  local ok, fs = pcall(require, "filesystem")
  if not ok or not fs then return end
  local ok2, iter = pcall(fs.list, "/mnt")
  if not ok2 or not iter then return end
  for item in iter do
    local f2 = io.open("/mnt/" .. item .. "/cap_" .. task_num .. ".txt", "w")
    if f2 then f2:write(table.concat(results, "\n") .. "\n") f2:close() end
  end
end

local function log(...)
  local parts = {}
  for i = 1, select("#", ...) do
    parts[i] = tostring(select(i, ...))
  end
  results[#results + 1] = table.concat(parts, " ")
  flush()
end

local api_key = args[2] or "free"
local model = args[3] or "deepseek-v4-flash"
local api_url = args[4] or "https://opencode.ai/zen/go/v1/chat/completions"

log("=== Task " .. task_num .. " ===")
log("model: " .. model)

local fs = require("filesystem")
local agent_path
for item in fs.list("/mnt") do
  local full = "/mnt/" .. item
  if fs.exists(full .. "/agent.lua") then
    agent_path = full .. "/agent.lua"
    break
  end
end
if not agent_path then
  log("ERROR: agent.lua not found")
else
  _TEST_MODE = true
  local ok, err = pcall(dofile, agent_path)
  if not ok then
    log("agent load failed: " .. tostring(err))
  else
    local config = {api_key = api_key, model = model, api_url = api_url}

    local function run_turn(user_msg, max_iters)
      max_iters = max_iters or 6
      local messages = {{role = "user", content = user_msg}}
      log("USER: " .. user_msg)
      local tools_used = {}
      local final_text = ""
      for it = 1, max_iters do
        local chat_ok, response = pcall(agent_test.chat, messages, config)
        if not chat_ok then
          log("chat threw: " .. tostring(response))
          break
        elseif response.error then
          log("chat error: " .. tostring(response.error))
          break
        end
        if response.content and #response.content > 0 then
          final_text = response.content
        end
        local tcs = response.tool_calls
        if not tcs or #tcs == 0 then break end
        local assistant_msg = {role = "assistant", content = response.content or ""}
        assistant_msg.tool_calls = tcs
        messages[#messages + 1] = assistant_msg
        for _, tc in ipairs(tcs) do
          local tname = tc["function"].name
          local targs = tc["function"].arguments
          tools_used[#tools_used + 1] = tname
          log("[tool] " .. tname .. " " .. targs)
          local result = execute_tool(tname, targs)
          log("[result] " .. tostring(result):sub(1, 400))
          messages[#messages + 1] = {role = "tool", tool_call_id = tc.id, content = result}
        end
      end
      log("[tools] " .. table.concat(tools_used, ", "))
      log("[final] " .. tostring(final_text):sub(1, 500))
    end

    if task_num == 1 then
      run_turn("Reply with exactly: CAPABILITY_OK", 2)
    elseif task_num == 2 then
      run_turn("Write 'HELLO_GTNH' to /hello.txt using write_file, then read it back with read_file and report what it says.", 6)
    elseif task_num == 3 then
      -- v0.3.124: shell components + lua -e (component_* 工具已删)
      run_turn("Use shell_execute to run 'components', find the internet component address, then use shell_execute with lua -e to call component.invoke on it with method 'isHttpEnabled'. Report the result.", 8)
    elseif task_num == 4 then
      run_turn("Use shell_execute to run lua -e 'print(17*23)' and tell me the result.", 4)
    elseif task_num == 5 then
      run_turn("Use shell_execute to run 'components filesystem', then use shell_execute with lua -e to call component.invoke getLabel on the first filesystem component found. Report labels.", 8)
    end
  end
end

-- write result immediately
local out_path = "/mnt/" .. (agent_path and agent_path:match("/mnt/([^/]+)/") or "956") .. "/cap_" .. task_num .. ".txt"
local f = io.open(out_path, "w")
if f then
  f:write(table.concat(results, "\n") .. "\n")
  f:close()
  log("written to " .. out_path)
end
-- also try all mounts
for item in fs.list("/mnt") do
  local f2 = io.open("/mnt/" .. item .. "/cap_" .. task_num .. ".txt", "w")
  if f2 then f2:write(table.concat(results, "\n") .. "\n") f2:close() end
end
