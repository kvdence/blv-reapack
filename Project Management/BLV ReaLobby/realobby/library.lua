-- The song catalogue: REAPER's recent list, data.known_files and the scan
-- folders, built a few operations per frame (a directory listing or a file
-- parse is one operation; a parse answered from the cache costs 1/16 of one).
-- With opts.clock, a step also stops once opts.time_budget seconds (default
-- 0.008) of wall time have passed.
--
-- songs() returns a cached list: the same table until something changes.
-- SongView.recent is true when any version's path is in REAPER's recent list
-- (compared with opts.normalize, default: forward slashes, lower case);
-- SongView.recent_rank is its smallest index in that list (1 = most recent).
-- SongView.archived is true for a song inside any "_Archive" folder (ruling
-- R28): like a hidden song, it is listed only with include_hidden.
-- SongView.time_worked is the song's counted seconds from L:set_time
-- (realobby/timelog.lua, keyed by normalize(song key)), or nil.
-- SongView.cloud_only is true when the newest version is a cloud placeholder
-- (platform list_dir): it is never read, since reading would download it.
-- After changing pins, status, tags or hidden in data.songs, the UI must call
-- L:touch() so the next songs() rebuilds the views. refresh() keeps the old
-- result visible until the new walk completes.
local versions = require("realobby.versions")
local paths = require("realobby.paths")

local M = {}

local MAX_DEPTH = 4
local REGROUP_EVERY = 25
local HITS_PER_OP = 16
local SKIP_DIRS = { backups = true, audio = true, media = true, peaks = true, recordedaudio = true }
local TEMP_PREFIXES = { "/tmp", "/private/tmp", "/private/var/folders" }

local function norm(path)
  return (path:gsub("\\", "/"):gsub("/+$", ""):lower())
end

local function dirname(path)
  local d = path:match("^(.*)[/\\][^/\\]*$")
  if d == nil then return "." end
  if d == "" then return "/" end
  return d
end

local function basename(path)
  return path:match("([^/\\]*)$") or path
end

local function is_rpp(name)
  return name:lower():match("%.rpp$") ~= nil
end

local function empty_info()
  return { length = 0, track_count = 0, fx = {}, media = {}, notes = "" }
end

