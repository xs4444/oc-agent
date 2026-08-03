-- ═══════════════════════════════════════════════════════════════
-- agent.json — JSON codec (Phase 2 split).
--
-- Verbatim move of the old agent.lua Section 1. Note: the original
-- code assigns the GLOBAL `json` table and refers to `json.encode`
-- recursively from inside the codec; that is preserved exactly so
-- behavior (and the global for tests) is unchanged. The module also
-- returns the same table, so `require("agent.json")` is usable.
-- ═══════════════════════════════════════════════════════════════

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

return json
