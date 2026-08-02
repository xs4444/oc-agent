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

local MAX_RETRIES = 3            -- retries for transient HTTP failures
local RETRY_BASE_DELAY = 2       -- seconds, doubled per attempt

-- Single request attempt. Returns code, body, err.
local function http_post_once(url, headers, body)
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

-- POST with automatic retry: transient failures (network errors, 429, 5xx)
-- are retried with exponential backoff. 4xx errors are permanent, never retried.
local function http_post(url, headers, body)
  for attempt = 1, MAX_RETRIES + 1 do
    local code, resp, err = http_post_once(url, headers, body)
    if err then
      if attempt > MAX_RETRIES then return code, resp, err end
    else
      local transient = (code == 429 or code >= 500)
      if not transient or attempt > MAX_RETRIES then
        return code, resp, err
      end
    end
    os.sleep(RETRY_BASE_DELAY * 2 ^ (attempt - 1))
  end
end

-- ── Section 3: Tool Definitions ────────────────────────────────

-- forward declaration: execute_tool (Section 4) calls load_config (Section 6)
local load_config

local TOOLS = {
  {type="function", ["function"]={
    name="read_file",
    description="Read file contents. Optional offset (1-based line number) and limit (max lines) read a slice of a large file instead of the whole thing; negative offset counts from the end (tail). When offset is given, lines are prefixed with their number. Omit both to read the whole file.",
    parameters={type="object", properties={path={type="string", description="File path"}, offset={type="number", description="Start line (1-based); negative = from end (e.g. -5 = last 5 lines)"}, limit={type="number", description="Max lines to read (after offset)"}}, required={"path"}}
  }},
  {type="function", ["function"]={
    name="edit_file",
    description="Edit a file by replacing an exact string match. The old_string must be unique unless replace_all is true. Use read_file first to see the exact text. For large files or appending, prefer append_file. Rejects files over 20KB.",
    parameters={type="object", properties={path={type="string", description="File path"}, old_string={type="string", description="Exact text to find (must be unique unless replace_all)"}, new_string={type="string", description="Replacement text"}, replace_all={type="boolean", description="Replace all occurrences (default false)"}}, required={"path", "old_string", "new_string"}}
  }},
  {type="function", ["function"]={
    name="append_file",
    description="Append content to the end of a file (creates it if missing). O(1) memory regardless of file size — use for logs, growing records, or adding to large files without reading them first.",
    parameters={type="object", properties={path={type="string", description="File path"}, content={type="string", description="Content to append"}}, required={"path", "content"}}
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
    name="json_query",
    description="Extract a value from a JSON string using a dot path (e.g. 'hits.0.title', 'data.items.3.name'). Arrays are indexed from 0. Returns the matched value (JSON for objects/arrays, plain text for scalars). Use to parse component_invoke, web_search or file contents.",
    parameters={type="object", properties={json={type="string", description="JSON text to query"}, path={type="string", description="Dot-separated path, e.g. 'hits.0.title'"}}, required={"json", "path"}}
  }},
  {type="function", ["function"]={
    name="calc",
    description="Evaluate a safe arithmetic expression. Supports + - * / % ^, parentheses, and functions: sqrt, abs, floor, ceil, min, max. Does NOT execute code — use for math only. Example: 'sqrt(2)*10^3'",
    parameters={type="object", properties={expression={type="string", description="Arithmetic expression to evaluate"}}, required={"expression"}}
  }},
  {type="function", ["function"]={
    name="text_ops",
    description="String manipulation operations: find(text, pattern) -> position or nil; replace(text, old, new) -> new text; split(text, sep) -> numbered lines; slice(text, start, length); upper(text); lower(text); trim(text); length(text).",
    parameters={type="object", properties={op={type="string", description="Operation: find, replace, split, slice, upper, lower, trim, length"}, text={type="string", description="Input text"}, arg1={type="string", description="First argument (pattern/old/separator/start)"}, arg2={type="string", description="Second argument (new/length)"}}, required={"op", "text"}}
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

-- json_query: extract value from JSON via dot path (arrays 0-indexed)
local function json_query_code(json_str, path)
  if type(json_str) ~= "string" then return "Error: json argument must be a string" end
  local ok_decode, data, derr = pcall(json.decode, json_str)
  if not ok_decode then
    return "Error: invalid JSON: " .. tostring(data)
  end
  if data == nil and derr then
    return "Error: invalid JSON: " .. tostring(derr)
  end

  local cur = data
  if path == nil or path == "" then
    -- no path: return whole value
    if type(cur) == "table" then return json.encode(cur) end
    if type(cur) == "boolean" then return tostring(cur) end
    return tostring(cur or "null")
  end

  for seg in (path .. "."):gmatch("([^%.]+)%.") do
    if type(cur) ~= "table" then
      return "Error: cannot descend into " .. type(cur) .. " at '" .. seg .. "'"
    end
    local idx = tonumber(seg)
    local next_val
    if idx ~= nil then
      next_val = cur[idx + 1]  -- JSON array index → 1-based Lua table
    else
      next_val = cur[seg]
    end
    if next_val == nil then
      return "Error: path not found at '" .. seg .. "'"
    end
    cur = next_val
  end

  if type(cur) == "table" then return json.encode(cur) end
  if type(cur) == "boolean" then return tostring(cur) end
  return tostring(cur or "null")
end

-- calc: safe arithmetic expression evaluator (no code execution)
local function calc_code(expr)
  if type(expr) ~= "string" or expr == "" then
    return "Error: expression must be a non-empty string"
  end

  local pos = 1
  local function peek()
    while expr:sub(pos, pos):match("%s") do pos = pos + 1 end
    return expr:sub(pos, pos)
  end

  local function parse_primary()
    peek()
    local c = expr:sub(pos, pos)
    if c == "(" then
      pos = pos + 1
      local v = parse_expr()
      peek()
      if expr:sub(pos, pos) ~= ")" then error("expected ')'") end
      pos = pos + 1
      return v
    end
    -- function call: name(...)
    local name = expr:match("^([a-zA-Z_][a-zA-Z0-9_]*)%s*%(", pos)
    if name then
      pos = pos + #name
      peek()
      if expr:sub(pos, pos) ~= "(" then error("expected '(' after " .. name) end
      pos = pos + 1
      local args = {}
      peek()
      if expr:sub(pos, pos) ~= ")" then
        while true do
          args[#args + 1] = parse_expr()
          peek()
          local cc = expr:sub(pos, pos)
          if cc == "," then pos = pos + 1
          elseif cc == ")" then break
          else error("expected ',' or ')'") end
        end
      end
      pos = pos + 1
      local fns = {
        sqrt = function(x) return math.sqrt(x) end,
        abs = function(x) return math.abs(x) end,
        floor = function(x) return math.floor(x) end,
        ceil = function(x) return math.ceil(x) end,
        min = function(...) return math.min(...) end,
        max = function(...) return math.max(...) end,
      }
      if not fns[name] then error("unknown function: " .. name) end
      return fns[name](table.unpack(args))
    end
    local rest = expr:sub(pos)
    -- strict number: optional sign, digits, optional fraction; exponent handled
    -- separately (a capture group would return nil when the exponent is absent)
    local num = rest:match("^%-?%d+%.?%d*")
    if not num or num == "" then error("expected number at " .. pos) end
    local exp = rest:sub(#num + 1):match("^[eE][%-+]?%d+")
    if exp then num = num .. exp end
    pos = pos + #num
    return tonumber(num)
  end

  local function parse_unary()
    peek()
    if expr:sub(pos, pos) == "-" then
      pos = pos + 1
      return -parse_unary()
    end
    if expr:sub(pos, pos) == "+" then
      pos = pos + 1
      return parse_unary()
    end
    return parse_primary()
  end

  local function parse_power()
    local v = parse_unary()
    peek()
    if expr:sub(pos, pos) == "^" then
      pos = pos + 1
      return v ^ parse_power()
    end
    return v
  end

  local function parse_mul()
    local v = parse_power()
    while true do
      peek()
      local c = expr:sub(pos, pos)
      if c == "*" then pos = pos + 1; v = v * parse_power()
      elseif c == "/" then pos = pos + 1; v = v / parse_power()
      elseif c == "%" then pos = pos + 1; v = v % parse_power()
      else return v end
    end
  end

  local function parse_add()
    local v = parse_mul()
    while true do
      peek()
      local c = expr:sub(pos, pos)
      if c == "+" then pos = pos + 1; v = v + parse_mul()
      elseif c == "-" then pos = pos + 1; v = v - parse_mul()
      else return v end
    end
  end

  parse_expr = parse_add

  local ok, result = pcall(function()
    local v = parse_expr()
    peek()
    if pos <= #expr then error("trailing input at " .. pos) end
    return v
  end)
  if not ok then
    return "Error: invalid expression: " .. tostring(result)
  end
  -- Format: integer-valued results without trailing .0
  if type(result) == "number" then
    if math.abs(result % 1) < 1e-9 and math.abs(result) < 1e15 then
      return string.format("%d", result)
    end
    return tostring(result)
  end
  return tostring(result or "")
end

-- text_ops: string manipulation
local function text_ops_code(op, text, arg1, arg2)
  if type(text) ~= "string" then return "Error: text must be a string" end
  local fn = ({
    length = function() return tostring(#text) end,
    upper = function() return string.upper(text) end,
    lower = function() return string.lower(text) end,
    trim = function() return text:match("^%s*(.-)%s*$") end,
    find = function()
      local s, e = text:find(arg1 or "", 1, true)
      if not s then return "not found" end
      return "found at " .. s .. " (length " .. (e - s + 1) .. ")"
    end,
    replace = function()
      return (text:gsub(arg1 or "", arg2 or ""))
    end,
    slice = function()
      local start = tonumber(arg1) or 1
      local len = tonumber(arg2)
      if start < 1 then start = 1 end
      if len and len > 0 then
        return text:sub(start, start + len - 1)
      end
      return text:sub(start)
    end,
    split = function()
      local sep = arg1 or "\n"
      local parts = {}
      local n = 0
      for piece in (text .. sep):gmatch("(.-)" .. string.gsub(sep, "[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0")) do
        n = n + 1
        parts[#parts + 1] = n .. ". " .. piece
      end
      if n == 0 then return "(no parts)" end
      return table.concat(parts, "\n")
    end,
  })[op]

  if not fn then return "Error: unknown op: " .. tostring(op) end
  local ok, result = pcall(fn)
  if not ok then
    return "Error: " .. tostring(result)
  end
  return tostring(result or "")
end

function execute_lua_code(code)
  return "Error: execute_lua has been removed. Use json_query (JSON extraction), calc (math), or text_ops (string manipulation) instead."
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
      local offset = args.offset
      local limit = args.limit
      if offset == nil and limit == nil then
        -- Whole file (original behavior)
        local c = f:read("*a")
        f:close()
        return c
      end
      -- Line-slice mode: count lines first (needed for negative offset / tail)
      local total = 0
      for _ in f:lines() do total = total + 1 end
      f:close()
      local start = offset or 1
      if start < 0 then start = total + start + 1 end  -- e.g. -5 -> total-4
      if start < 1 then start = 1 end
      -- Re-open and collect the slice (O(target lines) memory)
      local f2 = io.open(args.path, "r")
      if not f2 then error("cannot reopen: " .. args.path) end
      local parts = {}
      local n = 0
      local collected = 0
      for line in f2:lines() do
        n = n + 1
        if n >= start then
          collected = collected + 1
          parts[#parts + 1] = n .. ". " .. line
          if limit and collected >= limit then break end
        end
      end
      f2:close()
      if #parts == 0 then
        return "no lines (file has " .. total .. " lines; offset " .. tostring(offset or 1) .. ")"
      end
      return table.concat(parts, "\n")
    end)
    return ok and result or ("Error: " .. tostring(result))

  elseif name == "edit_file" then
    local ok, result = pcall(function()
      local f = io.open(args.path, "r")
      if not f then error("file not found: " .. args.path) end
      local content = f:read("*a")
      f:close()
      if #content > 20000 then
        error("file too large for edit_file (" .. #content .. " bytes, max 20000). Use read_file with offset/limit + append_file.")
      end
      local old = args.old_string
      if old == nil or old == "" then error("old_string must be non-empty") end
      local new = args.new_string or ""
      -- Count occurrences (plain text, no patterns)
      local count = 0
      local pos = 1
      while true do
        local found = content:find(old, pos, true)
        if not found then break end
        count = count + 1
        pos = found + 1
      end
      if count == 0 then
        error("old_string not found in file")
      end
      if count > 1 and not args.replace_all then
        error("old_string found " .. count .. " times; use replace_all=true or a longer unique match")
      end
      local newContent
      if args.replace_all then
        -- literal replace-all: escape magic chars in pattern and % in replacement.
        -- NOTE: wrap inner gsub calls in parens — gsub returns (result, count),
        -- and a bare call as an argument would expand both values.
        local pat = (old:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1"))
        local repl = (new:gsub("%%", "%%%%"))
        newContent = content:gsub(pat, repl)
      else
        local idx = content:find(old, 1, true)
        newContent = content:sub(1, idx - 1) .. new .. content:sub(idx + #old)
      end
      local fw = io.open(args.path, "w")
      if not fw then error("cannot write: " .. args.path) end
      fw:write(newContent)
      fw:close()
      return "Replaced " .. (args.replace_all and count or 1) .. " occurrence(s) in " .. args.path
    end)
    return ok and result or ("Error: " .. tostring(result))

  elseif name == "append_file" then
    local ok, result = pcall(function()
      local f = io.open(args.path, "a")
      if not f then error("cannot open for append: " .. args.path) end
      f:write(args.content or "")
      f:close()
      return "Appended " .. (#(args.content or "") ) .. " bytes to " .. args.path
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

  elseif name == "json_query" then
    local ok, result = pcall(json_query_code, args.json, args.path)
    return ok and result or ("Error: " .. tostring(result))

  elseif name == "calc" then
    local ok, result = pcall(calc_code, args.expression)
    return ok and result or ("Error: " .. tostring(result))

  elseif name == "text_ops" then
    local ok, result = pcall(text_ops_code, args.op, args.text, args.arg1, args.arg2)
    return ok and result or ("Error: " .. tostring(result))

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

  return "You are an AI assistant running inside OpenComputers, a computer system in Minecraft (GT: New Horizons modpack). You can read and write files, list connected hardware components, run shell commands, and process data with utility tools.\n\n"
    .. "Available tools:\n"
    .. "- read_file: Read file contents (whole file, or a line slice with offset/limit; negative offset = tail; sliced reads show line numbers)\n"
    .. "- write_file: Write content to a file (new files or full rewrites)\n"
    .. "- edit_file: Replace an exact string in a file (must be unique; replace_all for multiple). Read first, keep files under 20KB\n"
    .. "- append_file: Append content to a file — use for logs and growing files, memory cost is constant regardless of file size\n"
    .. "- list_directory: List files in a directory\n"
    .. "- json_query: Extract a value from a JSON string using a dot path (e.g. 'hits.0.title'). Use to parse component_invoke, web_search or file contents.\n"
    .. "- calc: Evaluate a safe arithmetic expression (sqrt, abs, floor, ceil, min, max, + - * / % ^)\n"
    .. "- text_ops: String manipulation: find, replace, split, slice, upper, lower, trim, length\n"
    .. "- component_list: List connected OpenComputers components\n"
    .. "- component_doc: Get documentation for a component's methods (list methods or read one method's doc)\n"
    .. "- component_invoke: Call a method on a component (after checking component_doc)\n"
    .. "- web_search: Search the web for information (titles, URLs, snippets). Uses Tavily if configured, Hacker News otherwise.\n"
    .. "- shell_execute: Run an OpenOS shell command\n\n"
    .. "Data processing: use json_query to extract fields from JSON (e.g. component return values), calc for math, text_ops for string work. You cannot execute arbitrary Lua code.\n\n"
    .. "When exploring hardware, use this workflow:\n"
    .. "1. component_list to discover components\n"
    .. "2. component_doc(address) to learn what methods a component has\n"
    .. "3. component_doc(address, method) for method details, then component_invoke to call it\n\n"
    .. "Current computer address: " .. tostring(address) .. "\n"
    .. "Uptime: " .. string.format("%.1f", uptime) .. "s\n"
    .. "Free memory: " .. tostring(free_mem) .. " bytes\n"
    .. "Connected components:\n" .. table.concat(comp_list, "\n")
end

local function build_headers(config)
  local headers = {
    ["Content-Type"] = "application/json",
  }
  -- Only send auth when a real key is configured. Some free endpoints
  -- (e.g. OpenCode Zen free models) reject invalid bearer tokens with 401
  -- but accept requests without an Authorization header.
  if config.api_key and config.api_key ~= "" and config.api_key ~= "free" then
    headers["Authorization"] = "Bearer " .. config.api_key
  end
  return headers
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

  local headers = build_headers(config)

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

-- ── Section 5.5: Conversation Compaction ───────────────────────

-- forward declaration: msg_bytes is defined in Section 6
local msg_bytes

local COMPACT_KEEP = 4          -- recent messages kept verbatim after compaction
local COMPACT_TRIGGER_COUNT = 16  -- auto-compact when history exceeds this many messages
local COMPACT_TRIGGER_BYTES = 40000 -- ... or this many bytes (of the 50KB budget)

-- Ask the LLM to summarize older messages. Independent minimal request
-- (no tools, no system prompt) so it can't recurse into compaction.
-- Returns summary string or nil on any failure.
local function summarize_history(messages, config)
  local transcript_parts = {}
  for _, m in ipairs(messages) do
    local role = m.role or "?"
    local content = ""
    if m.content and m.content ~= "" then
      content = m.content
    elseif m.tool_calls then
      local names = {}
      for _, tc in ipairs(m.tool_calls) do
        names[#names + 1] = (tc["function"] and tc["function"].name) or "?"
      end
      content = "[tool_calls: " .. table.concat(names, ", ") .. "]"
    elseif m.role == "tool" then
      content = tostring(m.content):sub(1, 200)
    end
    if content ~= "" then
      transcript_parts[#transcript_parts + 1] = role .. ": " .. content
    end
  end
  local transcript = table.concat(transcript_parts, "\n")
  -- Cap what we send to the summarizer
  if #transcript > 12000 then
    transcript = transcript:sub(1, 12000) .. "\n...[truncated]"
  end

  local body = json.encode({
    model = config.model or "deepseek-v4-flash-free",
    messages = {
      {role = "system", content = "You are a conversation summarizer for an AI agent running inside OpenComputers (Minecraft). Summarize the following conversation, keeping: user goals and questions, decisions, tool results that matter, file paths, component addresses, and any constraints. Preserve factual details. Output only the summary, no preamble."},
      {role = "user", content = "Summarize this conversation:\n\n" .. transcript}
    },
    max_tokens = 1024,
    temperature = 0.2
  })

  local headers = build_headers(config)
  local code, resp, err = http_post(config.api_url or "https://opencode.ai/zen/v1/chat/completions", headers, body)
  if err then return nil end
  if not code or code ~= 200 then return nil end
  local data, derr = json.decode(resp)
  if not data then return nil end
  local choice = data.choices and data.choices[1]
  if not choice then return nil end
  local summary = choice.message and choice.message.content
  if not summary or summary == "" then return nil end
  return summary
end

-- Compact: replace older messages with an LLM summary, keep recent verbatim.
-- Returns new message list on success, nil on failure (caller falls back to trim).
local function compact_history(messages, config)
  if #messages <= COMPACT_KEEP + 1 then return nil end
  local old = {}
  for i = 1, #messages - COMPACT_KEEP do
    old[#old + 1] = messages[i]
  end
  local summary = summarize_history(old, config)
  if not summary then return nil end

  local result = {{role = "system", content = "[对话摘要] " .. summary}}
  for i = #messages - COMPACT_KEEP + 1, #messages do
    result[#result + 1] = messages[i]
  end
  return result
end

-- Decide whether compaction is worthwhile before trimming
local function should_compact(messages)
  if #messages <= COMPACT_KEEP + 1 then return false end
  if #messages >= COMPACT_TRIGGER_COUNT then return true end
  local total = 0
  for _, m in ipairs(messages) do
    total = total + msg_bytes(m)
    if total >= COMPACT_TRIGGER_BYTES then return true end
  end
  return false
end

-- ── Section 6: Config & History ────────────────────────────────

local CONFIG_PATH = "/home/agent_config.txt"
local HISTORY_PATH = "/home/agent_history.txt"
local MAX_HISTORY = 20
local MAX_HISTORY_BYTES = 50000  -- ~50KB budget; large tool results trimmed away
local MAX_TOOL_RESULT = 3000     -- per-tool-result cap for history persistence

msg_bytes = function(msg)
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

-- Append-only session log: each line is one JSON-encoded message.
-- Append per message (O(new) memory) instead of rewriting the whole history
-- (O(n) each call, O(n^2) cumulative). load_history replays + trims.
local function append_history(msg)
  local f = io.open(HISTORY_PATH, "a")
  if not f then return end
  f:write(json.encode(msg), "\n")
  f:close()
end

-- Full rewrite of the session log (after compaction / new session / reset).
local function rebuild_history(messages)
  local f = io.open(HISTORY_PATH, "w")
  if not f then return end
  for _, m in ipairs(messages) do
    f:write(json.encode(m), "\n")
  end
  f:close()
end

local function load_history()
  local fs = require("filesystem")
  if not fs.exists(HISTORY_PATH) then return {} end
  local f = io.open(HISTORY_PATH, "r")
  if not f then return {} end
  local content = f:read("*a")
  f:close()
  if content == "" then return {} end

  -- Legacy format (whole-table serialization): migrate once to JSON-line format.
  local ser = require("serialization")
  local ok, data = pcall(ser.unserialize, content)
  if ok and type(data) == "table" and (data[1] or data.role) then
    local list = data.role and {data} or data
    rebuild_history(list)  -- migrate
    return trim_history(list)
  end

  -- JSON-line format: one message per line, skip corrupt lines.
  local messages = {}
  for line in content:gmatch("[^\r\n]+") do
    local ok2, msg = pcall(json.decode, line)
    if ok2 and type(msg) == "table" and msg.role then
      messages[#messages + 1] = msg
    end
  end
  return trim_history(messages)
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
  elseif command == "/new" then
    -- Archive current session, start fresh (config kept)
    if #messages > 0 then
      local fs = require("filesystem")
      local ok_dir, dir_err = pcall(fs.makeDirectory, "/home/sessions")
      if not ok_dir then print("Note: cannot create /home/sessions (" .. tostring(dir_err) .. ")") end
      local stamp = tostring(os.time and pcall(os.time) and (select(2, pcall(os.time)) or "") or "")
      if stamp == "" then
        local comp = require("computer")
        stamp = string.format("%.0f", comp.uptime() or 0)
      end
      local archive_path = "/home/sessions/agent_history_" .. stamp .. ".txt"
      local ok_save, save_err = pcall(function()
        local f = io.open(archive_path, "w")
        if not f then error("cannot open " .. archive_path) end
        f:write(require("serialization").serialize(messages))
        f:close()
      end)
      if ok_save then
        print("Session archived to " .. archive_path)
      else
        print("Session archive failed: " .. tostring(save_err))
      end
    else
      print("No messages to archive")
    end
    messages = {}
    rebuild_history(messages)
    print("New session started")
  elseif command == "/compact" then
    if #messages == 0 then
      print("Nothing to compact")
    else
      print("Compacting conversation...")
      local compacted = compact_history(messages, config)
      if compacted then
        messages = compacted
        rebuild_history(messages)
        print("Compacted: " .. #messages .. " messages kept (summary + recent)")
      else
        print("Compaction failed (network or model error); conversation unchanged")
      end
    end
  elseif command == "/reset" then
    messages = {}
    rebuild_history(messages)
    print("History cleared")
  elseif command == "/hist" then
    print(#messages .. " messages in history")
  elseif command == "/tools" then
    for _, t in ipairs(TOOLS) do
      print("  " .. t["function"].name .. ": " .. t["function"].description)
    end
  elseif command == "/help" then
    print("Commands: /model /key /url /tavily /new /compact /reset /hist /tools /help /exit")
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
    -- Auto-compact before trimming when history gets large: summarize old
    -- context instead of dropping it. Falls back to trim on failure.
    if should_compact(messages) then
      io.write("Compacting conversation...\r")
      local compacted = compact_history(messages, config)
      if compacted then
        messages = compacted
        rebuild_history(messages)
      end
    end
    messages = trim_history(messages)
    -- append-only: persist just the new user message (old entries stay in the
    -- log; load_history trims on replay)
    append_history(messages[#messages])

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
      append_history(assistant_msg)  -- append-only: persist reply

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
        local tool_msg = {
          role = "tool",
          tool_call_id = tc.id,
          content = result
        }
        messages[#messages + 1] = tool_msg
        append_history(tool_msg)  -- append-only: persist tool result
      end
    end

    messages = trim_history(messages)

    ::continue::
  end

  print("Goodbye!")
end

if not _TEST_MODE then main() end

-- Test hooks (available when loaded with _TEST_MODE = true)
if _TEST_MODE then
  -- allow tests to redirect history storage (default: /home/agent_history.txt)
  local history_path_override
  local function set_history_path(p)
    history_path_override = p
  end
  -- rebind HISTORY_PATH usage: load/append/rebuild read this variable at call time
  -- (declared local above; we re-point the functions' captured upvalue via a
  -- small indirection)
  agent_test = {
    chat = chat,
    http_post = http_post,
    build_system_prompt = build_system_prompt,
    trim_history = trim_history,
    compact_history = compact_history,
    should_compact = should_compact,
    summarize_history = summarize_history,
    load_history = function()
      local saved = HISTORY_PATH
      if history_path_override then HISTORY_PATH = history_path_override end
      local r = load_history()
      HISTORY_PATH = saved
      return r
    end,
    append_history = function(msg)
      local saved = HISTORY_PATH
      if history_path_override then HISTORY_PATH = history_path_override end
      append_history(msg)
      HISTORY_PATH = saved
    end,
    rebuild_history = function(messages)
      local saved = HISTORY_PATH
      if history_path_override then HISTORY_PATH = history_path_override end
      rebuild_history(messages)
      HISTORY_PATH = saved
    end,
    set_history_path = set_history_path,
    TOOLS = TOOLS,
  }
end
