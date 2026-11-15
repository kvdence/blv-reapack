-- What the menu and dialogs do, without ImGui: plans and their confirm
-- lines, applying a plan, pins, status, hidden, editing fields, statuses,
-- folders, opacity, new projects, Run at startup and the first run.
-- Pure Lua 5.4 (plain-Lua testable); REAPER is reached only through env.B.
--
-- env = {
--   P            platform (list_dir, join, move, mkdir, trash)
--   is_open      is_open(path) -> bool, the entry script's normalised check
--   library      L (touch, refresh)
--   data         ReaLobby's data (store.lua)
--   state        the app state (data_changed, selected_key, view, ...)
--   B            the bridge (new projects, startup)
--   now          os.time
--   entry_path   the running BLV_ReaLobby.lua
--   set_fields   optional, edit.set_fields (tests)
--   reset_details optional, details.reset (after the bounce folders change)
-- }
local edit = require("realobby.edit")
local versions = require("realobby.versions")
local format = require("realobby.ui.format")

local A = {}

A.OPEN_MSG = "Close this project in REAPER first."
A.CHANGED_MSG = "The song's files changed since this list was made. Check the new list, then press Do it again."
A.EXISTS_MSG = "A project with this name already exists there."
A.BAD_NAME_MSG = 'A name cannot be empty, start or end with a space or a dot, or contain / \\ : * ? " < > |'
A.SCAN_NOTE = "Choose the folders that hold your REAPER projects. ReaLobby looks inside every subfolder too, "
  .. "so pick the top folder (for example REAPER Media)."
A.CHOOSE_NOTE = "Choose… opens a folder browser. The number beside each folder counts the REAPER projects "
  .. "inside it or one level down."
A.CLOUD_EDIT_MSG = "This project is not downloaded. Open it in REAPER first."
A.ROOT_MSG = "Choose a folder inside a disk, not the top of the disk."
A.TIME_NOTE = "Counts while a song is the open tab in REAPER and pauses after 5 minutes without mouse "
  .. "movement, edits or playback. The times stay on this computer."
A.PROMPT_NOTE = "REAPER also shows its own Choose Project window when it starts. To switch it off, open "
  .. 'Preferences → General, find "Open project(s) on startup" and choose another option.'

local function trim(s)
  return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function parent(path)
  return path:gsub("[/\\]+$", ""):match("^(.*)[/\\][^/\\]*$") or ""
end

local function last_component(path)
  return path:gsub("[/\\]+$", ""):match("([^/\\]*)$")
end

local function norm(path)
  return (path:gsub("\\", "/"):gsub("/+$", ""):lower())
end

-- After a change to data.songs or a setting: the views rebuild and the data saves.
local function mark(env)
  env.library:touch()
  env.state.data_changed = true
end

local function meta(env, key)
  env.data.songs = env.data.songs or {}
  env.data.songs[key] = env.data.songs[key] or {}
  return env.data.songs[key]
end

-- Confirm lines ---------------------------------------------------------------

