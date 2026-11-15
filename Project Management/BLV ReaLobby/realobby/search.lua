-- Search, view filtering and column sorting over SongViews.
--
-- filter(songs, query, view) -> new table.
--   * Views: all = every non-hidden song; recent = songs in REAPER's recent
--     list (s.recent, set by the library) or opened through ReaLobby
--     (s.opened); pinned, status=<name>, artist=<name> (case-insensitive),
--     hidden = hidden and archived songs only. Every view except hidden drops
--     hidden and archived songs (s.archived, ruling R28).
--   * Empty query: the view's songs in input order.
--   * Non-empty query: every whitespace-separated word must be a substring of
--     at least one field (title, author, notes, fx name/file, folder of the
--     newest version), compared lowercase with common Latin accents folded.
--     Results are ordered by score (sum over words of the best field weight:
--     title 4, author 3, notes/fx/folder 1), highest first; ties keep input
--     order.
--   * Filters (M.parse): a word "name:value" with a known name narrows the
--     songs instead of being searched for. bpm:95-100, bpm:>120, bpm:100
--     (tempo); tracks:>20; time:>2h (time worked, see realobby/timelog.lua);
--     saved:<7d, opened:>30d (age: h, d, w, mo, y; "<" means newer than,
--     ">" older than, no sign means within); status:mixing, artist:xi (also
--     by:), uses:pro-q (also fx:, a plug-in name or file) match folded
--     substrings. A value can be quoted: uses:"pro-q 3". A filter whose value
--     cannot be read is searched for as a plain word.
--   * When the query has words the UI does not call sort: the ranking is
--     the order. A query of filters only keeps the column sort.
-- sort(songs, column, descending) -> new table; never mutates its input.
--   Missing values sort last in both directions; ties break by display_title
--   then key (folded), then input order.
local M = {}

local FOLD = {
  ["\xC3\xA0"] = "a", ["\xC3\xA1"] = "a", ["\xC3\xA2"] = "a", ["\xC3\xA3"] = "a",
  ["\xC3\xA4"] = "a", ["\xC3\xA5"] = "a", ["\xC3\xA7"] = "c",
  ["\xC3\xA8"] = "e", ["\xC3\xA9"] = "e", ["\xC3\xAA"] = "e", ["\xC3\xAB"] = "e",
  ["\xC3\xAC"] = "i", ["\xC3\xAD"] = "i", ["\xC3\xAE"] = "i", ["\xC3\xAF"] = "i",
  ["\xC3\xB1"] = "n",
  ["\xC3\xB2"] = "o", ["\xC3\xB3"] = "o", ["\xC3\xB4"] = "o", ["\xC3\xB5"] = "o", ["\xC3\xB6"] = "o",
  ["\xC3\xB9"] = "u", ["\xC3\xBA"] = "u", ["\xC3\xBB"] = "u", ["\xC3\xBC"] = "u",
  ["\xC3\xBD"] = "y", ["\xC3\xBF"] = "y",
  ["\xC3\x80"] = "a", ["\xC3\x81"] = "a", ["\xC3\x82"] = "a", ["\xC3\x83"] = "a",
  ["\xC3\x84"] = "a", ["\xC3\x85"] = "a", ["\xC3\x87"] = "c",
  ["\xC3\x88"] = "e", ["\xC3\x89"] = "e", ["\xC3\x8A"] = "e", ["\xC3\x8B"] = "e",
  ["\xC3\x8C"] = "i", ["\xC3\x8D"] = "i", ["\xC3\x8E"] = "i", ["\xC3\x8F"] = "i",
  ["\xC3\x91"] = "n",
  ["\xC3\x92"] = "o", ["\xC3\x93"] = "o", ["\xC3\x94"] = "o", ["\xC3\x95"] = "o", ["\xC3\x96"] = "o",
  ["\xC3\x99"] = "u", ["\xC3\x9A"] = "u", ["\xC3\x9B"] = "u", ["\xC3\x9C"] = "u",
  ["\xC3\x9D"] = "y",
  ["\xC5\x93"] = "oe", ["\xC5\x92"] = "oe", ["\xC3\xA6"] = "ae", ["\xC3\x86"] = "ae",
  ["\xC3\x9F"] = "ss",
}

-- Lowercase (ASCII), then fold accents; string.lower is ASCII-only.
local function fold(s)
  if s == nil then return "" end
  s = tostring(s):lower()
  if s:find("[\xC3\xC5]") then
    s = s:gsub("[\xC3\xC5][\x80-\xBF]", FOLD)
  end
  return s
end
M.fold = fold

local function dirname(path)
  local d = tostring(path or ""):match("^(.*)[/\\][^/\\]*$")
  return d or ""
end

