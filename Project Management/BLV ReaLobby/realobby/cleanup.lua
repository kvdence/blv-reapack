-- Space clean-up: audio files in a song's media folders that no project
-- uses. Pure Lua 5.4: folders are listed and files trashed through
-- platform.lua (P); project files are read through ctx.read.
--
-- What is checked (safety first; anything doubtful is kept):
--   * Projects: every .RPP and .rpp-bak in the song's folder and its Backups
--     folder, plus the song's backups elsewhere (backups.list). If one cannot
--     be read, nothing is offered.
--   * Media folders: the song folder's subfolders that a project records
--     into (RECORD_PATH) or takes media from. Never the song folder itself,
--     a render or bounce folder, a Backups folder, or a folder whose name
--     says bounce, render, export, stem, mix or master.
--   * A file is unused when no project lists it as media (FILE lines), no
--     project's text names it anywhere (plain, or inside saved plug-in
--     states, base64-decoded, as UTF-8 or UTF-16), no other song in the
--     library lists it (ctx.refs), and it is not one of the song's bounces.
--   * Folders that hold a project file of their own are skipped. Paths are
--     compared with "." and ".." collapsed (realobby/paths.lua), so a
--     RECORD_PATH like "../Shared" or "." can never reach outside the song
--     folder or make the song folder itself a media folder.
--   * Plug-in settings saved compressed cannot be searched: a file only such
--     a plug-in uses can still be offered (the dialog says so).
--   * Unused files go to the Trash (with their .reapeaks peak files), never
--     removed for good, and only while no project in the folder is open.
local rpp = require("realobby.rpp")
local paths = require("realobby.paths")
local backups = require("realobby.backups")
local bounces = require("realobby.bounces")

local M = {}

M.OPEN_MSG = "Close this song in REAPER first: an open project can hold recordings it has not saved yet."
M.CLOUD_MSG = "This project is not downloaded. Open it in REAPER first."

M.AUDIO = { wav = true, wave = true, aif = true, aiff = true, aifc = true, flac = true, mp3 = true, m4a = true,
  aac = true, ogg = true, opus = true, wv = true, caf = true, w64 = true, rf64 = true, bwf = true, wma = true }
local SKIP_WORDS = { "bounce", "render", "export", "stem", "mix", "master" }

local norm = paths.key

local function parent(path)
  local d = path:gsub("[/\\]+$", ""):match("^(.*)[/\\][^/\\]*$")
  if d == nil then return "." end
  if d == "" then return "/" end
  return d
end

local function basename(path) return path:match("([^/\\]*)$") or path end

local function ext(name) return (name:match("%.([^%.]+)$") or ""):lower() end

local function is_absolute(p) return p:match("^[/\\]") ~= nil or p:match("^%a:[/\\]") ~= nil end

