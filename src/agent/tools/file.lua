-- ═══════════════════════════════════════════════════════════════
-- agent.tools.file — file tools: read_file / edit_file / append_file
-- / write_file / list_directory / search_files / glob.
--
-- search_files and glob are ported from oc-ai lib/cmn-utils/grep.lua
-- and glob.lua (recursive directory search + line numbers + literal/
-- Lua pattern + glob filter + max results/line length caps).
--
-- Module contract: exports {tools = {...}, exec = function(name, args,
-- deps)}. exec returns nil for tool names it does not handle. deps is
-- injected per call by agent.execute (via agent.lua's execute_tool).
-- ═══════════════════════════════════════════════════════════════

local tools = {
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
    name="search_files",
    description="Search file contents for a pattern, returning matching lines as 'path:line: content' (one per line). Recurses directories. pattern is a Lua pattern by default; set literal=true to match a literal string. path is the file or directory to search (default: current directory). glob restricts which files are searched (e.g. '*.lua'). max_results caps the number of matches (default 50); max_line_length truncates long lines (default 200).",
    parameters={type="object", properties={
      pattern={type="string", description="Pattern to search for (Lua pattern unless literal=true)"},
      path={type="string", description="File or directory to search (default: current directory)"},
      glob={type="string", description="Only search files matching this glob pattern (e.g. '*.lua')"},
      literal={type="boolean", description="Treat pattern as a literal string (default false)"},
      max_results={type="number", description="Maximum number of results (default 50)"},
      max_line_length={type="number", description="Maximum line length to return (default 200)"}
    }, required={"pattern"}}
  }},
  {type="function", ["function"]={
    name="glob",
    description="Find files matching a glob pattern, recursively. Returns matching paths relative to path (one per line). Supports '*' (within a path segment) and '**' (across segments), e.g. '*.lua' or 'lib/**/*.lua'. path is the starting directory (default: current directory).",
    parameters={type="object", properties={
      pattern={type="string", description="Glob pattern to match (e.g. '*.lua', 'lib/**/*.lua')"},
      path={type="string", description="Starting directory (default: current directory)"}
    }, required={"pattern"}}
  }},
}

-- ═══════════════════════════════════════════════════════════════
-- search_files / glob — grep/glob file search (ported from oc-ai
-- lib/cmn-utils/grep.lua and lib/cmn-utils/glob.lua).
--
-- Path handling is deliberately portable: io.open works in every
-- environment (real OpenOS, host mock, tests), so it is the primary
-- file/dir discriminator; fs.isDirectory / fs.list are used as
-- fallbacks for hosts whose isDirectory is unreliable (e.g. oc_mock
-- returns false always). fs.concat/fs.name are not used because the
-- mock lacks them — plain string ops instead.
-- ═══════════════════════════════════════════════════════════════