local function in_view(s, view)
  local group = view and view.group or "all"
  if group == "hidden" then return (s.hidden or s.archived) and true or false end
  if s.hidden or s.archived then return false end
  if group == "pinned" then return s.pinned and true or false end
  if group == "recent" then return (s.recent or s.opened) and true or false end
  if group == "status" then return s.status == (view and view.value) end
  if group == "artist" then
    return fold(s.display_author) == fold(view and view.value)
  end
  return true -- all
end

local function fields(s)
  local info = s.info or {}
  local f = {
    title = fold(s.display_title),
    author = fold(s.display_author),
    notes = fold(info.notes),
    folder = fold(dirname(s.newest)),
    fx = {},
  }
  for _, fx in ipairs(info.fx or {}) do
    f.fx[#f.fx + 1] = fold(fx.name)
    f.fx[#f.fx + 1] = fold(fx.file)
  end
  return f
end

local function has(hay, word) return hay ~= "" and hay:find(word, 1, true) ~= nil end

local function score(f, words)
  local total = 0
  for _, w in ipairs(words) do
    local best = 0
    if has(f.title, w) then best = 4
    elseif has(f.author, w) then best = 3
    else
      if has(f.notes, w) or has(f.folder, w) then best = 1 end
      if best == 0 then
        for _, x in ipairs(f.fx) do
          if has(x, w) then best = 1; break end
        end
      end
    end
    if best == 0 then return nil end
    total = total + best
  end
  return total
end

-- Filters -------------------------------------------------------------------

local UNIT = { h = 3600, d = 86400, w = 7 * 86400, mo = 30 * 86400, y = 365 * 86400 }
local TIME_UNIT = { m = 60, min = 60, h = 3600 }

-- "95-100", ">120", ">=120", "<7", "100" -> { lo, hi } (inclusive, nil = open)
-- with read(text) -> number|nil for each bound.
local function range(v, read)
  local a, b = v:match("^([^%-<>=]+)%-([^%-<>=]+)$")
  if a then
    local lo, hi = read(a), read(b)
    if lo and hi then
      if lo > hi then lo, hi = hi, lo end
      return { lo = lo, hi = hi }
    end
    return nil
  end
  local op, rest = v:match("^([<>]=?)(.+)$")
  if op then
    local n = read(rest)
    if not n then return nil end
    if op:sub(1, 1) == ">" then return { lo = n, strict_lo = op == ">" } end
    return { hi = n, strict_hi = op == "<" }
  end
  local n = read(v)
  if n then return { lo = n, hi = n, exact = true } end
  return nil
end

local function in_range(r, x)
  if x == nil then return false end
  if r.lo and (x < r.lo or (r.strict_lo and x == r.lo)) then return false end
  if r.hi and (x > r.hi or (r.strict_hi and x == r.hi)) then return false end
  return true
end

local function number(t) return tonumber(t) end

local function age(t)
  local n, u = t:match("^(%d+%.?%d*)(%a+)$")
  if not n then n, u = t:match("^(%d+%.?%d*)$"), "d" end
  if not n or not UNIT[u] then return nil end
  return tonumber(n) * UNIT[u]
end

local function worked(t)
  local n, u = t:match("^(%d+%.?%d*)(%a*)$")
  if not n then return nil end
  if u == "" then u = "h" end
  if not TIME_UNIT[u] then return nil end
  return tonumber(n) * TIME_UNIT[u]
end

local function text_filter(get)
  return function(v)
    if v == "" then return nil end
    return function(s) return get(s, v) end
  end
end

-- name -> function(value) -> test(song, now) or nil when the value is unreadable
local FILTERS = {
  bpm = function(v)
    local r = range(v, number)
    return r and function(s) return in_range(r, s.info and s.info.tempo) end
  end,
  tracks = function(v)
    local r = range(v, number)
    return r and function(s) return in_range(r, s.info and s.info.track_count) end
  end,
  time = function(v)
    local r = range(v, worked)
    return r and function(s) return in_range(r, s.time_worked or 0) end
  end,
  status = text_filter(function(s, v) return has(fold(s.status or ""), v) end),
  artist = text_filter(function(s, v) return has(fold(s.display_author), v) end),
  uses = text_filter(function(s, v)
    for _, fx in ipairs((s.info or {}).fx or {}) do
      if has(fold(fx.name), v) or has(fold(fx.file), v) then return true end
    end
    return false
  end),
}
FILTERS.tempo, FILTERS.by, FILTERS.fx = FILTERS.bpm, FILTERS.artist, FILTERS.uses

-- saved: and opened: compare an age with the song's time.
local function age_filter(field)
  return function(v)
    local r = range(v, age)
    if not r then return nil end
    -- No sign means "within": saved:7d is saved:<7d.
    if r.exact then r = { hi = r.hi } end
    return function(s, now)
      local t = field == "saved" and s.mtime or s.opened
      if t == nil then return false end
      return in_range(r, now - t)
    end
  end
end
FILTERS.saved, FILTERS.opened = age_filter("saved"), age_filter("opened")

-- Splits a folded query into words, keeping "quoted values" whole.
local function tokens(q)
  local out, i, n = {}, 1, #q
  while true do
    i = q:find("%S", i)
    if not i then break end
    local j, buf = i, {}
    while j <= n and not q:sub(j, j):find("%s") do
      local c = q:sub(j, j)
      if c == '"' then
        local k = q:find('"', j + 1, true) or (n + 1)
        buf[#buf + 1] = q:sub(j + 1, k - 1)
        j = k + 1
      else
        buf[#buf + 1] = c
        j = j + 1
      end
    end
    out[#out + 1] = table.concat(buf)
    i = j
  end
  return out
end

-- parse(query) -> { words = { folded word }, tests = { test(song, now) } }
function M.parse(query)
  local out = { words = {}, tests = {} }
  for _, w in ipairs(tokens(fold(query))) do
    local name, value = w:match("^(%a+):(.*)$")
    local make = name and FILTERS[name]
    local test = make and make(value)
    if test then
      out.tests[#out.tests + 1] = test
    elseif make and value == "" then
      -- "status:" while still typing: neither a filter nor a word yet
    elseif w ~= "" then
      out.words[#out.words + 1] = w
    end
  end
  return out
end

-- True when the query has words to rank by (filters alone keep the sort).
function M.has_words(query)
  return #M.parse(query or "").words > 0
end

function M.filter(songs, query, view, now)
  local q = M.parse(query)
  local words, tests = q.words, q.tests
  now = now or os.time()

  local out, scored = {}, {}
  for i, s in ipairs(songs) do
    local pass = in_view(s, view)
    for _, test in ipairs(tests) do
      if not pass then break end
      pass = test(s, now)
    end
    if pass then
      if #words == 0 then
        out[#out + 1] = s
      else
        local sc = score(fields(s), words)
        if sc then scored[#scored + 1] = { s = s, score = sc, i = i } end
      end
    end
  end
  if #words == 0 then return out end

  table.sort(scored, function(a, b)
    if a.score ~= b.score then return a.score > b.score end
    return a.i < b.i
  end)
  for i, e in ipairs(scored) do out[i] = e.s end
  return out
end

-- column -> { value function, kind }
local COLUMNS = {
  title    = function(s) return fold(s.display_title) end,
  author   = function(s) return fold(s.display_author) end,
  status   = function(s) return s.status and fold(s.status) or nil end,
  opened   = function(s) return s.opened end,
  saved    = function(s) return s.mtime end,
  bpm      = function(s) return s.info and s.info.tempo or nil end,
  versions = function(s) return #(s.versions or {}) end,
}

function M.sort(songs, column, descending)
  local get = COLUMNS[column]
  if not get then error("unknown sort column: " .. tostring(column), 2) end
  local items = {}
  for i, s in ipairs(songs) do
    items[i] = { s = s, v = get(s), title = fold(s.display_title), key = tostring(s.key), i = i }
  end
  table.sort(items, function(a, b)
    if a.v == nil or b.v == nil then
      if a.v == nil and b.v == nil then
        -- fall through to tie-breakers
      else
        return b.v == nil -- missing last in both directions
      end
    elseif a.v ~= b.v then
      if descending then return a.v > b.v end
      return a.v < b.v
    end
    if a.title ~= b.title then return a.title < b.title end
    if a.key ~= b.key then return a.key < b.key end
    return a.i < b.i
  end)
  local out = {}
  for i, e in ipairs(items) do out[i] = e.s end
  return out
end

-- sort_recent(songs) -> new table: the recent view's default order (the
-- Opened column, descending). Songs opened through ReaLobby first, newest
-- first; then songs in REAPER's recent list by its order (recent_rank); then
-- the rest. Ties break by display_title, key, then input order.
function M.sort_recent(songs)
  local items = {}
  for i, s in ipairs(songs) do
    local tier = s.opened and 1 or (s.recent_rank and 2 or 3)
    local v = tier == 1 and -s.opened or (tier == 2 and s.recent_rank or 0)
    items[i] = { s = s, tier = tier, v = v, title = fold(s.display_title), key = tostring(s.key), i = i }
  end
  table.sort(items, function(a, b)
    if a.tier ~= b.tier then return a.tier < b.tier end
    if a.v ~= b.v then return a.v < b.v end
    if a.title ~= b.title then return a.title < b.title end
    if a.key ~= b.key then return a.key < b.key end
    return a.i < b.i
  end)
  local out = {}
  for i, e in ipairs(items) do out[i] = e.s end
  return out
end

return M
