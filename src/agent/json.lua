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

-- JSON 字符串转义（模块级映射，避免每次 encode 重建表）
-- 除 \ " \n \r \t 外，所有控制字符（\x00-\x1f、\x7f）必须转义为 \u00XX，
-- 否则裸控制字符产出非法 JSON，服务端解析失败返回 HTTP 400
local ESCAPES = {
  ["\\"] = "\\\\",
  ['"'] = '\\"',
  ["\n"] = "\\n",
  ["\r"] = "\\r",
  ["\t"] = "\\t",
}

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
    local s = val:gsub("[\\\"%c]", function(c)
      local esc = ESCAPES[c]
      if esc then return esc end
      return string.format("\\u%04x", c:byte())
    end)
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
  local n = #str

  -- byte-based 跳过空白（兼容 Lua %s 全集: 空格/Tab/LF/FF/CR/VT——
  -- 与旧版 str:find("^[%s]*") 行为一致）
  local function skip_ws()
    while pos <= n do
      local b = str:byte(pos)
      if b == 32 or b == 9 or b == 10 or b == 11 or b == 12 or b == 13 then
        pos = pos + 1
      else
        break
      end
    end
  end

  local function parse_string()
    pos = pos + 1  -- skip opening quote
    local result = {}
    while pos <= n do
      local b = str:byte(pos)
      if b == 34 then  -- closing quote
        pos = pos + 1
        return table.concat(result)
      elseif b == 92 then  -- backslash escape
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
        -- 批量收集普通字符段（byte 定位边界，一次 sub 取整段——
        -- 替代逐字符 sub，消除每字符 1 个临时字符串对象）
        local start = pos
        while pos <= n do
          local b2 = str:byte(pos)
          if b2 == 34 or b2 == 92 then break end
          pos = pos + 1
        end
        result[#result+1] = str:sub(start, pos - 1)
      end
    end
    error("json: unterminated string")
  end

  local function parse_number()
    local start = pos
    if str:byte(pos) == 45 then pos = pos + 1 end  -- '-'
    while pos <= n do
      local b = str:byte(pos)
      -- 0-9 e E + - .（与旧版 c:match("[0-9eE+%.%-]") 一致）
      if (b >= 48 and b <= 57) or b == 101 or b == 69 or b == 43 or b == 45 or b == 46 then
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
    if str:byte(pos) == 93 then pos = pos + 1; return arr end  -- ']'
    while true do
      arr[#arr + 1] = parse_value()
      skip_ws()
      local c = str:byte(pos)
      if c == 93 then pos = pos + 1; return arr end
      if c ~= 44 then error("json: expected ',' or ']' at " .. pos) end  -- ','
      pos = pos + 1
      skip_ws()
    end
  end

  local function parse_object()
    pos = pos + 1
    local obj = {}
    skip_ws()
    if str:byte(pos) == 125 then pos = pos + 1; return obj end  -- '}'
    while true do
      skip_ws()
      if str:byte(pos) ~= 34 then error("json: expected key string at " .. pos) end  -- '"'
      local key = parse_string()
      skip_ws()
      if str:byte(pos) ~= 58 then error("json: expected ':' at " .. pos) end  -- ':'
      pos = pos + 1
      skip_ws()
      obj[key] = parse_value()
      skip_ws()
      local c = str:byte(pos)
      if c == 125 then pos = pos + 1; return obj end
      if c ~= 44 then error("json: expected ',' or '}' at " .. pos) end
      pos = pos + 1
    end
  end

  parse_value = function()
    skip_ws()
    local c = str:byte(pos)
    if c == 34 then return parse_string()      -- '"'
    elseif c == 123 then return parse_object()  -- '{'
    elseif c == 91 then return parse_array()    -- '['
    -- 关键字必须完整匹配（byte 只验证首字节，后续仍需校验——
    -- 否则 "tru"/"f"/"n" 会被错误接受）
    elseif c == 116 and str:sub(pos, pos + 3) == "true" then pos = pos + 4; return true
    elseif c == 102 and str:sub(pos, pos + 4) == "false" then pos = pos + 5; return false
    elseif c == 110 and str:sub(pos, pos + 3) == "null" then pos = pos + 4; return nil
    elseif c == 45 or (c >= 48 and c <= 57) then return parse_number()
    else error("json: unexpected char at " .. pos) end
  end

  local result = parse_value()
  skip_ws()
  if pos <= #str then error("json: trailing data at " .. pos) end
  return result
end

return json
