-- ═══════════════════════════════════════════════════════════════
-- agent.tools.file — file tools: read_file / edit_file / append_file
-- / write_file / list_directory.
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
}

local function exec(name, args, deps)
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
  end

  return nil  -- not handled by this module
end

return {tools = tools, exec = exec}
