-- ═══════════════════════════════════════════════════════════════
-- agent.tools.data — data tools: json_query / calc / text_ops.
--
-- Module contract: exports {tools = {...}, exec = function(name, args,
-- deps)}. exec returns nil for tool names it does not handle. deps is
-- injected per call by agent.execute; json comes from deps.json (the
-- same global table agent.lua defines in Phase 1 — never referenced
-- as a global here, so Phase 2 can swap in a json module).
-- ═══════════════════════════════════════════════════════════════

local tools = {
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
}

-- json_query: extract value from JSON via dot path (arrays 0-indexed)
local function json_query_code(json, json_str, path)
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

local function exec(name, args, deps)
  local json = deps.json
  if name == "json_query" then
    local ok, result = pcall(json_query_code, json, args.json, args.path)
    return ok and result or ("Error: " .. tostring(result))

  elseif name == "calc" then
    local ok, result = pcall(calc_code, args.expression)
    return ok and result or ("Error: " .. tostring(result))

  elseif name == "text_ops" then
    local ok, result = pcall(text_ops_code, args.op, args.text, args.arg1, args.arg2)
    return ok and result or ("Error: " .. tostring(result))
  end

  return nil  -- not handled by this module
end

return {tools = tools, exec = exec}
