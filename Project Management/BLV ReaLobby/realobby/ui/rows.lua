-- The table's rows and the sidebar's counts. Pure Lua (no ImGui, no reaper.*).
--
-- Views are tables: { group = "recent" | "all" | "pinned" | "hidden" |
-- "status" | "artist" | "templates", value = <status, artist or "project"/"track"> }.
local search = require("realobby.search")

local M = {}

-- The columns the table can sort by (search.sort's names).
M.SORT_COLUMNS = { title = true, author = true, status = true, opened = true, saved = true, bpm = true,
  versions = true }

-- Columns sorted newest or biggest first on their first click.
local DESC_FIRST = { opened = true, saved = true, bpm = true, versions = true }

function M.same_view(a, b)
  return a ~= nil and b ~= nil and a.group == b.group and a.value == b.value
end

-- Filtered rows: a query without words (empty, or filters only) sorts by
-- `sort`; words keep the ranking.
function M.compute(songs, query, view, sort)
  local list = search.filter(songs, query or "", view)
  if not search.has_words(query) then
    if view and view.group == "recent" and sort.column == "opened" and sort.descending then
      list = search.sort_recent(list)   -- REAPER's recent order after ReaLobby's opened times
    else
      list = search.sort(list, sort.column, sort.descending)
    end
  end
  return list
end

-- Cached compute: recomputes only when the songs table (identity), query,
-- view or sort changes. m is the caller's memo table. Returns rows, changed.
function M.memo(m, songs, query, view, sort)
  if m.rows and m.songs == songs and m.query == query and M.same_view(m.view, view)
      and m.column == sort.column and m.descending == sort.descending then
    return m.rows, false
  end
  m.rows = M.compute(songs, query, view, sort)
  m.songs, m.query = songs, query
  m.view = { group = view.group, value = view.value }
  m.column, m.descending = sort.column, sort.descending
  return m.rows, true
end

function M.index_of(list, key)
  if key == nil then return nil end
  for i, r in ipairs(list) do
    if r.key == key then return i end
  end
  return nil
end

-- The key to select after the rows changed: the current one while it is
-- still listed (unless prefer_first, e.g. the query changed), else the first.
function M.reselect(list, key, prefer_first)
  if #list == 0 then return nil end
  if not prefer_first and M.index_of(list, key) then return key end
  return list[1].key
end

-- Moves the selection by delta rows, stopping at the ends.
function M.move(list, key, delta)
  if #list == 0 then return nil end
  local i = M.index_of(list, key)
  if not i then return list[1].key end
  i = math.max(1, math.min(#list, i + delta))
  return list[i].key
end

-- A header click: the same column reverses, a new one starts in its default.
function M.click_sort(sort, column)
  if sort.column == column then return { column = column, descending = not sort.descending } end
  return { column = column, descending = DESC_FIRST[column] or false }
end

-- Sidebar counts over every song (hidden ones included):
--   { all, recent, pinned, hidden, status = { [name] = n }, artists = { {name, count} } }
-- recent counts songs in REAPER's recent list or opened through ReaLobby.
-- Hidden and archived songs only count towards hidden. Artists fold case and accents the
-- way the artist view does; most songs first, then by name.
function M.counts(songs, statuses)
  local c = { all = 0, recent = 0, pinned = 0, hidden = 0, status = {}, artists = {} }
  for _, name in ipairs(statuses or {}) do c.status[name] = 0 end
  local by_artist = {}
  for _, s in ipairs(songs) do
    if s.hidden or s.archived then
      c.hidden = c.hidden + 1
    else
      c.all = c.all + 1
      if s.pinned then c.pinned = c.pinned + 1 end
      if s.recent or s.opened then c.recent = c.recent + 1 end
      if s.status and c.status[s.status] then c.status[s.status] = c.status[s.status] + 1 end
      local a = s.display_author or ""
      if a:find("%S") then
        local k = search.fold(a)
        local e = by_artist[k]
        if not e then
          e = { name = a, count = 0 }
          by_artist[k] = e
          c.artists[#c.artists + 1] = e
        end
        e.count = e.count + 1
      end
    end
  end
  table.sort(c.artists, function(x, y)
    if x.count ~= y.count then return x.count > y.count end
    return search.fold(x.name) < search.fold(y.name)
  end)
  return c
end

-- Template files as rows { key, path, name }, kept when every query word is
-- in the name.
function M.templates(paths, query)
  local words = {}
  for w in search.fold(query or ""):gmatch("%S+") do words[#words + 1] = w end
  local out = {}
  for _, p in ipairs(paths or {}) do
    local name = (p:match("([^/\\]*)$") or p):gsub("%.[^%.]*$", "")
    local hay, ok = search.fold(name), true
    for _, w in ipairs(words) do
      if not hay:find(w, 1, true) then ok = false; break end
    end
    if ok then out[#out + 1] = { key = p, path = p, name = name } end
  end
  return out
end

return M