local function under(child, root)
  local c, r = norm(child), norm(root)
  return c ~= r and c:sub(1, #r + 1) == r .. "/"
end

local function is_project(name)
  local e = name:lower()
  return e:match("%.rpp$") ~= nil or e:match("%.rpp%-bak$") ~= nil
end

-- Base64 ----------------------------------------------------------------------

local B64 = {}
do
  local chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
  for i = 1, #chars do B64[chars:byte(i)] = i - 1 end
end

-- Decodes base64 text (groups of four; "=" ends a segment, the next one
-- carries on). Bytes that are not base64 are skipped.
function M.b64decode(s)
  s = s:gsub("[^%w%+/=]", "")
  local out, n = {}, 0
  for i = 1, #s - 3, 4 do
    local a, b, c, d = s:byte(i, i + 3)
    local va, vb = B64[a], B64[b]
    if va and vb then
      local vc, vd = B64[c], B64[d]
      local x = va * 262144 + vb * 4096 + (vc or 0) * 64 + (vd or 0)
      n = n + 1
      if vc and vd then
        out[n] = string.char(x >> 16, (x >> 8) & 255, x & 255)
      elseif vc then
        out[n] = string.char(x >> 16, (x >> 8) & 255)
      else
        out[n] = string.char(x >> 16)
      end
    end
  end
  return table.concat(out)
end

-- The decoded text of each run of base64-only lines (saved plug-in states).
local function decoded_runs(text, yield)
  local out, run = {}, {}
  local function close()
    if #run > 0 then
      out[#out + 1] = M.b64decode(table.concat(run)):lower()
      run = {}
      if yield then yield() end
    end
  end
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    local l = line:match("^%s*(.-)%s*$")
    if #l >= 8 and not l:find("[^%w%+/=]") then run[#run + 1] = l else close() end
  end
  close()
  return out
end

-- UTF-8 text as UTF-16LE bytes (how some plug-ins save file names).
local function utf16(s)
  local out = {}
  local ok = pcall(function()
    for _, cp in utf8.codes(s) do
      if cp < 0x10000 then
        out[#out + 1] = string.char(cp & 255, cp >> 8)
      else
        local v = cp - 0x10000
        local hi, lo = 0xD800 + (v >> 10), 0xDC00 + (v & 0x3FF)
        out[#out + 1] = string.char(hi & 255, hi >> 8, lo & 255, lo >> 8)
      end
    end
  end)
  if not ok then return (s:gsub(".", "%0\0")) end
  return table.concat(out)
end

-- Reading the projects ---------------------------------------------------------

-- refs(text, project_path) -> { normalized media path = path }, { record folders },
-- { render paths }
local function refs(text, project_path)
  local dir = parent(project_path)
  local set, rec, render = {}, {}, {}
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    local key, rest = line:match("^%s*(%u[%u_]*)%s+(.-)%s*$")
    if key == "FILE" or key == "RECORD_PATH" or key == "RENDER_FILE" then
      local tokens = rpp.tokenize(rest)
      if key == "FILE" then
        local p = tokens[1]
        if p and p ~= "" then
          if not is_absolute(p) then p = dir .. "/" .. p end
          p = paths.clean(p)
          set[norm(p)] = p
        end
      elseif key == "RENDER_FILE" then
        local p = tokens[1]
        if p and p ~= "" then render[#render + 1] = paths.clean(is_absolute(p) and p or (dir .. "/" .. p)) end
      else
        for _, p in ipairs(tokens) do
          if p ~= "" then rec[#rec + 1] = paths.clean(is_absolute(p) and p or (dir .. "/" .. p)) end
        end
      end
    end
  end
  return set, rec, render
end

local function skipped_name(name)
  local n = name:lower()
  if n == "backups" then return true end
  for _, w in ipairs(SKIP_WORDS) do
    if n:find(w, 1, true) then return true end
  end
  return false
end

-- scan(song, ctx) -> result or nil, message
--   ctx = { P, read = read(path) -> text|nil, backup_dir, bounce_folders,
--           refs = { normalized path = true } (other songs' media), yield }
--   result = { dir, projects = { path }, folders = { path },
--              files = { { path, name, size, extra = { peak path } } }, total }
function M.scan(song, ctx)
  local yield = ctx.yield
  -- Each folder is listed once per check (a listing costs a shell command,
  -- about a quarter of a second on Windows).
  local P = setmetatable({}, { __index = ctx.P })
  local listings = {}
  function P.list_dir(dir)
    local k = norm(dir)
    if listings[k] == nil then listings[k] = ctx.P.list_dir(dir) or {} end
    return listings[k]
  end
  if song.cloud_only then return nil, M.CLOUD_MSG end
  local dir = paths.clean(parent(song.newest))
  local listing = P.list_dir(dir) or {}

  -- Every project file that could use the folder's media.
  local projects, seen = {}, {}
  local function add_project(path)
    if not seen[norm(path)] then
      seen[norm(path)] = true
      projects[#projects + 1] = path
    end
  end
  for _, e in ipairs(listing) do
    if not e.is_dir and is_project(e.name) then add_project(e.path) end
  end
  for _, e in ipairs(listing) do
    if e.is_dir and e.name:lower() == "backups" then
      for _, b in ipairs(P.list_dir(e.path) or {}) do
        if not b.is_dir and is_project(b.name) then add_project(b.path) end
      end
    end
  end
  -- The backups of every version, wherever REAPER keeps them.
  for _, v in ipairs(song.versions or { { path = song.newest } }) do
    for _, b in ipairs(backups.list(v.path, P, ctx.backup_dir)) do add_project(b.path) end
  end
  table.sort(projects)

  local used, record, renders = {}, {}, {}
  for _, path in ipairs(projects) do
    local text = ctx.read(path)
    if not text then return nil, "Could not read " .. basename(path) .. ", so nothing is offered." end
    local set, rec, ren = refs(text, path)
    for k, v in pairs(set) do used[k] = v end
    for _, r in ipairs(rec) do record[#record + 1] = r end
    for _, r in ipairs(ren) do renders[#renders + 1] = r end
    if yield then yield() end
  end

  -- The media folders.
  -- Every project's render target: the folder itself and its parent (a
  -- RENDER_FILE can name a file or a folder).
  local excluded = {}
  local info = song.info or {}
  for _, r in ipairs(renders) do
    excluded[norm(r)] = true
    excluded[norm(parent(r))] = true
  end
  for _, f in ipairs(ctx.bounce_folders or {}) do excluded[norm(f)] = true end
  local folders, fseen = {}, {}
  local function add_folder(f)
    f = paths.clean(f)
    local n = norm(f)
    if fseen[n] or not under(f, dir) or excluded[n] then return end
    -- Any part of the path below the song folder with a skipped name.
    local rel = n:sub(#norm(dir) + 2)
    for part in rel:gmatch("[^/]+") do
      if skipped_name(part) then return end
    end
    fseen[n] = true
    folders[#folders + 1] = f
  end
  for _, r in ipairs(record) do add_folder(r) end
  local used_paths = {}
  for _, v in pairs(used) do used_paths[#used_paths + 1] = v end
  table.sort(used_paths)
  for _, v in ipairs(used_paths) do add_folder(parent(v)) end

  local bounce_set = {}
  for _, b in ipairs(bounces.list(info, song.newest, P, ctx.bounce_folders) or {}) do bounce_set[norm(b.path)] = true end
  local candidates = {}
  table.sort(folders)
  local listed = {}
  for _, f in ipairs(folders) do
    local real = f
    if not listed[norm(real)] then
      listed[norm(real)] = true
      local entries = P.list_dir(real) or {}
      -- A folder holding a project of its own (a subproject) is left alone:
      -- its project could use anything in it.
      local has_project = false
      for _, e in ipairs(entries) do
        if not e.is_dir and is_project(e.name) then has_project = true end
      end
      if has_project then entries = {} end
      local peaks = {}
      for _, e in ipairs(entries) do
        if not e.is_dir and e.name:lower():match("%.reapeaks$") then peaks[e.name:lower()] = e end
      end
      for _, e in ipairs(entries) do
        local n = norm(e.path)
        if not e.is_dir and M.AUDIO[ext(e.name)] and not used[n] and not bounce_set[n]
            and not (ctx.refs and ctx.refs[n]) then
          local c = { path = e.path, name = e.name, size = e.size or 0, extra = {} }
          local pk = peaks[(e.name .. ".reapeaks"):lower()]
          if pk then
            c.extra[1] = pk.path
            c.size = c.size + (pk.size or 0)
          end
          candidates[#candidates + 1] = c
        end
      end
      if yield then yield() end
    end
  end

  -- Keep any file a project names anywhere: plain text, or in a plug-in's
  -- saved state.
  if #candidates > 0 then
    for _, path in ipairs(projects) do
      local raw = ctx.read(path) or ""
      local hay = { raw:lower() }
      for _, d in ipairs(decoded_runs(raw, yield)) do hay[#hay + 1] = d end
      local keep = {}
      for i, c in ipairs(candidates) do
        local n = c.name:lower()
        local u = utf16(n)
        for _, h in ipairs(hay) do
          if h:find(n, 1, true) or h:find(u, 1, true) then keep[i] = true; break end
        end
      end
      local rest = {}
      for i, c in ipairs(candidates) do
        if not keep[i] then rest[#rest + 1] = c end
      end
      candidates = rest
      if yield then yield() end
      if #candidates == 0 then break end
    end
  end

  table.sort(candidates, function(a, b) return norm(a.path) < norm(b.path) end)
  local total = 0
  for _, c in ipairs(candidates) do total = total + c.size end
  return { dir = dir, projects = projects, folders = folders, files = candidates, total = total }
end

-- The same files (paths and sizes) in both results.
function M.same(a, b)
  if not a or not b or #a.files ~= #b.files then return false end
  for i, c in ipairs(a.files) do
    local o = b.files[i]
    if c.path ~= o.path or c.size ~= o.size then return false end
  end
  return true
end

-- apply(result, P, is_open) -> true, or false and the message. Moves every
-- file (and its peak file) to the Trash.
function M.apply(result, P, is_open)
  if is_open then
    if is_open(result.dir) then return false, M.OPEN_MSG end
    for _, p in ipairs(result.projects) do
      if is_open(p) then return false, M.OPEN_MSG end
    end
  end
  local paths = {}
  for _, c in ipairs(result.files) do
    paths[#paths + 1] = c.path
    for _, x in ipairs(c.extra or {}) do paths[#paths + 1] = x end
  end
  if #paths == 0 then return true end
  return P.trash_many(paths)
end

-- Where a file is, relative to the song folder ("Media/take 3.wav").
function M.relative(result, path)
  local d, p = paths.clean(result.dir), paths.clean(path)
  if p:sub(1, #d + 1):lower() == (d .. "/"):lower() then return p:sub(#d + 2) end
  return path
end

return M
