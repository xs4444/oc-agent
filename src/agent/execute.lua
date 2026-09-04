-- ═══════════════════════════════════════════════════════════════
-- agent.execute — tool execution dispatcher (Phase 1 plugin split).
--
-- Equivalent of the old Section 4 execute_tool body: parses the LLM's
-- (possibly sloppy) JSON arguments with the same salvage logic, then
-- dispatches to the registered tool implementation from agent.tools.
--
-- deps is injected by agent.lua's execute_tool wrapper: {json=...,
-- http_post=..., load_config=..., wait_modem_message=...,
-- subagent_listen_port=..., subagent_reply_port=...,
-- subagent_timeout=...}. Tool modules receive the same deps table.
-- ═══════════════════════════════════════════════════════════════

local tools = require("agent.tools")
local REGISTRY = tools.registry()

-- execute_lua was removed in a previous version; keep the old guard
-- message (run_tests asserts it) without any actual executor.
local EXECUTE_LUA_GUARD =
  "Error: execute_lua has been removed. Do math/JSON/text work yourself; for exact arithmetic write a script with write_file that writes the answer to a file, then run `lua /tmp/v.lua; cat /tmp/v_out.txt` via shell_execute (the lua wrapper has no -e flag)."

local M = {}

-- 返回 (text, is_err)：
--   text   — 工具结果字符串（成功输出或错误信息，chat 路径消费这个）
--   is_err — 结构化错误标志：本层判定的错误（参数解析失败 / execute_lua
--            护栏 / Unknown tool / 工具 pcall 崩溃）= true；工具层自带的
--            标志（file/shell 模块返回）透传；工具未提供（插件等）= nil，
--            调用方可回退字符串前缀判定。
function M.run(name, args_str, deps)
  deps = deps or {}
  local json = deps.json

  -- LLM-provided arguments can be sloppy JSON; never let decode errors kill us.
  local args
  local ok, decoded = pcall(json.decode, args_str or "{}")
  if ok and type(decoded) == "table" then
    args = decoded
  else
    -- Try to salvage: strip surrounding whitespace/quotes
    local cleaned = tostring(args_str or "{}"):gsub("^%s*", ""):gsub("%s*$", "")
    local ok2, decoded2 = pcall(json.decode, cleaned)
    if ok2 and type(decoded2) == "table" then
      args = decoded2
    else
      args = {}
    end
    -- Diagnose: expose raw args + error for debugging
    local err_info
    if ok and type(decoded) ~= "table" then
      -- decode actually succeeded, but the result wasn't an object —
      -- don't report it as a decode failure
      err_info = "decoded to " .. type(decoded) .. ", expected object"
    elseif ok then
      err_info = tostring(ok2 and decoded2 or decoded)
    else
      err_info = tostring(decoded)
    end
    return "Error parsing arguments (decode failed: " .. err_info .. "): " .. tostring(cleaned):sub(1, 200), true
  end

  if name == "execute_lua" then
    return EXECUTE_LUA_GUARD, true
  end

  local exec = REGISTRY[name]
  if not exec then
    return "Unknown tool: " .. tostring(name), true
  end

  local ok_run, result, tool_err = pcall(exec, name, args, deps)
  if not ok_run then
    return "Error: " .. tostring(result), true
  end
  return result, tool_err
end

return M