-- Escape Lua pattern magic characters for literal search
local function escape_literal(str)
  return (str:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1"))
end

-- UTF-8 安全截断: 取前 n 字节，回退到字符边界（不劈裂多字节字符）。
-- 续字节 = 0x80-0xBF；单字节 < 0x80；起始字节 0xC0+。
local function utf8_cut(s, n)
  if not s or #s <= n then return s end
  local cut = n
  while cut < #s and cut >= 1 do
    local b = s:byte(cut + 1)
    if not b or b < 0x80 or b >= 0xC0 then break end
    cut = cut - 1
  end
  if cut < 0 then cut = 0 end
  return s:sub(1, cut)
end

-- Convert a glob pattern to a Lua pattern. Supports '*' (within a
-- path segment) and '**' (across segments): e.g. '*.lua', 'lib/**/*.lua'.
local function glob_to_lua_pattern(glob_pat)
  local pat = glob_pat
  pat = (pat:gsub("([%^%$%(%)%%%.%[%]%+%-%?])", "%%%1"))
  pat = (pat:gsub("%*%*", "\001"))
  pat = (pat:gsub("%*", "[^/]*"))
  pat = (pat:gsub("\001", ".*"))
  return "^" .. pat .. "$"
end

-- Simple name glob match ('*' = anything), used for the search_files
-- glob filter on file names (e.g. '*.lua'). Returns true when no
-- filter is given.
local function glob_match(name, pattern)
  if not pattern then return true end
  local pat = pattern
  pat = (pat:gsub("([%^%$%(%)%%%.%[%]%+%-%?])", "%%%1"))
  pat = (pat:gsub("%*", ".*"))
  return name:match("^" .. pat .. "$") ~= nil
end

-- Last path component (portable fs.name)
local function path_name(p)
  local name = p:match("([^/\\]+)[/\\]*$")
  return name or p
end

-- Classify a path: "file", "dir" or "missing". io.open first (works
-- everywhere — opening a directory fails), then fs.isDirectory, then
-- fs.list (for hosts whose isDirectory always returns false).
local function classify_path(path, fs)
  local f = io.open(path, "r")
  if f then
    f:close()
    return "file"
  end
  if fs and fs.isDirectory then
    local ok, r = pcall(fs.isDirectory, path)
    if ok and r then return "dir" end
  end
  if fs and fs.list then
    local ok, it = pcall(fs.list, path)
    if ok and type(it) == "function" then
      if it() then return "dir" end
    end
  end
  return "missing"
end

-- search_files: recursive content search.
-- args: pattern, path, glob, literal, max_results, max_line_length.
-- Returns one 'path:line: content' line per match.
local function search_files_code(args)
  local ok_fs, fs = pcall(require, "filesystem")
  local pattern = args.pattern
  if type(pattern) ~= "string" or pattern == "" then
    error("pattern must be a non-empty string")
  end
  local base = (args.path ~= nil and args.path ~= "") and args.path or "."
  local max_results = tonumber(args.max_results) or 50
  local max_line_length = tonumber(args.max_line_length) or 200
  local glob_filter = args.glob

  local pat = pattern
  if args.literal then
    pat = escape_literal(pat)
  end

  local results = {}
  local truncated = false

  -- Search one file; returns true when the result cap is reached.
  local function search_file(full_path, rel_path)
    local f = io.open(full_path, "r")
    if not f then return false end
    local line_num = 0
    for line in f:lines() do
      line_num = line_num + 1
      local ok_find, found = pcall(line.find, line, pat)
      if ok_find and found then
        local shown = line
        -- 超长行: UTF-8 安全截断 + 显式标记（pi 风格，不静默丢内容）
        if #shown > max_line_length then
          shown = utf8_cut(shown, max_line_length)
            .. " ... [line truncated at " .. max_line_length .. "]"
        end
        results[#results + 1] = rel_path .. ":" .. line_num .. ": " .. shown
        if #results >= max_results then
          truncated = true
          f:close()
          return true
        end
      end
    end
    f:close()
    return false
  end

  local stopped = false
  local function walk(dir, prefix)
    if stopped then return end
    local kind = classify_path(dir, fs)
    if kind == "file" then
      -- Single-file target: glob filter applies to the file name
      if glob_match(path_name(dir), glob_filter) then
        if search_file(dir, prefix) then stopped = true end
      end
      return
    end
    if kind ~= "dir" then return end
    local ok_list, it = pcall(function() return fs.list(dir) end)
    if not ok_list or type(it) ~= "function" then return end
    for entry in it do
      if stopped then return end
      local full = dir .. "/" .. entry
      local rel = prefix == "" and entry or (prefix .. "/" .. entry)
      local sub = classify_path(full, fs)
      if sub == "dir" then
        walk(full, rel)
      elseif sub == "file" then
        if glob_match(entry, glob_filter) then
          if search_file(full, rel) then
            stopped = true
            return
          end
        end
      end
    end
  end

  local base_kind = classify_path(base, fs)
  local prefix = base_kind == "file" and path_name(base) or ""
  walk(base, prefix)

  if #results == 0 then
    return "No matches for '" .. tostring(args.pattern) .. "' in " .. base
  end
  local out = {("Match " .. #results .. " for '" .. tostring(args.pattern)
    .. "' in " .. base .. ":")}
  for i = 1, #results do
    out[#out + 1] = results[i]
  end
  if truncated then
    out[#out + 1] = "(results truncated at " .. max_results .. ")"
  end
  return table.concat(out, "\n")
end

-- glob: recursive glob pattern match over relative paths.
-- args: pattern, path.
local function glob_code(args)
  local ok_fs, fs = pcall(require, "filesystem")
  local pattern = args.pattern
  if type(pattern) ~= "string" or pattern == "" then
    error("pattern must be a non-empty string")
  end
  local base = (args.path ~= nil and args.path ~= "") and args.path or "."
  local lua_pat = glob_to_lua_pattern(pattern)
  local matches = {}

  local function walk(dir, prefix)
    if classify_path(dir, fs) ~= "dir" then return end
    local ok_list, it = pcall(function() return fs.list(dir) end)
    if not ok_list or type(it) ~= "function" then return end
    for entry in it do
      local full = dir .. "/" .. entry
      local rel = prefix == "" and entry or (prefix .. "/" .. entry)
      if classify_path(full, fs) == "dir" then
        walk(full, rel)
      else
        if rel:match(lua_pat) then
          matches[#matches + 1] = rel
        end
      end
    end
  end

  walk(base, "")
  table.sort(matches)
  if #matches == 0 then
    return "No files match '" .. tostring(args.pattern) .. "' in " .. base
  end
  return table.concat(matches, "\n")
end

local function exec(name, args, deps)
  if name == "read_file" then
    local ok, result = pcall(function()
      local f = io.open(args.path, "r")
      if not f then error("file not found: " .. args.path) end
      local offset = args.offset
      local limit = args.limit
      -- 无 offset/limit 的默认读: 有行/字节上限，避免大文件全量回传。
      -- 上限与 edit_file 的 20KB 预算一致; 超限时尾注给出续读指引。
      local READ_MAX_LINES = 400
      local READ_MAX_BYTES = 20000
      if offset == nil and limit == nil then
        local parts = {}
        local n = 0
        local total_bytes = 0
        for line in f:lines() do
          n = n + 1
          total_bytes = total_bytes + #line + 1
          if n > READ_MAX_LINES or total_bytes > READ_MAX_BYTES then
            f:close()
            -- 截断: 返回已收集的行 + 尾注（提示用 offset 续读）
            local out = table.concat(parts, "\n")
            local shown = #parts
            return out .. "\n...(truncated: showing first " .. shown
              .. " lines; use read_file with offset=" .. (shown + 1)
              .. " to continue)"
          end
          parts[#parts + 1] = line
        end
        f:close()
        return table.concat(parts, "\n")
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
      local out = table.concat(parts, "\n")
      -- 切片结果仍超上限（limit 参数过大）: 同样尾注
      if #out > READ_MAX_BYTES then
        out = out:sub(1, READ_MAX_BYTES)
          .. "\n...(truncated: slice output exceeds " .. READ_MAX_BYTES
          .. " bytes; use read_file with a smaller limit to continue)"
      end
      return out
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

  elseif name == "search_files" then
    local ok, result = pcall(search_files_code, args)
    return ok and result or ("Error: " .. tostring(result))

  elseif name == "glob" then
    local ok, result = pcall(glob_code, args)
    return ok and result or ("Error: " .. tostring(result))
  end

  return nil  -- not handled by this module
end

return {tools = tools, exec = exec}
