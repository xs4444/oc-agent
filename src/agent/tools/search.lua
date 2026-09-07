-- ═══════════════════════════════════════════════════════════════
-- agent.tools.search — web_search + web_fetch.
--
-- web_search 后端（按序）:
--   1. Tavily（config.tavily_key，/tavily <key>）— 通用+中文
--   2. Bing 抓取（无 key、通用+中文；真机出口可达，2026-09 实证
--      Cloudflare 系/DDG 不可达而 bing.com 可达且返回中文页）
--   3. Hacker News Algolia（无 key 技术内容兜底）
-- web_fetch: 抓 URL → HTML 转可读文本，封顶截断。OpenOS internet
-- 组件不跟随重定向——检测到 301/302/meta-refresh 时提示直连目标 URL。
--
-- 真机注意: 模式类里禁用 %c（C Lua %c 对长串 0xB1 高字节误判，r7b
-- 事故），一律用显式类 [\z\1-\31\127]。
--
-- Module contract: exports {tools = {...}, exec = function(name, args,
-- deps)}. exec returns nil for tool names it does not handle. deps is
-- injected per call by agent.execute: json + load_config come from
-- agent.lua (never referenced as globals here).
-- ═══════════════════════════════════════════════════════════════

local tools = {
  {type="function", ["function"]={
    name="web_search",
    description="Search the web. Returns titles, URLs and snippets. Backends in order: Tavily (if /tavily key set), Bing (general + Chinese, keyless), Hacker News Algolia (last resort). Find pages here, then read one with web_fetch.",
    parameters={type="object", properties={query={type="string", description="Search query"}, limit={type="number", description="Max results (1-10, default 5)"}}, required={"query"}}
  }},
  {type="function", ["function"]={
    name="web_fetch",
    description="Fetch a URL and return its content as readable text (HTML tags stripped, entities decoded). OpenOS internet does NOT follow redirects — if the result says 'redirected', fetch the target URL directly. Default cap 32KB; max_bytes up to 65536. GitHub raw/gist/issues/pull URLs are auto-rewritten to reachable equivalents (cdn.jsdelivr.net / api.github.com) when this machine's egress filters github 443 (GFW) — the result then starts with a 'GFW rewrite:' note.",
    parameters={type="object", properties={url={type="string", description="http(s) URL to fetch"}, max_bytes={type="number", description="Max bytes returned (1024-65536, default 32768)"}}, required={"url"}}
  }},
}

-- ── 纯函数辅助（可单测，_TEST_MODE 下经 _internal 暴露）────────────

-- GitHub GFW 改写（真机实测 2026-09-07: github.com/gist/raw 的 443 被 SNI 级
-- 黑洞[直连 ~25% 通、每次失败白等 ~21s]，而 api.github.com 与 cdn.jsdelivr.net
-- 100% 通）。把有确定等价物的 URL 形态改写到可达端点：
--   raw.githubusercontent.com/U/R/BR/PATH → cdn.jsdelivr.net/gh/U/R@BR/PATH
--   github.com/U/R/raw/BR/PATH            → cdn.jsdelivr.net/gh/U/R@BR/PATH
--   gist.github.com/[U/]ID[/...]           → api.github.com/gists/ID（JSON 含 files 内容）
--   github.com/U/R/issues/N | pull/N      → api.github.com/repos/U/R/issues(N|pull_requests/N)
-- 其余 github.com HTML 页面无确定等价物 → 返回 nil（直连，~25% 通）。
local function rewrite_github(url)
  local u, r, br, p = url:match("^https://raw%.githubusercontent%.com/([^/]+)/([^/]+)/([^/]+)/(.+)$")
  if u then return "https://cdn.jsdelivr.net/gh/" .. u .. "/" .. r .. "@" .. br .. "/" .. p end
  u, r, br, p = url:match("^https://github%.com/([^/]+)/([^/]+)/raw/([^/]+)/(.+)$")
  if u then return "https://cdn.jsdelivr.net/gh/" .. u .. "/" .. r .. "@" .. br .. "/" .. p end
  -- 带用户名模式必须先试：匿名模式的 ([0-9a-fA-F]+) 会吃掉十六进制前缀的
  -- 用户名（alice → "a"），且无尾锚
  local g = url:match("^https://gist%.github%.com/[^/]+/([0-9a-fA-F]+)")
  if g then return "https://api.github.com/gists/" .. g end
  g = url:match("^https://gist%.github%.com/([0-9a-fA-F]+)")
  if g then return "https://api.github.com/gists/" .. g end
  u, r, n = url:match("^https://github%.com/([^/]+)/([^/]+)/issues/([0-9]+)")
  if u then return "https://api.github.com/repos/" .. u .. "/" .. r .. "/issues/" .. n end
  u, r, n = url:match("^https://github%.com/([^/]+)/([^/]+)/pull/([0-9]+)")
  if u then return "https://api.github.com/repos/" .. u .. "/" .. r .. "/pull_requests/" .. n end
  return nil
