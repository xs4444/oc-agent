-- ═══════════════════════════════════════════════════════════════
-- OC Agent — AI coding assistant for OpenComputers (GTNH)
-- Single-file Lua agent, OpenAI-compatible, with tool calling
-- ═══════════════════════════════════════════════════════════════

-- ── Section 1: JSON Codec ──────────────────────────────────────

json = {}

function json.encode(val)
  local t = type(val)
  if val == nil then return "null" end
  if t == "boolean" then return val and "true" or "false" end
  if t == "number" then
    if val ~= val or val == math.huge or val == -math.huge then
      return "null"
    end
    return tostring(val)
  end
  if t == "string" then
    local s = val:gsub("[\\\"\n\r\t]", {
      ["\\"] = "\\\\", ['"'] = '\\"',
      ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t"
    })
    return '"' .. s .. '"'
  end
  if t == "table" then
    local is_array = true
    local max_idx = 0
    local has_string_keys = false
    for k in pairs(val) do
      if type(k) == "string" then
        has_string_keys = true
        is_array = false
        break
      end
      if type(k) ~= "number" or k < 1 or k ~= math.floor(k) then
        is_array = false
      end
      if k > max_idx then max_idx = k end
    end
    if is_array and max_idx == #val and not has_string_keys then
      local parts = {}
      for i = 1, #val do
        parts[i] = json.encode(val[i])
      end
      return "[" .. table.concat(parts, ",") .. "]"
    else
      local parts = {}
      for k, v in pairs(val) do
        if type(k) == "string" then
          parts[#parts + 1] = json.encode(k) .. ":" .. json.encode(v)
        end
      end
      return "{" .. table.concat(parts, ",") .. "}"
    end
  end
  error("json: cannot encode type " .. t)
end

function json.decode(str)
  local pos = 1

  local function skip_ws()
    local _, e = str:find("^[%s]*", pos)
    if e then pos = e + 1 end
  end

  local function parse_string()
    pos = pos + 1
    local result = {}
    while pos <= #str do
      local c = str:sub(pos, pos)
      if c == '"' then
        pos = pos + 1
        return table.concat(result)
      elseif c == "\\" then
        pos = pos + 1
        local esc = str:sub(pos, pos)
        if esc == "n" then result[#result+1] = "\n"
        elseif esc == "r" then result[#result+1] = "\r"
        elseif esc == "t" then result[#result+1] = "\t"
        elseif esc == '"' then result[#result+1] = '"'
        elseif esc == "\\" then result[#result+1] = "\\"
        elseif esc == "/" then result[#result+1] = "/"
        elseif esc == "u" then
          local hex = str:sub(pos+1, pos+4)
          pos = pos + 4
          local code = tonumber(hex, 16)
          if code then
            if code < 128 then
              result[#result+1] = string.char(code)
            elseif code < 2048 then
              result[#result+1] = string.char(192 + math.floor(code/64), 128 + code%64)
            else
              result[#result+1] = string.char(224 + math.floor(code/4096), 128 + math.floor(code/64)%64, 128 + code%64)
            end
          end
        else
          result[#result+1] = esc
        end
        pos = pos + 1
      else
        result[#result+1] = c
        pos = pos + 1
      end
    end
    error("json: unterminated string")
  end

  local function parse_number()
    local start = pos
    if str:sub(pos, pos) == "-" then pos = pos + 1 end
    while pos <= #str do
      local c = str:sub(pos, pos)
      if c:match("[0-9eE+%.%-]") then
        pos = pos + 1
      else
        break
      end
    end
    return tonumber(str:sub(start, pos - 1))
  end

  local parse_value

  local function parse_array()
    pos = pos + 1
    local arr = {}
    skip_ws()
    if str:sub(pos, pos) == "]" then pos = pos + 1; return arr end
    while true do
      arr[#arr + 1] = parse_value()
      skip_ws()
      local c = str:sub(pos, pos)
      if c == "]" then pos = pos + 1; return arr end
      if c ~= "," then error("json: expected ',' or ']' at " .. pos) end
      pos = pos + 1
      skip_ws()
    end
  end

  local function parse_object()
    pos = pos + 1
    local obj = {}
    skip_ws()
    if str:sub(pos, pos) == "}" then pos = pos + 1; return obj end
    while true do
      skip_ws()
      if str:sub(pos, pos) ~= '"' then error("json: expected key string at " .. pos) end
      local key = parse_string()
      skip_ws()
      if str:sub(pos, pos) ~= ":" then error("json: expected ':' at " .. pos) end
      pos = pos + 1
      skip_ws()
      obj[key] = parse_value()
      skip_ws()
      local c = str:sub(pos, pos)
      if c == "}" then pos = pos + 1; return obj end
      if c ~= "," then error("json: expected ',' or '}' at " .. pos) end
      pos = pos + 1
    end
  end

  parse_value = function()
    skip_ws()
    local c = str:sub(pos, pos)
    if c == '"' then return parse_string()
    elseif c == "{" then return parse_object()
    elseif c == "[" then return parse_array()
    elseif str:sub(pos, pos+3) == "true" then pos = pos + 4; return true
    elseif str:sub(pos, pos+4) == "false" then pos = pos + 5; return false
    elseif str:sub(pos, pos+3) == "null" then pos = pos + 4; return nil
    elseif c == "-" or (c >= "0" and c <= "9") then return parse_number()
    else error("json: unexpected char '" .. c .. "' at " .. pos) end
  end

  local result = parse_value()
  skip_ws()
  if pos <= #str then error("json: trailing data at " .. pos) end
  return result
end

-- ── Section 2: HTTP Client ─────────────────────────────────────

local function http_post(url, headers, body)
  local internet = require("internet")
  local ok, handle = pcall(function()
    -- 3-arg form: body presence auto-selects POST (compatible with ocvm
    -- and real OC; explicit 4th method arg is ignored by some emulators)
    return internet.request(url, body, headers)
  end)
  if not ok then
    return nil, nil, "connection failed: " .. tostring(handle)
  end

  local chunks = {}
  local iter_ok, iter_err = pcall(function()
    local n = 0
    for chunk in handle do
      n = n + 1
      chunks[#chunks + 1] = chunk
      -- Yield on EVERY chunk: OC's scheduler sees progress even while the
      -- iterator waits for slow (reasoning) model responses. Otherwise the
      -- computer crashes with "too long without yielding".
      os.sleep(0.02)
    end
  end)
  if not iter_ok then
    return nil, nil, "http read failed: " .. tostring(iter_err)
  end
  local response_body = table.concat(chunks)

  -- Some emulators (ocvm) fill the response asynchronously; retry briefly.
  local code
  local mt = getmetatable(handle)
  if mt and mt.__index and mt.__index.response then
    for _ = 1, 10 do
      local ok2, c = pcall(mt.__index.response)
      if ok2 and type(c) == "number" then
        code = c
        break
      end
      os.sleep(0.2)
    end
  end

  return code or 0, response_body, nil
end

-- ── Section 3: Tool Definitions ────────────────────────────────

-- forward declaration: execute_tool (Section 4) calls load_config (Section 6)
local load_config

local TOOLS = {
  {type="function", ["function"]={
    name="read_file",
    description="Read file contents at the given path",
    parameters={type="object", properties={path={type="string", description="File path"}}, required={"path"}}
  }},
  {type="function", ["function"]={
    name="write_file",
    description="Write content to a file",
    parameters={type="object", properties={path={type="string", description="File path"}, content={type="string", description="Content to write"}}, required={"path", "content"}}
  }},
  {type="function", ["function"]={
    name="list_directory",
    description="List files in a directory",
    parameters={type="object", properties={path={type="string", description="Directory path"}}, required={"path"}}
  }},
  {type="function", ["function"]={
    name="execute_lua",
    description="Execute Lua code in the OpenOS environment. Can use require(), component, robot, etc. Must yield in loops with os.sleep(0).",
    parameters={type="object", properties={code={type="string", description="Lua code to execute"}}, required={"code"}}
  }},
  {type="function", ["function"]={
    name="component_list",
    description="List connected OpenComputers components (optionally filtered by type name)",
    parameters={type="object", properties={filter={type="string", description="Optional type filter (e.g. 'redstone', 'gpu', 'adapter')"}}}
  }},
  {type="function", ["function"]={
    name="component_doc",
    description="Get documentation for a component's methods. Call with just an address to list all methods, or with a method name for details. Use after component_list to learn what a component can do.",
    parameters={type="object", properties={address={type="string", description="Component address (can be abbreviated, e.g. first 4 chars)"}, method={type="string", description="Optional method name to get docs for"}}, required={"address"}}
  }},
  {type="function", ["function"]={
    name="component_invoke",
    description="Call a method on an OpenComputers component. Use component_doc first to learn available methods.",
    parameters={type="object", properties={address={type="string", description="Component address (can be abbreviated)"}, method={type="string", description="Method name to call"}, args={type="array", items={type="string"}, description="Arguments to pass to the method (numbers, strings, booleans)"}}, required={"address", "method"}}
  }},
  {type="function", ["function"]={
    name="web_search",
    description="Search the web for information. Returns titles, URLs and snippets. Uses Tavily (general web, configurable via /tavily) or Hacker News Algolia (technical, no key needed) as fallback.",
    parameters={type="object", properties={query={type="string", description="Search query"}, limit={type="number", description="Max results (1-10, default 5)"}}, required={"query"}}
  }},
  {type="function", ["function"]={
    name="shell_execute",
    description="Run an OpenOS shell command",
    parameters={type="object", properties={command={type="string", description="Shell command to execute"}}, required={"command"}}
  }}
}

-- ── Section 4: Tool Execution ──────────────────────────────────

function execute_lua_code(code)
  if type(code) ~= "string" then
    return "Error: code argument must be a string, got " .. type(code)
  end
  -- Capture both io.write and print (OpenOS's print renders to GPU, not io.write)
  local original_write = io.write
  local original_print = rawget(_G, "print")
  local captured = {}
  io.write = function(s)
    captured[#captured + 1] = tostring(s or "")
    return true
  end
  if type(original_print) == "function" then
    _G.print = function(s)
      captured[#captured + 1] = tostring(s or "")
    end
  end

  local fn, compile_err = load(code)
  local ok, result
  if fn then
    ok, result = pcall(fn)
  end

  io.write = original_write
  if type(original_print) == "function" then
    _G.print = original_print
  end

  local output = table.concat(captured)
  if not fn then
    return "Compile error: " .. tostring(compile_err)
  elseif not ok then
    return "Runtime error: " .. tostring(result) ..
      (output ~= "" and ("\nOutput before error:\n" .. output) or "")
  else
    local ret = output
    if result ~= nil then
      ret = ret .. (ret ~= "" and "\n" or "") .. "=> " .. tostring(result)
    end
    return ret ~= "" and ret or "(no output)"
  end
end

function execute_tool(name, args_str)
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
    local err_info = ok and tostring(decoded) or tostring(ok2 and decoded2)
    return "Error parsing arguments (decode failed: " .. err_info .. "): " .. tostring(cleaned):sub(1, 200)
  end

  if name == "read_file" then
    local ok, result = pcall(function()
      local f = io.open(args.path, "r")
      if not f then error("file not found: " .. args.path) end
      local c = f:read("*a")
      f:close()
      return c
    end)
    return ok and result or ("Error: " .. tostring(result))

  elseif name == "write_file" then
    local ok, result = pcall(function()
      local f = io.open(args.path, "w")
      if not f then error("cannot open for writing: " .. args.path) end
      f:write(args.content)
      f:close()
      return "Written to " .. args.path
    end)
    return ok and result or ("Error: " .. tostring(result))

  elseif name == "list_directory" then
    local ok, result = pcall(function()
      local fs = require("filesystem")
      local parts = {}
      for f in fs.list(args.path or "/") do
        parts[#parts + 1] = f
      end
      if #parts == 0 then return "(empty)" end
      return table.concat(parts, "\n")
    end)
    return ok and result or ("Error: " .. tostring(result))

  elseif name == "execute_lua" then
    return execute_lua_code(args.code)

  elseif name == "component_list" then
    local ok, result = pcall(function()
      local comp = require("component")
      local parts = {}
      for addr, typ in comp.list(args.filter or "") do
        parts[#parts + 1] = addr:sub(1, 8) .. "... = " .. typ
      end
      if #parts == 0 then return "(no components found)" end
      return table.concat(parts, "\n")
    end)
    return ok and result or ("Error: " .. tostring(result))

  elseif name == "component_doc" then
    local ok, result = pcall(function()
      local comp = require("component")
      local resolved, err = comp.get(args.address)
      if not resolved then
        local addr2 = comp.type(args.address) and args.address or nil
        if not addr2 then return "unknown component address: " .. tostring(args.address) .. (err and (" (" .. err .. ")") or "") end
      end
      local addr = resolved or args.address
      local parts = {}
      if args.method then
        local doc = comp.doc(addr, args.method)
        return doc and ("(" .. args.method .. ")\n" .. doc) or ("no doc for method: " .. args.method)
      else
        local methods = comp.methods(addr)
        if not methods then return "no methods listed for " .. args.address end
        for m in pairs(methods) do
          parts[#parts + 1] = m
        end
        table.sort(parts)
        return "Type: " .. tostring(comp.type(addr)) .. "\nMethods:\n" .. table.concat(parts, "\n")
      end
    end)
    return ok and result or ("Error: " .. tostring(result))

  elseif name == "component_invoke" then
    local ok, result = pcall(function()
      local comp = require("component")
      local resolved, err = comp.get(args.address)
      if not resolved then
        local addr2 = comp.type(args.address) and args.address or nil
        if not addr2 then return "unknown component address: " .. tostring(args.address) .. (err and (" (" .. err .. ")") or "") end
      end
      local addr = resolved or args.address
      local arg_values = {}
      if type(args.args) == "table" then
        for _, v in ipairs(args.args) do
          arg_values[#arg_values + 1] = v
        end
      end
      local r = {comp.invoke(addr, args.method, table.unpack(arg_values))}
      -- format results
      local out = {}
      for _, v in ipairs(r) do
        out[#out + 1] = type(v) == "table" and json.encode(v) or tostring(v)
      end
      if #out == 0 then return "(no return values)" end
      return table.concat(out, "\n")
    end)
    return ok and result or ("Error: " .. tostring(result))

  elseif name == "web_search" then
    local ok, result = pcall(function()
      local query = tostring(args.query or "")
      local limit = math.floor(tonumber(args.limit) or 5)
      if limit < 1 then limit = 1 end
      if limit > 10 then limit = 10 end
      if query == "" then return "Error: query is required" end
      local internet = require("internet")
      local config_table = load_config() or {}
      local tavily_key = config_table.tavily_key

      local function read_all(handle)
        local chunks = {}
        local ok_iter, err_iter = pcall(function()
          local n = 0
          for chunk in handle do
            n = n + 1
            chunks[#chunks + 1] = chunk
            if n % 4 == 0 then os.sleep(0.02) end
          end
        end)
        if not ok_iter then
          error("read failed: " .. tostring(err_iter))
        end
        return table.concat(chunks)
      end

      if tavily_key and tavily_key ~= "" then
        -- Tavily: general web search with Chinese support
        local body = json.encode({query = query, api_key = tavily_key, max_results = limit, search_depth = "basic"})
        local headers = {["Content-Type"] = "application/json"}
        local okr, handle = pcall(function()
          return internet.request("https://api.tavily.com/search", body, headers)
        end)
        if not okr then return "Tavily error: " .. tostring(handle) end
        local resp = read_all(handle)
        local data, err = json.decode(resp)
        if not data then return "Tavily parse error: " .. tostring(err) end
        local results = data.results or {}
        local out = {}
        for i, r in ipairs(results) do
          if i > limit then break end
          out[#out + 1] = string.format("%d. %s\n   %s\n   %s", i, tostring(r.title or ""), tostring(r.url or ""), tostring(r.content or ""))
        end
        if #out == 0 then return "(no results from Tavily)" end
        return table.concat(out, "\n")
      else
        -- Fallback: Hacker News Algolia (keyless, technical content)
        local url = "https://hn.algolia.com/api/v1/search?query=" .. query:gsub(" ", "+") .. "&hitsPerPage=" .. limit .. "&tags=story"
        local okr, handle = pcall(function()
          return internet.request(url)
        end)
        if not okr then return "HN error: " .. tostring(handle) end
        local resp = read_all(handle)
        local data, err = json.decode(resp)
        if not data then return "HN parse error: " .. tostring(err) end
        local hits = data.hits or {}
        local out = {}
        for i, h in ipairs(hits) do
          if i > limit then break end
          local title = h.title or h.story_title or ""
          local url = h.url or ("https://news.ycombinator.com/item?id=" .. tostring(h.objectID or ""))
          out[#out + 1] = string.format("%d. %s\n   %s", i, tostring(title), tostring(url))
        end
        if #out == 0 then return "(no results from Hacker News)" end
        return table.concat(out, "\n")
      end
    end)
    return ok and result or ("Error: " .. tostring(result))

  elseif name == "shell_execute" then
    local ok, result = pcall(function()
      local sh = require("shell")
      return sh.execute(args.command)
    end)
    return ok and tostring(result) or ("Error: " .. tostring(result))

  else
    return "Unknown tool: " .. name
  end
end

-- ── Section 5: LLM Client ─────────────────────────────────────

local function safe_call(fn, ...)
  if type(fn) == "function" then
    local ok, r = pcall(fn, ...)
    if ok then return r end
  end
  return nil
end

local function build_system_prompt()
  local computer = require("computer")
  local component = require("component")

  local comp_list = {}
  for addr, typ in component.list() do
    comp_list[#comp_list + 1] = addr:sub(1, 8) .. "... = " .. typ
  end

  local address = safe_call(computer.address) or "unknown"
  local uptime = safe_call(computer.uptime) or 0
  local free_mem = safe_call(computer.freeMemory) or 0

  return "You are an AI assistant running inside OpenComputers, a computer system in Minecraft (GT: New Horizons modpack). You can read and write files, execute Lua code, list connected hardware components, and run shell commands.\n\n"
    .. "Available tools:\n"
    .. "- read_file: Read file contents at the given path\n"
    .. "- write_file: Write content to a file\n"
    .. "- list_directory: List files in a directory\n"
    .. "- execute_lua: Execute Lua code in the OpenOS environment (use require(), component, robot, etc.)\n"
    .. "- component_list: List connected OpenComputers components\n"
    .. "- component_doc: Get documentation for a component's methods (list methods or read one method's doc)\n"
    .. "- component_invoke: Call a method on a component (after checking component_doc)\n"
    .. "- web_search: Search the web for information (titles, URLs, snippets). Uses Tavily if configured, Hacker News otherwise.\n"
    .. "- shell_execute: Run an OpenOS shell command\n\n"
    .. "You have full access to the OpenComputers environment. You can extend your own capabilities by writing new Lua scripts via write_file and loading them with execute_lua using require().\n\n"
    .. "When exploring hardware, use this workflow:\n"
    .. "1. component_list to discover components\n"
    .. "2. component_doc(address) to learn what methods a component has\n"
    .. "3. component_doc(address, method) for method details, then component_invoke to call it\n"
    .. "You can also use execute_lua for complex logic, component.proxy() for convenience access, and component.doc() to query documentation from Lua.\n\n"
    .. "When writing Lua code for execute_lua, remember:\n"
    .. "- You MUST yield periodically in loops (use os.sleep(0)) to avoid the computer crashing\n"
    .. "- Use require() to access OpenOS libraries\n"
    .. "- Use component.proxy() or component.list() to interact with hardware\n"
    .. "- Memory is limited; keep code efficient\n\n"
    .. "Current computer address: " .. tostring(address) .. "\n"
    .. "Uptime: " .. string.format("%.1f", uptime) .. "s\n"
    .. "Free memory: " .. tostring(free_mem) .. " bytes\n"
    .. "Connected components:\n" .. table.concat(comp_list, "\n")
end

local function chat(messages, config)
  local system_prompt = build_system_prompt()

  local api_messages = {}
  api_messages[#api_messages + 1] = {role = "system", content = system_prompt}
  for _, msg in ipairs(messages) do
    api_messages[#api_messages + 1] = msg
  end

  local body = json.encode({
    model = config.model or "deepseek-v4-flash-free",
    messages = api_messages,
    tools = TOOLS,
    max_tokens = 2048,
    temperature = 0.7
  })

  local headers = {
    ["Content-Type"] = "application/json",
  }
  -- Only send auth when a real key is configured. Some free endpoints
  -- (e.g. OpenCode Zen free models) reject invalid bearer tokens with 401
  -- but accept requests without an Authorization header.
  if config.api_key and config.api_key ~= "" and config.api_key ~= "free" then
    headers["Authorization"] = "Bearer " .. config.api_key
  end

  local code, resp, err = http_post(config.api_url or "https://opencode.ai/zen/v1/chat/completions", headers, body)
  if err then
    return {content = nil, tool_calls = nil, finish_reason = "error", error = err}
  end
  if not code or code ~= 200 then
    return {content = nil, tool_calls = nil, finish_reason = "error",
      error = "HTTP " .. tostring(code) .. ": " .. tostring(resp):sub(1, 500)}
  end

  local data, decode_err = json.decode(resp)
  if not data then
    return {content = nil, tool_calls = nil, finish_reason = "error",
      error = "JSON decode: " .. tostring(decode_err)}
  end

  local choice = data.choices and data.choices[1]
  if not choice then
    return {content = nil, tool_calls = nil, finish_reason = "error",
      error = "No choices in response"}
  end

  local msg = choice.message or {}
  return {
    content = msg.content,
    tool_calls = msg.tool_calls,
    finish_reason = choice.finish_reason
  }
end

-- ── Section 6: Config & History ────────────────────────────────

local CONFIG_PATH = "/home/agent_config.txt"
local HISTORY_PATH = "/home/agent_history.txt"
local MAX_HISTORY = 20
local MAX_HISTORY_BYTES = 50000  -- ~50KB budget; large tool results trimmed away
local MAX_TOOL_RESULT = 3000     -- per-tool-result cap for history persistence

local function msg_bytes(msg)
  local total = 0
  if type(msg.content) == "string" then total = total + #msg.content end
  if type(msg.tool_calls) == "table" then
    for _, tc in ipairs(msg.tool_calls) do
      if tc["function"] and type(tc["function"].arguments) == "string" then
        total = total + #tc["function"].arguments
      end
    end
  end
  return total
end

local function trim_history(messages)
  -- Cap by count first
  if #messages > MAX_HISTORY then
    local trimmed = {}
    for i = #messages - MAX_HISTORY + 1, #messages do
      trimmed[#trimmed + 1] = messages[i]
    end
    messages = trimmed
  end
  -- Then cap by total bytes (drop oldest until under budget)
  while #messages > 2 do  -- never drop the last 2 (current exchange)
    local total = 0
    for _, m in ipairs(messages) do
      total = total + msg_bytes(m)
    end
    if total <= MAX_HISTORY_BYTES then break end
    table.remove(messages, 1)
  end
  return messages
end

load_config = function()
  local fs = require("filesystem")
  if not fs.exists(CONFIG_PATH) then return nil end
  local f = io.open(CONFIG_PATH, "r")
  if not f then return nil end
  local content = f:read("*a")
  f:close()
  local ser = require("serialization")
  local ok, data = pcall(ser.unserialize, content)
  if ok and type(data) == "table" then return data end
  return nil
end

local function save_config(config)
  local ser = require("serialization")
  local f = io.open(CONFIG_PATH, "w")
  if not f then error("cannot save config") end
  f:write(ser.serialize(config))
  f:close()
end

local function first_run_setup()
  print("OC Agent - First Run Setup")
  io.write("API Key (empty for free OpenCode Zen model, or any OpenAI-compatible key): ")
  local api_key = io.read():gsub("\n", "")
  io.write("Model [deepseek-v4-flash-free]: ")
  local model = io.read():gsub("\n", "")
  if model == "" then model = "deepseek-v4-flash-free" end
  io.write("API URL [https://opencode.ai/zen/v1/chat/completions]: ")
  local api_url = io.read():gsub("\n", "")
  if api_url == "" then api_url = "https://opencode.ai/zen/v1/chat/completions" end

  local config = {api_key = api_key, model = model, api_url = api_url}
  save_config(config)
  print("Configuration saved to " .. CONFIG_PATH)
  return config
end

local function load_history()
  local fs = require("filesystem")
  if not fs.exists(HISTORY_PATH) then return {} end
  local f = io.open(HISTORY_PATH, "r")
  if not f then return {} end
  local content = f:read("*a")
  f:close()
  local ser = require("serialization")
  local ok, data = pcall(ser.unserialize, content)
  if ok and type(data) == "table" then
    return trim_history(data)
  end
  return {}
end

local function save_history(messages)
  local ser = require("serialization")
  local f = io.open(HISTORY_PATH, "w")
  if not f then return end
  f:write(ser.serialize(messages))
   f:close()
 end

-- ── Section 7: REPL & Main Loop ────────────────────────────────

local function handle_command(cmd, config, messages)
  local parts = {}
  for w in cmd:gmatch("%S+") do parts[#parts + 1] = w end
  local command = parts[1]

  if command == "/model" then
    if parts[2] then
      config.model = parts[2]
      save_config(config)
      print("Model: " .. config.model)
    else
      print("Model: " .. config.model)
    end
  elseif command == "/key" then
    if parts[2] then
      config.api_key = parts[2]
      save_config(config)
      print("API key updated")
    else
      print("Usage: /key <api_key>")
    end
  elseif command == "/tavily" then
    if parts[2] then
      config.tavily_key = parts[2]
      save_config(config)
      print("Tavily API key set: " .. parts[2]:sub(1, 8) .. "... (web_search will use Tavily)")
    else
      if config.tavily_key then
        print("Tavily key: " .. config.tavily_key:sub(1, 8) .. "...")
      else
        print("No Tavily key set. web_search uses Hacker News (keyless). Usage: /tavily <key>")
      end
    end
  elseif command == "/url" then
    if parts[2] then
      config.api_url = parts[2]
      save_config(config)
      print("API URL: " .. config.api_url)
    else
      print("API URL: " .. config.api_url)
    end
  elseif command == "/reset" then
    messages = {}
    save_history(messages)
    print("History cleared")
  elseif command == "/hist" then
    print(#messages .. " messages in history")
  elseif command == "/tools" then
    for _, t in ipairs(TOOLS) do
      print("  " .. t["function"].name .. ": " .. t["function"].description)
    end
  elseif command == "/help" then
    print("Commands: /model /key /url /tavily /reset /hist /tools /help /exit")
  elseif command == "/exit" then
    return true, config, messages
  else
    print("Unknown command: " .. command .. ". Type /help for commands.")
  end
  return false, config, messages
end

local function main()
  local component = require("component")
  if not component.isAvailable("internet") then
    print("Error: No internet card found. Tier 2 Internet Card required.")
    return
  end

  local config = load_config()
  if not config then config = first_run_setup() end

  local messages = load_history()
  local term_history = {}

  print("OC Agent ready. Model: " .. config.model)
  print("Type /help for commands.")

  while true do
    io.write("> ")
    local input = io.read()
    if not input then break end
    input = input:gsub("\n", "")
    if input == "" then goto continue end

    if input:sub(1, 1) == "/" then
      local exit, c, m = handle_command(input, config, messages)
      config, messages = c, m
      if exit then break end
      goto continue
    end

    messages[#messages + 1] = {role = "user", content = input}
    term_history[#term_history + 1] = input
    if #term_history > 50 then
      table.remove(term_history, 1)  -- keep terminal history bounded
    end
    messages = trim_history(messages)
    save_history(messages)  -- persist user message immediately

    while true do
      io.write("Thinking...\r")
      local response = chat(messages, config)

      if response.error then
        print("Error: " .. response.error)
        break
      end

      if response.content then
        print(response.content)
      end

      local assistant_msg = {role = "assistant", content = response.content or ""}
      if response.tool_calls then
        assistant_msg.tool_calls = response.tool_calls
      end
      messages[#messages + 1] = assistant_msg
      save_history(messages)  -- persist assistant reply immediately

      if not response.tool_calls or #response.tool_calls == 0 then
        break
      end

      for _, tc in ipairs(response.tool_calls) do
        local tool_name = tc["function"].name
        local tool_args = tc["function"].arguments
        print("[tool] " .. tool_name)
        local result = execute_tool(tool_name, tool_args)
        -- Cap large tool outputs so history + memory stay bounded
        if type(result) == "string" and #result > MAX_TOOL_RESULT then
          result = result:sub(1, MAX_TOOL_RESULT) .. "\n...[truncated " .. (#result - MAX_TOOL_RESULT) .. " chars]"
        end
        messages[#messages + 1] = {
          role = "tool",
          tool_call_id = tc.id,
          content = result
        }
        save_history(messages)  -- persist each tool result immediately
      end
    end

    messages = trim_history(messages)
    save_history(messages)

    ::continue::
  end

  print("Goodbye!")
end

if not _TEST_MODE then main() end

-- Test hooks (available when loaded with _TEST_MODE = true)
if _TEST_MODE then
  agent_test = {
    chat = chat,
    http_post = http_post,
    build_system_prompt = build_system_prompt,
    trim_history = trim_history,
    TOOLS = TOOLS,
  }
end
