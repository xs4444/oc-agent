-- ═══════════════════════════════════════════════════════════════
-- agent.tools.search — web_search.
--
-- Module contract: exports {tools = {...}, exec = function(name, args,
-- deps)}. exec returns nil for tool names it does not handle. deps is
-- injected per call by agent.execute: json + load_config come from
-- agent.lua (never referenced as globals here).
-- ═══════════════════════════════════════════════════════════════

local tools = {
  {type="function", ["function"]={
    name="web_search",
    description="Search the web for information. Returns titles, URLs and snippets. Uses Tavily (general web, configurable via /tavily) or Hacker News Algolia (technical, no key needed) as fallback.",
    parameters={type="object", properties={query={type="string", description="Search query"}, limit={type="number", description="Max results (1-10, default 5)"}}, required={"query"}}
  }},
}

local function exec(name, args, deps)
  if name == "web_search" then
    local ok, result = pcall(function()
      local json = deps.json
      local query = tostring(args.query or "")
      local limit = math.floor(tonumber(args.limit) or 5)
      if limit < 1 then limit = 1 end
      if limit > 10 then limit = 10 end
      if query == "" then return "Error: query is required" end
      local internet = require("internet")
      local config_table = deps.load_config and deps.load_config() or {}
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
  end

  return nil  -- not handled by this module
end

return {tools = tools, exec = exec}
