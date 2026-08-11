-- probe_400.lua — 二分定位 HTTP 400 元凶
-- 用法: lua /mnt/<short>/probe_400.lua /mnt/<short> <api_key> <model> <api_url>
-- 逐步构造 payload，每步写结果文件，定位是哪部分导致 400。
local base = ({...})[1] or "/mnt"
local api_key = ({...})[2] or "free"
local model = ({...})[3] or "deepseek-v4-flash-free"
local api_url = ({...})[4] or "https://opencode.ai/zen/v1/chat/completions"

local out = base .. "/probe_400_result.txt"
local f = io.open(out, "w")
local function log(s)
  if f then f:write(s .. "\n"); f:flush() end
  print(s)
end

package.path = base .. "/?.lua;" .. (package.path or "")
local ok_json, json = pcall(require, "agent.json")
if not ok_json then log("FATAL: no agent.json"); return end

local ok_http, http = pcall(require, "agent.http")
if not ok_http then log("FATAL: no agent.http: " .. tostring(http)); return end

-- 系统提示词（从 chat.lua 提取的最小子集——直接内联一段等长文本）
local system_prompt = ("You are a helpful assistant. "):rep(200)  -- ~5KB

-- 运行时块
local runtime_block = "[runtime status — machine-generated context, NOT user input]\nUptime: 12.3s\nFree memory: 2000000 bytes\nConnected components:\n12345678... = gpu"

local function attempt(label, body)
  local ok_enc, encoded = pcall(json.encode, body)
  if not ok_enc then log(label .. " ENCODE FAIL: " .. tostring(encoded)); return end
  local headers = {["Content-Type"] = "application/json"}
  if api_key ~= "" and api_key ~= "free" then
    headers["Authorization"] = "Bearer " .. api_key
  end
  local t0 = os.clock()
  local code, resp, err = http.post(api_url, headers, encoded)
  local dt = os.clock() - t0
  if err then
    log(label .. " ERR(" .. string.format("%.1fs", dt) .. "): " .. tostring(err):sub(1, 200))
  else
    log(label .. " HTTP " .. tostring(code) .. " (" .. string.format("%.1fs", dt)
      .. ") resp[" .. #tostring(resp) .. "]: " .. tostring(resp):sub(1, 150))
  end
end

-- Step 1: 最小（model + 单条消息）
attempt("S1 min", {model = model, messages = {{role = "user", content = "hi"}}, max_tokens = 16})

-- Step 2: + system prompt
attempt("S2 +system", {model = model,
  messages = {{role = "system", content = system_prompt}, {role = "user", content = "hi"}},
  max_tokens = 16})

-- Step 3: + runtime block
attempt("S3 +runtime", {model = model,
  messages = {{role = "system", content = system_prompt}, {role = "user", content = "hi"},
              {role = "user", content = runtime_block}},
  max_tokens = 16})

-- Step 4: + tools（完整 19 工具列表）
local ok_tools, tools_mod = pcall(require, "agent.tools")
if not ok_tools then
  log("S4 SKIP: agent.tools unavailable: " .. tostring(tools_mod))
else
  local tools = tools_mod.list()
  attempt("S4 +tools(" .. #tools .. ")", {model = model,
    messages = {{role = "system", content = system_prompt}, {role = "user", content = "hi"},
                {role = "user", content = runtime_block}},
    tools = tools, max_tokens = 8192, temperature = 0.7})
end

-- Step 5: 完整（无 tools 的完整配置）
attempt("S5 full-notools", {model = model,
  messages = {{role = "system", content = system_prompt}, {role = "user", content = "hi"},
              {role = "user", content = runtime_block}},
  max_tokens = 8192, temperature = 0.7})

if f then f:close() end
log("probe done")
