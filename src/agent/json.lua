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

-- 缓冲式 encode（内存优化：P0 OOM 修复的治本——旧实现每层 json.encode()
-- 产生完整子串存 parts + 顶层 table.concat 再复制一次，且每个字符串
-- '"'..s..'"' 强制拼接副本；纯文本消息（无转义字符）时 gsub 返回原字符串
-- 引用（零复制），但拼接强制复制。新实现把片段直接 append 进 out 表：
--   1) 无转义的字符串零复制（gsub 无匹配返回原引用），仅最终 concat 一次
--   2) 数组/对象递归 append，不再产生每层子串
-- 峰值从 ~3x 文本降到 ~1.2x（输入原串已存在 + 最终结果一次分配），
-- 真机 55K tokens≈190KB 文本场景 encode 峰值 ~230KB 而非 ~570KB）
local function json_encode_to(out, val)
  local t = type(val)
  if val == nil then
    out[#out + 1] = "null"
  elseif t == "boolean" then
    out[#out + 1] = val and "true" or "false"
  elseif t == "number" then
    if val ~= val or val == math.huge or val == -math.huge then
      out[#out + 1] = "null"
    else
      out[#out + 1] = tostring(val)
    end
  elseif t == "string" then
    -- 无转义字符时 gsub 返回原字符串引用（零复制）——直接进缓冲；
    -- 引号/反斜杠/控制字符才产生转义副本（\u00XX 转义规则不变）。
    -- v0.3.125r7: 控制字符用显式范围 %z\1-\31\127 而**不用 %c 类**——
    -- 真机 GTNH fork 原生 C Lua 的 %c 类对长串（≥~450B）高字节误判
    -- （0xB1 被当控制字符，实证: 9KB 中文 encode 后每个 B1 变 \u00b1，
    -- decode 还原成 C2 B1，写文件静默损坏；短串/纯 %c 小字节不受影响，
    -- 400B 干净 500B 起坏）。显式类语义对低控制字符完全一致（实证
    -- \1/\9/\127 转义集合相同），高字节原样透传（RFC 8259 合法 raw
    -- UTF-8）。
    out[#out + 1] = '"'
    out[#out + 1] = val:gsub("[\\\"%z\1-\31\127]", function(c)
      local esc = ESCAPES[c]
      if esc then return esc end
      return string.format("\\u%04x", c:byte())
    end)
    out[#out + 1] = '"'
  elseif t == "table" then
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
      out[#out + 1] = "["
      for i = 1, #val do
        if i > 1 then out[#out + 1] = "," end
        json_encode_to(out, val[i])
      end
      out[#out + 1] = "]"
    else
      out[#out + 1] = "{"
      local first = true
      for k, v in pairs(val) do
        if type(k) == "string" then
          if not first then out[#out + 1] = "," end
          first = false
          json_encode_to(out, k)
          out[#out + 1] = ":"
          json_encode_to(out, v)
        end
      end
      out[#out + 1] = "}"
    end
  else
    error("json: cannot encode type " .. t)
  end
end

function json.encode(val)
  local out = {}
  json_encode_to(out, val)
  return table.concat(out)
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
          local combined = false
          if code then
            -- surrogate pair 合并（v0.3.125r2）: 高代理 \uD800-\uDBFF 后
            -- 紧跟低代理 \uDC00-\uDFFF → 合并成 >0xFFFF 码元 → 4 字节
            -- UTF-8（emoji 等，RFC 8259 surrogate pair 形式）。旧版无
            -- 合并：孤立代理走 3 字节路径产出无效 UTF-8（实证坑: Python
            -- json.dumps 默认 ensure_ascii=True 把 🌍 编成
            -- \uD83C\uDF0D，agent 解码成 6 字节乱码，回传 decode
            -- (replace) 显示 "??????"）。控制服务器/LLM 端点的代理对
            -- 形式自此可解。孤立代理（无后续低代理）仍走原 3 字节路径
            -- （与旧行为一致，容错不抛错）。
            if code >= 0xD800 and code <= 0xDBFF
              and str:sub(pos+1, pos+2) == "\\u" then
              local code2 = tonumber(str:sub(pos+3, pos+6), 16)
              if code2 and code2 >= 0xDC00 and code2 <= 0xDFFF then
                local cp = 0x10000 + (code - 0xD800) * 0x400 + (code2 - 0xDC00)
                result[#result+1] = string.char(
                  240 + math.floor(cp / 262144),
                  128 + math.floor(cp / 4096) % 64,
                  128 + math.floor(cp / 64) % 64,
                  128 + cp % 64)
                pos = pos + 6  -- 吃掉第二半 \uXXXX（外层 +1 过其末位）
                combined = true
              end
            end
            if not combined then
              if code < 128 then
                result[#result+1] = string.char(code)
              elseif code < 2048 then
                result[#result+1] = string.char(192 + math.floor(code/64), 128 + code%64)
              else
                result[#result+1] = string.char(224 + math.floor(code/4096), 128 + math.floor(code/64)%64, 128 + code%64)
              end
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