function M.new(opts)
  local P, data = opts.P, opts.data
  local read = opts.read
  local budget = opts.budget or 8
  local clock = opts.clock                    -- seconds; reaper.time_precise in the app
  local time_budget = opts.time_budget or 0.008
  local recent = opts.recent or {}
  local normalize = opts.normalize or norm
  local recent_set = {}      -- normalized path -> first index in the recent list
  for i, path in ipairs(recent) do
    local n = normalize(path)
    if not recent_set[n] then recent_set[n] = i end
  end

  local L = {}
  local cache = {}            -- path..size..mtime -> info
  local files, shown, walking, dir_queue, parse_queue
  local dir_head, parse_head
  local parsed_since = 0
  local views = {}            -- include_hidden -> cached SongView list
  local view_index = {}       -- include_hidden -> { song key -> SongView }
  local groups, groups_dirty = {}, true
  local installed = nil
  local time_worked = {}      -- normalize(song key) -> seconds
  local media_missing = {}    -- song key -> { string }

  local function excluded(path)
    local p = norm(path)
    for _, ex in ipairs(data.excludes or {}) do
      local e = norm(ex)
      if e ~= "" and (p == e or p:sub(1, #e + 1) == e .. "/") then return true end
    end
    for _, tp in ipairs(TEMP_PREFIXES) do
      if p:sub(1, #tp + 1) == tp .. "/" then return true end
    end
    if p:find("/appdata/local/temp/", 1, true) then return true end
    return false
  end

  local function add_file(path, size, mtime, cloud_only)
    if files[path] or excluded(path) then return end
    files[path] = { size = size or 0, mtime = mtime or 0, cloud_only = cloud_only or false }
    parse_queue[#parse_queue + 1] = path
  end

  function L:refresh()
    files = {}
    walking = true
    dir_queue, parse_queue = {}, {}
    dir_head, parse_head = 1, 1
    for _, folder in ipairs(data.scan_folders or {}) do
      if not excluded(folder) then
        dir_queue[#dir_queue + 1] = { dir = folder, depth = 0 }
      end
    end
    -- REAPER's recent list, then ReaLobby's known files (songs renamed,
    -- moved or archived outside every scan folder); each folder is listed
    -- once and a path that is gone is dropped.
    local by_folder, order, seen = {}, {}, {}
    local sources = {}
    for _, path in ipairs(recent) do sources[#sources + 1] = path end
    for _, path in ipairs(data.known_files or {}) do sources[#sources + 1] = path end
    for _, path in ipairs(sources) do
      local n = normalize(path)
      if is_rpp(path) and not seen[n] and not excluded(path) then
        seen[n] = true
        local d = dirname(path)
        if not by_folder[d] then by_folder[d] = {}; order[#order + 1] = d end
        by_folder[d][#by_folder[d] + 1] = path
      end
    end
    for _, d in ipairs(order) do
      dir_queue[#dir_queue + 1] = { dir = d, recent = by_folder[d] }
    end
  end

  local function do_dir(op)
    local entries = P.list_dir(op.dir) or {}
    if op.recent then
      local present = {}
      for _, e in ipairs(entries) do
        if not e.is_dir then present[e.name:lower()] = e end
      end
      for _, path in ipairs(op.recent) do
        local e = present[basename(path):lower()]
        if e then add_file(path, e.size, e.mtime, e.cloud_only) end
      end
      return
    end
    for _, e in ipairs(entries) do
      if e.is_dir then
        local lname = e.name:lower()
        if op.depth < MAX_DEPTH and e.name:sub(1, 1) ~= "." and not SKIP_DIRS[lname]
          and not excluded(e.path) then
          dir_queue[#dir_queue + 1] = { dir = e.path, depth = op.depth + 1 }
        end
      elseif is_rpp(e.name) then
        add_file(e.path, e.size, e.mtime, e.cloud_only)
      end
    end
  end

  local function cache_key(path)
    local f = files[path]
    return path .. "\0" .. tostring(f.size) .. "\0" .. tostring(f.mtime)
  end

  local function do_parse(path)
    local ck = cache_key(path)
    local info = cache[ck]
    if files[path].cloud_only then
      -- Reading a cloud-only file would download it: show the file name only.
      info = empty_info()
    elseif not info then
      info = read(path)
      if type(info) ~= "table" then info = empty_info() end
      cache[ck] = info
    end
    files[path].info = info
    if not shown then
      parsed_since = parsed_since + 1
      if parsed_since >= REGROUP_EVERY then
        groups_dirty = true
        views, view_index = {}, {}
        parsed_since = 0
      end
    end
  end

  function L:step()
    local limit = budget * HITS_PER_OP
    local cost = 0
    local started = clock and clock()
    while true do
      if started and cost > 0 and clock() - started >= time_budget then return false end
      if dir_head <= #dir_queue then
        if cost + HITS_PER_OP > limit then return false end
        local op = dir_queue[dir_head]
        dir_queue[dir_head] = false
        dir_head = dir_head + 1
        do_dir(op)
        cost = cost + HITS_PER_OP
      elseif parse_head <= #parse_queue then
        local path = parse_queue[parse_head]
        local c = cache[cache_key(path)] and 1 or HITS_PER_OP
        if cost + c > limit then return false end
        parse_queue[parse_head] = false
        parse_head = parse_head + 1
        do_parse(path)
        cost = cost + c
      else
        if walking then
          walking = false
          shown = files
          groups_dirty = true
          views, view_index = {}, {}
        end
        return true
      end
    end
  end

  local function regroup()
    local list = {}
    for path, f in pairs(shown or files) do
      if f.info then list[#list + 1] = { path = path, mtime = f.mtime } end
    end
    table.sort(list, function(a, b) return a.path < b.path end)
    groups = versions.group(list)
    groups_dirty = false
    views, view_index = {}, {}
  end

  local function fx_missing(info)
    if not installed then return nil end
    local out, seen = {}, {}
    for _, fx in ipairs(info.fx or {}) do
      local file = fx.file
      if file and fx.kind ~= "JS" and not installed[file] and not seen[file] then
        seen[file] = true
        out[#out + 1] = file
      end
    end
    return out
  end

  local function reset_views()
    views, view_index = {}, {}
  end

  -- The song's smallest index in REAPER's recent list, or nil.
  local function recent_rank(g)
    local best
    for _, v in ipairs(g.versions) do
      local i = recent_set[normalize(v.path)]
      if i and (not best or i < best) then best = i end
    end
    return best
  end

  function L:set_installed_fx(set)
    installed = set
    reset_views()
  end

  function L:set_time(map)
    time_worked = map or {}
    reset_views()
  end

  function L:touch()
    reset_views()
  end

  function L:songs(view_opts)
    if groups_dirty then regroup() end
    local include_hidden = view_opts and view_opts.include_hidden and true or false
    if views[include_hidden] then return views[include_hidden] end
    local src = shown or files
    local out, index = {}, {}
    for _, g in ipairs(groups) do
      local meta = data.songs and data.songs[g.key] or {}
      local archived = ("/" .. norm(g.newest)):find("/_archive/", 1, true) ~= nil
      if include_hidden or not (meta.hidden or archived) then
        local f = src[g.newest]
        local info = f.info
        local base = basename(g.key)
        out[#out + 1] = {
          key = g.key, newest = g.newest, versions = g.versions, info = info,
          display_title = info.title or base,
          display_author = info.author or "",
          mtime = f.mtime, size = f.size, cloud_only = f.cloud_only or false,
          opened = meta.opened, status = meta.status, pinned = meta.pinned, tags = meta.tags,
          hidden = meta.hidden,
          archived = archived,
          recent = recent_rank(g) ~= nil,
          recent_rank = recent_rank(g),
          missing_fx = fx_missing(info),
          missing_media = media_missing[g.key],
          time_worked = time_worked[normalize(g.key)],
        }
        index[g.key] = out[#out]
      end
    end
    views[include_hidden], view_index[include_hidden] = out, index
    return out
  end

  -- Every media file any parsed project lists, as { paths.key(path) = true }
  -- (realobby/cleanup.lua keeps them). Built again after the next walk.
  local refs_memo
  -- true while the first walk is still reading folders (media_refs is partial).
  function L:first_walk()
    return shown == nil
  end

  function L:media_refs()
    local src = shown or files
    if refs_memo and refs_memo.src == src and not walking then return refs_memo.set end
    local set = {}
    for _, f in pairs(src) do
      for _, p in ipairs(f.info and f.info.media or {}) do set[paths.key(p)] = true end
    end
    refs_memo = { src = src, set = set }
    return set
  end

  -- Lists each media folder at most once; never opens a media file.
  function L:check_media(key)
    if groups_dirty then regroup() end
    for _, g in ipairs(groups) do
      if g.key == key then
        local info = (shown or files)[g.newest].info
        local listings, missing = {}, {}
        for _, path in ipairs(info.media or {}) do
          local dir = dirname(path)
          if not listings[dir] then
            local set = {}
            for _, e in ipairs(P.list_dir(dir) or {}) do set[e.name:lower()] = true end
            listings[dir] = set
          end
          if not listings[dir][basename(path):lower()] then missing[#missing + 1] = path end
        end
        media_missing[key] = missing
        -- Only this song changes: update it in the cached views in place, so
        -- songs() keeps its identity (no re-sort or recount per selection).
        for _, index in pairs(view_index) do
          if index[key] then index[key].missing_media = missing end
        end
        return missing
      end
    end
  end

  L:refresh()
  return L
end

return M