end

local ENTITIES = {
  amp="&", lt="<", gt=">", quot='"', apos="'", nbsp=" ",
  ensp="\226\128\130",   -- U+2002，Bing 摘要日期分隔符高频
  mdash="\194\172\145", ndash="\194\172\173", hellip="\194\183\164",
  ldquo="\194\172\147", rdquo="\194\172\148", lsquo="\194\184\161", rsquo="\194\184\162",
  copy="\194\174\169", reg="\194\174\184", trade="\194\174\188",
}

local function utf8_char(n)
  if n < 0x80 then return string.char(n) end
  if n < 0x800 then
    return string.char(0xC0 + math.floor(n / 64), 0x80 + (n % 64))
  end
  if n < 0x10000 then
    return string.char(0xE0 + math.floor(n / 4096),
      0x80 + (math.floor(n / 64) % 64), 0x80 + (n % 64))
  end
  return nil
end

local function decode_entities(s)
  -- Lua 模式无 | 交替运算符（| 是字面量）——命名实体与数字实体
  -- 合并进一个字符类 [%w#] 解决。
  return (s:gsub("&([%w#]+);", function(tok)
    if tok:sub(1, 1) == "#" then
      local n = tonumber(tok:sub(2))
      if n and n > 0 then
        local c = utf8_char(n)
        return c or ("&" .. tok .. ";")
      end
      return "&" .. tok .. ";"
    end
    return ENTITIES[tok] or ("&" .. tok .. ";")
  end))
end

local function strip_tags(s)
  s = s:gsub("<script.-</script>", " ")
  s = s:gsub("<style.-</style>", " ")
  s = s:gsub("<[^>]*>", " ")
  return s
end

local BLOCK_TAGS = {
  "p", "div", "li", "h1", "h2", "h3", "h4", "h5", "h6",
  "tr", "table", "section", "article", "ul", "ol", "pre", "blockquote",
}

local function html_to_text(s)
  s = s:gsub("<script.-</script>", " ")
  s = s:gsub("<style.-</style>", " ")
  for _, tag in ipairs(BLOCK_TAGS) do
    s = s:gsub("</" .. tag .. ">", "\n")
  end
  s = s:gsub("<br%s*/%s*>", "\n")
  s = s:gsub("<[^>]*>", " ")
  s = decode_entities(s)
  s = s:gsub("[%z\1-\9\11-\31\127]", "")   -- 控制字符（保留 \n=\10）
  s = s:gsub("[%z\1-\9\11-\31\127\t\r ]+", " ")  -- 横向空白折叠（排除 \n）
  s = s:gsub(" ?\n ?", "\n")
  s = s:gsub("\n\n+", "\n\n")
  return (s:match("^%s*(.-)%s*$") or "")
end

local function urlencode(s)
  return (s:gsub("([^%w%-%.%_%~])", function(c)
    return string.format("%%%02X", c:byte())
  end))
end

local function parse_bing(body, limit)
  local out = {}
  for block in body:gmatch('<li class="b_algo[^"]*"[^>]*>.-</li>') do
    if #out >= limit then break end
    local url, title = block:match('h2[^>]*>.-<a[^>]*href="([^"]+)"[^>]*>(.-)</a>')
    if not (url and title) then
      url, title = block:match('<a[^>]*href="([^"]+)"[^>]*>(.-)</a>')
    end
    -- Lua 模式无交替：bing 站内链用三次 find 覆盖三种前缀
    local is_internal = url:find("^https?://bing%.com")
      or url:find("^https?://www%.bing%.com")
      or url:find("^https?://login%.bing%.com")
    if url and title and url:find("^https?://") and not is_internal then
      local title_txt = (title:gsub("<[^>]*>", ""))
      title_txt = decode_entities(title_txt):gsub("%s+", " ")
      title_txt = title_txt:match("^%s*(.-)%s*$") or title_txt
      local snip = block:match("<p[^>]*>(.-)</p>")
      local snip_txt = ""
      if snip then
        snip_txt = decode_entities(strip_tags(snip)):gsub("%s+", " ")
        snip_txt = snip_txt:match("^%s*(.-)%s*$") or snip_txt
      end
      out[#out + 1] = {title = title_txt, url = url, snippet = snip_txt}
    end
  end
  return out
end

-- ── exec ───────────────────────────────────────────────────────

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
          -- Yield on EVERY chunk: http.lua warns that otherwise the
          -- computer crashes with "too long without yielding".
          for chunk in handle do
            chunks[#chunks + 1] = chunk
            os.sleep(0.02)
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
      end

      -- 后端 2: Bing 抓取（真机出口可达；解析失败/无结果时落到 HN）
      local bing_err
      local items
      do
        local burl = "https://www.bing.com/search?q=" .. urlencode(query) .. "&count=" .. limit
        local okr, handle = pcall(function() return internet.request(burl) end)
        if okr then
          local resp = read_all(handle)
          items = parse_bing(resp, limit)
          if #items == 0 then bing_err = "no parseable results" end
        else
          bing_err = tostring(handle)
        end
      end
      if items and #items > 0 then
        local out = {}
        for i, r in ipairs(items) do
          out[#out + 1] = string.format("%d. %s\n   %s\n   %s", i, r.title, r.url, r.snippet)
        end
        return table.concat(out, "\n")
      end

      -- 后端 3: Hacker News Algolia 兜底
      local url = "https://hn.algolia.com/api/v1/search?query=" .. query:gsub(" ", "+") .. "&hitsPerPage=" .. limit .. "&tags=story"
      local okr, handle = pcall(function()
        return internet.request(url)
      end)
      if not okr then
        return "Error: all search backends failed (Bing: " .. tostring(bing_err) .. "; HN: " .. tostring(handle) .. ")"
      end
      local resp = read_all(handle)
      local data, err = json.decode(resp)
      if not data then
        return "HN parse error: " .. tostring(err) .. " (Bing: " .. tostring(bing_err) .. ")"
      end
      local hits = data.hits or {}
      local out = {}
      for i, h in ipairs(hits) do
        if i > limit then break end
        local title = h.title or h.story_title or ""
        local hurl = h.url or ("https://news.ycombinator.com/item?id=" .. tostring(h.objectID or ""))
        out[#out + 1] = string.format("%d. %s\n   %s", i, tostring(title), tostring(hurl))
      end
      if #out == 0 then
        return "(no results: Bing " .. tostring(bing_err) .. ", Hacker News empty)"
      end
      return "(Bing unavailable/empty — " .. tostring(bing_err) .. "; Hacker News fallback)\n" .. table.concat(out, "\n")
    end)
    return ok and result or ("Error: " .. tostring(result))
  end

  if name == "web_fetch" then
    local ok, result = pcall(function()
      local url = tostring(args.url or "")
      if not url:match("^https?://") then
        return "Error: url must start with http:// or https://"
      end
      local max_bytes = math.floor(tonumber(args.max_bytes) or 32768)
      if max_bytes < 1024 then max_bytes = 1024 end
      if max_bytes > 65536 then max_bytes = 65536 end
      -- GitHub GFW 改写（见 rewrite_github）——命中则改道可达端点
      local rw = rewrite_github(url)
      local note = rw and ("GFW rewrite: " .. rw .. "\n") or ""
      if rw then url = rw end
      local internet = require("internet")
      local okr, handle = pcall(function() return internet.request(url) end)
      if not okr then return "fetch error: " .. tostring(handle) end

      local chunks, total = {}, 0
      local ok_iter, err_iter = pcall(function()
        for chunk in handle do
          chunks[#chunks + 1] = chunk
          total = total + #chunk
          if total >= max_bytes then break end
          os.sleep(0.02)
        end
      end)
      if not ok_iter then return "fetch read failed: " .. tostring(err_iter) end
      local body = table.concat(chunks)

      -- 重定向检测（OpenOS internet 组件不跟随）
      local redir_target
      if body:find("Moved Permanently") or body:find("301") and body:find("<title>301")
         or body:find("302 Found") then
        redir_target = body:match('<a href="([^"]+)"')
      end
      if not redir_target then
        redir_target = body:match('<meta[^>]*refresh[^>]*url="?([^"& ]+)')
      end
      if redir_target then
        return "redirected (OpenOS internet does not follow redirects) to: "
          .. redir_target .. " — fetch that URL directly."
      end

      local text = html_to_text(body)
      if text == "" then return note .. "(empty page)" end
      local truncated = #body > max_bytes
      text = text:sub(1, max_bytes)
      if truncated then
        text = text .. "\n…[truncated at " .. max_bytes .. " bytes of " .. #body .. "]"
      end
      return note .. text
    end)
    return ok and result or ("Error: " .. tostring(result))
  end

  return nil  -- not handled by this module
end

local M = {tools = tools, exec = exec}
if _TEST_MODE then
  M._internal = {
    urlencode = urlencode, decode_entities = decode_entities,
    html_to_text = html_to_text, strip_tags = strip_tags, parse_bing = parse_bing,
    utf8_char = utf8_char, rewrite_github = rewrite_github,
  }
end
return M
