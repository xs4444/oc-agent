-- probe2_tools.lua — 定位 19 个工具中哪个导致 400
-- 用法: lua /mnt/<short>/probe2_tools.lua /mnt/<short> <api_key> <model> <api_url>
-- 1) 把 encode(tools) 写盘（host 侧检查 JSON 合法性）
-- 2) 逐个工具发请求，定位坏工具
local base = ({...})[1] or "/mnt"
local api_key = ({...})[2] or "free"
local model = ({...})[3] or "deepseek-v4-flash-free"
local api_url = ({...})[4] or "https://opencode.ai/zen/v1/chat/completions"

local out = base .. "/probe2_result.txt"
local f = io.open(out, "w")
local function log(s)
  if f then f:write(s .. "\n"); f:flush() end
  print(s)
end

package.path = base .. "/?.lua;" .. (package.path or "")
local ok_json, json = pcall(require, "agent.json")
local ok_http, http = pcall(require, "agent.http")
local ok_tools, tools_mod = pcall(require, "agent.tools")
if not (ok_json and ok_http and ok_tools) then
  log("FATAL: json=" .. tostring(ok_json) .. " http=" .. tostring(ok_http) .. " tools=" .. tostring(ok_tools))
  return
end

local tools = tools_mod.list()
log("tools count: " .. #tools)

-- 1) dump encode(tools) 全量到独立文件（host 检查 JSON 合法性）
local ok_enc_all, encoded_all = pcall(json.encode, {tools = tools})
local dump_path = base .. "/probe2_tools_dump.json"
local fd = io.open(dump_path, "w")
if fd then
  if ok_enc_all then
    fd:write(encoded_all)
    log("dump written: " .. dump_path .. " size=" .. #encoded_all)
  else
    fd:write("ENCODE FAIL: " .. tostring(encoded_all))
    log("dump ENCODE FAIL: " .. tostring(encoded_all))
  end
  fd:close()
end

-- 2) 逐个工具请求（每个 1 个 tool，max_tokens 16 快速）
local headers = {["Content-Type"] = "application/json"}
if api_key ~= "" and api_key ~= "free" then
  headers["Authorization"] = "Bearer " .. api_key
end
local base_messages = {{role = "user", content = "hi"}}

for i, t in ipairs(tools) do
  local name = t and t["function"] and t["function"].name or ("tool#" .. i)
  local ok_enc, encoded = pcall(json.encode, {
    model = model, messages = base_messages,
    tools = {t}, max_tokens = 16,
  })
  if not ok_enc then
    log("tool[" .. i .. "] " .. name .. " ENCODE FAIL: " .. tostring(encoded):sub(1, 150))
  else
    local code, resp, err = http.post(api_url, headers, encoded)
    if err then
      log("tool[" .. i .. "] " .. name .. " ERR: " .. tostring(err):sub(1, 120))
    elseif code == 200 then
      log("tool[" .. i .. "] " .. name .. " OK")
    else
      log("tool[" .. i .. "] " .. name .. " HTTP " .. tostring(code) .. " resp=" .. tostring(resp):sub(1, 200))
    end
  end
end

if f then f:close() end
log("probe2 done")