-- One line per change: "from → to", "from → Trash" or "create <dir>".
function A.confirm_lines(plan)
  local out = {}
  for _, c in ipairs(plan.changes or {}) do
    if c.mkdir then
      out[#out + 1] = "create " .. c.to
    elseif c.to == nil then
      out[#out + 1] = c.from .. " → Trash"
    else
      out[#out + 1] = c.from .. " → " .. c.to
    end
  end
  return out
end

function A.can_apply(plan)
  return #(plan.changes or {}) > 0
end

local function components(path)
  local out = {}
  for part in path:gmatch("[^/\\]+") do out[#out + 1] = part end
  return out
end

-- A plan only ever touches .RPP files and folders: anything else is a folder.
local function is_folder_change(c)
  return c.mkdir or not (c.from or ""):lower():match("%.rpp$")
end

-- The confirm dialog's view of a plan (ruling R29): the common parent folder
-- once, then each change in short names. A rename inside one folder shows
-- the two names; anything else is relative to the common folder. Folders end
-- in "/". Each line keeps the full-path text for hovering.
-- Returns { folder = string, lines = { { text, full } } }.
function A.confirm_view(plan)
  local changes = plan.changes or {}
  local full = A.confirm_lines(plan)
  local sep = "/"
  local first = changes[1] and (changes[1].from or changes[1].to)
  if first and first:find("\\", 1, true) and not first:find("/", 1, true) then sep = "\\" end
  local absolute = first and first:match("^[/\\]") ~= nil
  -- the common prefix of every touched path's parent folder
  local common
  for _, c in ipairs(changes) do
    for _, p in ipairs({ c.from or false, c.to or false }) do
      if p then
        local parts = components(p)
        parts[#parts] = nil
        if not common then
          common = parts
        else
          local n = 0
          while n < #common and n < #parts and common[n + 1] == parts[n + 1] do n = n + 1 end
          for i = #common, n + 1, -1 do common[i] = nil end
        end
      end
    end
  end
  common = common or {}
  local folder = table.concat(common, sep)
  if absolute then folder = sep .. folder end
  if folder == "" then folder = sep end
  local function rel(p, dir)
    local parts = components(p)
    local short = table.concat(parts, sep, #common + 1)
    return dir and (short .. sep) or short
  end
  local lines = {}
  for i, c in ipairs(changes) do
    local dir = is_folder_change(c)
    local text
    if c.mkdir then
      text = "create " .. rel(c.to, true)
    elseif c.to == nil then
      text = rel(c.from, dir) .. " → Trash"
    elseif parent(c.from) == parent(c.to) then
      text = last_component(c.from) .. (dir and sep or "") .. " → " .. last_component(c.to) .. (dir and sep or "")
    else
      text = rel(c.from, dir) .. " → " .. rel(c.to, dir)
    end
    lines[i] = { text = text, full = full[i] }
  end
  return { folder = folder, lines = lines }
end

-- The message for a failed apply: "open" asks to close the project; any other
-- error is shown as returned, followed by the changes already made.
function A.failure_text(err, done)
  if err == "open" then return A.OPEN_MSG end
  local s = tostring(err)
  if done and #done > 0 then
    s = s .. "\nThese changes already happened:\n" .. table.concat(A.confirm_lines({ changes = done }), "\n")
  end
  return s
end

-- Open projects ------------------------------------------------------------------

-- is_open(path) for applying changes: true when path is an open project, or a
-- folder that holds one. open_set() gives { [normalize(path)] = true };
-- normalize is the bridge's (forward slashes, lower case on mac and win).
function A.open_checker(open_set, normalize)
  return function(path)
    local n = (normalize(path):gsub("/+$", ""))
    local set = open_set()
    if set[n] then return true end
    local prefix = n .. "/"
    for k in pairs(set) do
      if k:sub(1, #prefix) == prefix then return true end
    end
    return false
  end
end

-- Plans and applying ----------------------------------------------------------

-- Where "archive" puts its _Archive folder: the deepest scan folder that
-- holds the song, else the folder above the song's own folder (or the
-- project's folder for a loose project).
function A.archive_root(song, scan_folders)
  local p = norm(song.newest)
  local best
  for _, f in ipairs(scan_folders or {}) do
    local nf = norm(f)
    if nf ~= "" and p:sub(1, #nf + 1) == nf .. "/" and (not best or #nf > #norm(best)) then best = f end
  end
  if best then return (best:gsub("([^/\\])[/\\]+$", "%1")) end
  local dir = parent(song.newest)
  if last_component(dir) == last_component(versions.key(song.newest)) then return parent(dir) end
  return dir
end

-- plan(env, action, song, arg) -> Plan (edit.plan). Archive works out its own root.
function A.plan(env, action, song, arg)
  if action == "archive" then arg = A.archive_root(song, env.data.scan_folders) end
  return edit.plan(action, song, arg, env.P)
end

-- path after the moves in done (a file rename, then its folder's rename).
function A.mapped_path(path, done)
  for _, c in ipairs(done) do
    if c.from and c.to and not c.mkdir then
      if path == c.from then
        path = c.to
      elseif path:sub(1, #c.from + 1) == c.from .. "/" or path:sub(1, #c.from + 1) == c.from .. "\\" then
        path = c.to .. path:sub(#c.from + 1)
      end
    end
  end
  return path
end

local function under_scan(path, scan_folders)
  local p = norm(path)
  for _, f in ipairs(scan_folders or {}) do
    local nf = norm(f)
    if nf ~= "" and p:sub(1, #nf + 1) == nf .. "/" then return true end
  end
  return false
end

-- data.known_files: project paths the library lists although no scan folder
-- holds them. After a change, the song's old paths leave the list; its new
-- paths join it when no scan folder holds them (a song found through the
-- recent list would otherwise vanish once renamed, moved or archived).
local function remember_paths(env, song, done, trashed)
  -- The song's project files before the change: its versions and every
  -- project file the plan moved (a rename moves versions the scan never saw).
  local before = {}
  for _, v in ipairs(song.versions or { { path = song.newest } }) do before[#before + 1] = v.path end
  for _, c in ipairs(done) do
    if c.from and c.to and not c.mkdir and c.from:lower():match("%.rpp$") then before[#before + 1] = c.from end
  end
  local old = {}
  for _, p in ipairs(before) do old[norm(p)] = true end
  local list = {}
  for _, p in ipairs(env.data.known_files or {}) do
    if not old[norm(p)] then list[#list + 1] = p end
  end
  if not trashed and not under_scan(A.mapped_path(song.newest, done), env.data.scan_folders) then
    local have = {}
    for _, p in ipairs(list) do have[norm(p)] = true end
    for _, b in ipairs(before) do
      local p = A.mapped_path(b, done)
      if not have[norm(p)] and not old[norm(p)] then
        list[#list + 1] = p
        have[norm(p)] = true
      end
    end
  end
  if #list > 0 or env.data.known_files then env.data.known_files = list end
end

-- Applies plan to song. After any change (even a partial one) the library
-- re-reads the folders and the song's data moves to its new key.
-- Returns true, or false and the message to show.
function A.apply(env, plan, song)
  local ok, err, done = edit.apply(plan, { P = env.P, is_open = env.is_open })
  done = done or {}
  if ok or #done > 0 then
    local trashed = false
    for _, c in ipairs(done) do
      if c.to == nil and not c.mkdir then trashed = true end
    end
    remember_paths(env, song, done, trashed)
    if not trashed then
      local new_key = versions.key(A.mapped_path(song.newest, done))
      if new_key ~= song.key then
        if env.move_time then env.move_time(song.key, new_key) end
        local songs = env.data.songs or {}
        local old = songs[song.key]
        if old then
          -- an entry already at the new key wins; only its missing fields are filled
          local into = songs[new_key] or {}
          for k, v in pairs(old) do
            if into[k] == nil then into[k] = v end
          end
          songs[new_key] = into
          songs[song.key] = nil
        end
        if env.state.selected_key == song.key then env.state.selected_key = new_key end
      end
    end
    env.state.data_changed = true
    env.library:refresh()
  end
  if ok then return true end
  return false, A.failure_text(err, done)
end

-- The song as it is on disk now: every project file in its folder that
-- belongs to its key (a version saved after the scan included).
function A.fresh_song(env, song)
  local dir = parent(song.newest)
  local files = {}
  for _, e in ipairs(env.P.list_dir(dir)) do
    if not e.is_dir and e.name:lower():match("%.rpp$") and versions.key(e.path) == song.key then
      files[#files + 1] = { path = e.path, mtime = e.mtime }
    end
  end
  if #files == 0 then return song end
  table.sort(files, function(a, b) return a.path < b.path end)
  local g = versions.group(files)[1]
  local fresh = {}
  for k, v in pairs(song) do fresh[k] = v end
  fresh.versions, fresh.newest = g.versions, g.newest
  return fresh
end

-- "Do it": plans again from the files on disk right before applying.
-- args = { song, plan (the list shown), action, arg }. Returns true, or
-- false, message and the fresh plan (to show instead when the list changed).
function A.do_it(env, args)
  local song = A.fresh_song(env, args.song)
  local plan = A.plan(env, args.action, song, args.arg)
  for _, p in ipairs(plan.song_paths or {}) do
    if env.is_open(p) then return false, A.OPEN_MSG, plan end
  end
  for _, c in ipairs(plan.changes) do
    if c.from and env.is_open(c.from) then return false, A.OPEN_MSG, plan end
  end
  if table.concat(A.confirm_lines(plan), "\n") ~= table.concat(A.confirm_lines(args.plan), "\n") then
    return false, A.CHANGED_MSG, plan
  end
  local ok, msg = A.apply(env, plan, song)
  return ok, msg, plan
end

-- Pins, status, hidden --------------------------------------------------------

-- "Count time worked on each song" (data.count_time, on unless false).
function A.set_count_time(env, on)
  env.data.count_time = on and true or false
  if on then
    if env.start_timer then env.start_timer() end
  elseif env.stop_timer then
    env.stop_timer()
  end
  mark(env)
end

function A.toggle_pin(env, song)
  meta(env, song.key).pinned = (not song.pinned) or nil
  mark(env)
end

-- name nil clears the status ("None").
function A.set_status(env, song, name)
  meta(env, song.key).status = name
  mark(env)
end

function A.set_hidden(env, song, on)
  meta(env, song.key).hidden = on or nil
  mark(env)
end

-- Editing fields --------------------------------------------------------------

-- fields = { title, author, notes } as typed. Only the ones that differ from
-- the project go to edit.set_fields, in one call (one backup).
function A.save_fields(env, song, fields)
  -- Reading a cloud placeholder would download it.
  if song.cloud_only then return false, A.CLOUD_EDIT_MSG end
  local info = song.info or {}
  local changed, any = {}, false
  for _, k in ipairs({ "title", "author", "notes" }) do
    local v = fields[k]
    if v ~= nil and v ~= (info[k] or "") then
      changed[k] = v
      any = true
    end
  end
  if not any then return true, "Nothing changed." end
  local set_fields = env.set_fields or edit.set_fields
  local ok, err = set_fields(song.newest, changed, { P = env.P, is_open = env.is_open, now = env.now })
  if not ok then
    if err == "open" then return false, A.OPEN_MSG end
    return false, tostring(err)
  end
  env.library:refresh()
  return true
end

-- Statuses ----------------------------------------------------------------------

local function status_index(data, name)
  for i, s in ipairs(data.statuses) do
    if s:lower() == name:lower() then return i end
  end
end

-- nil when name can be a status (except: the status being renamed).
local function status_error(data, name, except)
  if name == "" then return "A status needs a name." end
  if name:lower() == "none" then return '"None" is kept for songs with no status.' end
  local i = status_index(data, name)
  if i and data.statuses[i] ~= except then return "There is already a status called " .. name .. "." end
  return nil
end

function A.status_add(env, name)
  name = trim(name)
  local err = status_error(env.data, name)
  if err then return false, err end
  table.insert(env.data.statuses, name)
  mark(env)
  return true
end

-- Renames the status and every song that has it. A built-in status
-- (Writing, Mixing, Done) keeps its colour under its new name.
function A.status_rename(env, old, new)
  new = trim(new)
  local data = env.data
  if new == old then return true end
  local err = status_error(data, new, old)
  if err then return false, err end
  local i
  for k, s in ipairs(data.statuses) do if s == old then i = k end end
  if not i then return false, "There is no status called " .. old .. "." end
  data.statuses[i] = new
  for _, m in pairs(data.songs or {}) do
    if m.status == old then m.status = new end
  end
  local first = (data.status_builtin or {})[old]
  if not first and (old == "Writing" or old == "Mixing" or old == "Done") then first = old end
  if first then
    data.status_builtin = data.status_builtin or {}
    data.status_builtin[old] = nil
    if new ~= first then data.status_builtin[new] = first end
  end
  local view = env.state.view
  if view and view.group == "status" and view.value == old then view.value = new end
  mark(env)
  return true
end

-- How many songs have the status.
function A.status_users(data, name)
  local n = 0
  for _, m in pairs(data.songs or {}) do
    if m.status == name then n = n + 1 end
  end
  return n
end

-- Removes the status and clears it from its songs. Returns how many songs had it.
function A.status_remove(env, name)
  local data = env.data
  for k, s in ipairs(data.statuses) do
    if s == name then table.remove(data.statuses, k); break end
  end
  local n = 0
  for _, m in pairs(data.songs or {}) do
    if m.status == name then m.status = nil; n = n + 1 end
  end
  if data.status_builtin then data.status_builtin[name] = nil end
  local view = env.state.view
  if view and view.group == "status" and view.value == name then env.state.view = { group = "recent" } end
  mark(env)
  return n
end

-- Moves status i up (delta -1) or down (+1). False at either end.
function A.status_move(env, i, delta)
  local list = env.data.statuses
  local j = i + delta
  if i < 1 or i > #list or j < 1 or j > #list then return false end
  list[i], list[j] = list[j], list[i]
  mark(env)
  return true
end

-- One frame of the Settings status rows: rename = { old, new } (a field
-- that lost focus after an edit) and other = { "move", i, delta } |
-- { "ask_remove", name } | { "add", name }. The rename lands first, so a
-- click on ↑/↓ or Remove in the same frame does not lose it. Returns ok, the
-- first error, and the status name to ask about removing.
function A.status_commit(env, rename, other)
  local ok, err = true, nil
  local renamed = {}
  if rename then
    ok, err = A.status_rename(env, rename[1], rename[2])
    if ok then renamed[rename[1]] = (rename[2]:gsub("^%s+", ""):gsub("%s+$", "")) end
  end
  local ask
  if other then
    local kind = other[1]
    if kind == "move" then
      A.status_move(env, other[2], other[3])
    elseif kind == "ask_remove" then
      ask = renamed[other[2]] or other[2]
    elseif kind == "add" then
      local aok, aerr = A.status_add(env, other[2])
      if ok and not aok then ok, err = false, aerr end
    end
  end
  return ok, err, ask
end

-- Folders and settings ---------------------------------------------------------

local function clean_folder(path)
  local p = trim(path)
  if p:match("^[/\\]+$") then return p:sub(1, 1) end
  return (p:gsub("[/\\]+$", ""))
end

-- True when path is a folder: an absolute path with at least one folder
-- below the root or drive root ("/", "C:\\", "C:" and relative paths are
-- refused), found as a folder in its parent's listing (P.list_dir). Network
-- shares (ruling R30): \\server\share and anything below it; \\,
-- \\server and \\server\ are refused. The share itself counts when
-- its listing is not empty (P.list_dir gives no error to tell an empty share
-- from a missing one).
function A.folder_exists(P, path)
  local p = clean_folder(path)
  local up
  local drive, rest = p:match("^(%a:)[/\\](.*)$")
  if p:match("^[/\\][/\\]") then
    local share, below = p:match("^([/\\][/\\][^/\\]+[/\\][^/\\]+)(.*)$")
    if not share then return false end
    if below == "" then return #P.list_dir(p) > 0 end
    up = parent(p)
  elseif drive then
    if not rest:find("[^/\\]") then return false end
    up = parent(p)
    if up == drive then up = drive .. "\\" end
  elseif p:match("^/[^/\\]") then
    up = parent(p)
    if up == "" then up = "/" end
  else
    return false
  end
  local name = last_component(p)
  if name == "" or name == "." or name == ".." then return false end
  local want = name:lower()
  for _, e in ipairs(P.list_dir(up)) do
    if e.is_dir and e.name:lower() == want then return true end
  end
  return false
end

local function update_sources(env)
  env.state.no_sources = #(env.data.scan_folders or {}) == 0 and #(env.recent or {}) == 0
end

-- which = "scan_folders" | "excludes".
-- Scan and excluded folders change the song list; bounce folders change
-- only what the details panel lists (env.reset_details).
local function folders_changed(env, which)
  mark(env)
  if which == "bounce_folders" then
    if env.reset_details then env.reset_details() end
    return
  end
  update_sources(env)
  env.library:refresh()
end

-- which: "scan_folders", "excludes" or "bounce_folders".
function A.folder_add(env, which, path)
  local p = clean_folder(path)
  if p == "" then return false, "Type or choose a folder." end
  local list = env.data[which] or {}
  env.data[which] = list
  for _, f in ipairs(list) do
    if norm(f) == norm(p) then return false, "That folder is already in the list." end
  end
  if not A.folder_exists(env.P, p) then return false, "That folder does not exist: " .. p end
  list[#list + 1] = p
  folders_changed(env, which)
  return true
end

function A.folder_remove(env, which, i)
  local list = env.data[which] or {}
  if not list[i] then return false end
  table.remove(list, i)
  folders_changed(env, which)
  return true
end

-- Sets the glass opacity from a percentage (80-100); returns the percentage used.
function A.opacity(env, pct)
  pct = math.floor((tonumber(pct) or 94) + 0.5)
  pct = math.max(80, math.min(100, pct))
  local v = pct / 100
  env.state.opacity = v
  env.data.opacity = v
  env.state.data_changed = true
  return pct
end

-- New project, startup, first run ---------------------------------------------

-- opts = { empty = true } or { template, name, folder }. On success the
-- window closes (ruling R25).
function A.new_project(env, opts)
  if opts.empty then
    local ok, err = env.B.new_empty(env.state.ignore_default)
    if not ok then return false, "Could not make the project: " .. tostring(err) end
    env.state.close_requested = true
    return true
  end
  local name, folder = trim(opts.name), clean_folder(opts.folder)
  if not opts.template then return false, "Choose a template." end
  if folder == "" then return false, "Type or choose a folder." end
  if not A.folder_exists(env.P, folder) then return false, "That folder does not exist: " .. folder end
  local ok, res = env.B.new_from_template(opts.template, name, folder)
  if not ok then
    if res == "exists" then return false, A.EXISTS_MSG end
    if res == "bad name" then return false, A.BAD_NAME_MSG end
    if res == "not opened" then return false, format.open_error(res) end
    return false, "Could not make the project: " .. tostring(res)
  end
  -- Ruling R1: opening through ReaLobby records the time.
  if type(res) == "string" then
    meta(env, (versions.key(res))).opened = env.now()
    env.state.data_changed = true
  end
  env.state.close_requested = true
  return true
end

-- Turns Run at startup on or off; errors come back as the bridge returns them.
function A.set_startup(env, on)
  local ok, err
  if on then ok, err = env.B.install_startup(env.entry_path) else ok, err = env.B.remove_startup() end
  env.state.startup_on = env.B.startup_installed()
  if not ok then return false, tostring(err) end
  return true
end

-- The first run's Done: Run at startup as chosen, then never again.
function A.finish_first_run(env, startup_on)
  if (startup_on and true or false) ~= (env.B.startup_installed() and true or false) then
    local ok, err = A.set_startup(env, startup_on)
    if not ok then return false, err end
  end
  env.data.first_run_done = true
  env.state.data_changed = true
  return true
end

return A
