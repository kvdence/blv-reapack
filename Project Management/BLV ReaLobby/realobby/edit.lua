-- Safe changes to the owner's songs: writing Title/Author/Notes into a
-- project file, and planning + applying rename, move, archive and delete.
-- Pure Lua 5.4: file operations go through platform.lua (P); the only
-- direct filesystem calls are on ReaLobby's own temp and swap files.
local rpp = require("realobby.rpp")
local versions = require("realobby.versions")

local edit = {}

local function parent(path)
  return path:gsub("[/\\]+$", ""):match("^(.*)[/\\][^/\\]*$") or ""
end

local function last_component(path)
  return path:gsub("[/\\]+$", ""):match("([^/\\]*)$")
end

local function same_dir(a, b)
  return (a:gsub("[/\\]+$", "")) == (b:gsub("[/\\]+$", ""))
end

-- set_fields ---------------------------------------------------------------

-- REAPER's token quoting: bare, "…", '…' or `…`.
local function quote_value(v)
  if v:find("[\r\n]") then return nil end
  if v ~= "" and not v:find("[%s\"'`]") then return v end
  if not v:find('"', 1, true) then return '"' .. v .. '"' end
  if not v:find("'", 1, true) then return "'" .. v .. "'" end
  if not v:find("`", 1, true) then return "`" .. v .. "`" end
  return nil
end

local function split_lines(text)
  local parts, start = {}, 1
  while true do
    local i = text:find("\n", start, true)
    if not i then parts[#parts + 1] = text:sub(start); break end
    parts[#parts + 1] = text:sub(start, i - 1)
    start = i + 1
  end
  return parts
end

-- Finds the root line, the top-level TITLE/AUTHOR lines and the top-level
-- NOTES block (same depth rules as rpp.parse).
local function scan(lines)
  local s = { indent = nil }
  local stack = {}
  for i, raw in ipairs(lines) do
    local line = raw:gsub("\r$", "")
    local trimmed = line:match("^%s*(.-)%s*$")
    local depth = #stack
    local top = stack[depth]
    if top and top.name == "NOTES" and trimmed:sub(1, 1) == "|" then
      -- note text, never structure
    elseif trimmed == ">" then
      if top and top.notes_start then s.notes_end = i end
      stack[depth] = nil
    elseif trimmed:sub(1, 1) == "<" then
      local name = trimmed:match("^<(%S*)") or ""
      local entry = { name = name }
      if depth == 0 and name == "REAPER_PROJECT" and not s.root then
        s.root = i
      elseif depth == 1 and stack[1].name == "REAPER_PROJECT" then
        s.indent = s.indent or line:match("^(%s*)")
        if name == "NOTES" and not s.notes_start then
          s.notes_start = i
          entry.notes_start = true
        end
      end
      stack[depth + 1] = entry
    elseif trimmed ~= "" and depth == 1 and top.name == "REAPER_PROJECT" then
      s.indent = s.indent or line:match("^(%s*)")
      local key = trimmed:match("^(%S+)")
      if key == "TITLE" and not s.title then s.title = i
      elseif key == "AUTHOR" and not s.author then s.author = i
      end
    end
  end
  return s
end

local function note_lines(notes)
  local out = {}
  if notes == "" then return out end
  for l in (notes .. "\n"):gmatch("(.-)\r?\n") do out[#out + 1] = l end
  return out
end

-- rpp.parse trims each line's trailing spaces; compare like it reads.
local function as_read(notes)
  local out = {}
  for _, l in ipairs(note_lines(notes)) do out[#out + 1] = (l:gsub("%s+$", "")) end
  return table.concat(out, "\n")
end

local function rewrite(text, fields)
  local lines = split_lines(text)
  local s = scan(lines)
  if not s.root then return nil, "not a REAPER project" end
  local cr = text:find("\r\n", 1, true) and "\r" or ""
  local indent = s.indent or "  "
  local replace, after = {}, {}
  local function add_after(i, line)
    after[i] = after[i] or {}
    table.insert(after[i], line .. cr)
  end
  local function keep_cr(i) return (lines[i]:match("\r$") and "\r") or "" end

  for _, key in ipairs({ "title", "author" }) do
    local v = fields[key]
    if v ~= nil then
      local q = quote_value(v)
      if not q then return nil, "unsupported characters" end
      local word = key:upper()
      local at = s[key]
      if at then
        replace[at] = { (lines[at]:match("^(%s*)")) .. word .. " " .. q .. keep_cr(at) }
      else
        add_after(s.root, indent .. word .. " " .. q)
      end
    end
  end

  if fields.notes ~= nil then
    local function block(ind, ending)
      local b = { ind .. "<NOTES 0 2" .. ending }
      for _, l in ipairs(note_lines(fields.notes)) do b[#b + 1] = ind .. "  |" .. l .. ending end
      b[#b + 1] = ind .. ">" .. ending
      return b
    end
    if s.notes_start then
      if not s.notes_end then return nil, "unreadable NOTES block" end
      local ind = lines[s.notes_start]:match("^(%s*)")
      replace[s.notes_start] = block(ind, keep_cr(s.notes_end))
      for i = s.notes_start + 1, s.notes_end do replace[i] = {} end
    else
      local anchor = math.max(s.title or 0, s.author or 0)
      if anchor == 0 then anchor = s.root end
      for _, l in ipairs(block(indent, "")) do add_after(anchor, l) end
    end
  end

  local out = {}
  for i, line in ipairs(lines) do
    for _, l in ipairs(replace[i] or { line }) do out[#out + 1] = l end
    for _, l in ipairs(after[i] or {}) do out[#out + 1] = l end
  end
  return table.concat(out, "\n")
end

edit._rewrite = rewrite -- test seam

-- before = rpp.parse of the original: the rewrite must not change the
-- project's structure (track count, length).
local function verify(text, path, fields, before)
  local info = rpp.parse(text, path)
  if info.track_count ~= before.track_count or info.length ~= before.length then return false end
  for _, key in ipairs({ "title", "author" }) do
    local want = fields[key]
    if want ~= nil then
      if want == "" then want = nil end
      if info[key] ~= want then return false end
    end
  end
  if fields.notes ~= nil and info.notes ~= as_read(fields.notes) then return false end
  return true
end

local function write_file(path, text)
  local f, err = io.open(path, "wb")
  if not f then return false, err end
  local ok, werr = f:write(text)
  if not ok then f:close(); return false, werr end
  ok, werr = f:flush()
  if not ok then f:close(); return false, werr end
  ok, werr = f:close()
  if not ok then return false, werr end
  return true
end

local function read_file(path)
  local f, err = io.open(path, "rb")
  if not f then return nil, err end
  local text = f:read("a")
  f:close()
  if not text then return nil, "could not read " .. path end
  return text
end

-- ctx = { P, is_open(path) -> bool, now() -> number, rename? (tests) }
function edit.set_fields(path, fields, ctx)
  if ctx.is_open(path) then return false, "open" end
  if fields.title == nil and fields.author == nil and fields.notes == nil then return true end
  local P = ctx.P
  local rename = ctx.rename or os.rename

  local text, rerr = read_file(path)
  if not text then return false, rerr end
  local before = rpp.parse(text, path)
  local new_text, err = edit._rewrite(text, fields)
  if not new_text then return false, err end
  if not verify(new_text, path, fields, before) then return false, "the change could not be confirmed" end

  -- backup; a name already taken (two edits in one second) gets -2, -3, ...
  local stem = last_component(path):gsub("%.[^.]*$", "")
  local prefix = P.join(parent(path), stem .. "-" .. os.date("%Y-%m-%d_%H%M%S", ctx.now()) .. "-realobby")
  local backup, bok, berr
  for n = 1, 99 do
    backup = prefix .. (n == 1 and "" or ("-" .. n)) .. ".rpp-bak"
    bok, berr = P.copy(path, backup)
    if bok or not (berr and berr:find("destination exists", 1, true)) then break end
  end
  if not bok then return false, berr or "backup failed" end

  local tmp = path .. ".realobby-tmp"
  local wok, werr = write_file(tmp, new_text)
  if not wok then os.remove(tmp); return false, werr end
  local back = read_file(tmp)
  if back ~= new_text or not verify(back, path, fields, before) then
    os.remove(tmp)
    return false, "the change could not be confirmed"
  end

  if rename(tmp, path) then return true end
  -- Windows: rename cannot replace an existing file.
  local old = path .. ".realobby-old"
  local ok1, e1 = rename(path, old)
  if not ok1 then os.remove(tmp); return false, e1 or "could not replace the project" end
  local ok2, e2 = rename(tmp, path)
  if not ok2 then
    if rename(old, path) then
      os.remove(tmp)
      return false, e2 or "could not replace the project"
    end
    -- could not put the original back: keep every copy and say where they are
    return false, "could not replace the project; the original is at " .. old
      .. " and a backup is at " .. backup
  end
  os.remove(old) -- the original's bytes are in the backup
  return true
end

-- plan / apply -------------------------------------------------------------

local BAD_NAME = '[/\\:%*%?"<>|]'
local KEEP_DIRS = { Audio = true, Media = true, Peaks = true, Backups = true }
-- system clutter that never counts as "something else" in a song folder
local CLUTTER = { [".ds_store"] = true, ["thumbs.db"] = true, ["desktop.ini"] = true }

local function song_base(song)
  local key = versions.key(song.newest)
  return last_component(key)
end

local function new_plan(action, song)
  local paths = {}
  for i, v in ipairs(song.versions) do paths[i] = v.path end
  return { action = action, changes = {}, warnings = {}, song_paths = paths }
end

local function plan_move(P, plan, song, dest, dir, owned)
  if owned then
    if same_dir(parent(dir), dest) then
      plan.warnings[#plan.warnings + 1] = "The song is already in that folder."
      return plan
    end
    plan.changes[#plan.changes + 1] = { from = dir, to = P.join(dest, last_component(dir)) }
    plan.warnings[#plan.warnings + 1] = "The whole folder " .. last_component(dir) .. " moves, with everything in it."
  else
    if same_dir(dir, dest) then
      plan.warnings[#plan.warnings + 1] = "The song is already in that folder."
      return plan
    end
    for _, v in ipairs(song.versions) do
      plan.changes[#plan.changes + 1] = { from = v.path, to = P.join(dest, last_component(v.path)) }
    end
    plan.warnings[#plan.warnings + 1] = "Only the project files move; the song's audio stays where it is."
  end
  return plan
end

-- plan(action, song, arg, P) -> Plan. Never changes anything on disk.
function edit.plan(action, song, arg, P)
  local plan = new_plan(action, song)
  local dir = parent(song.newest)
  local base = song_base(song)
  local owned = last_component(dir) == base

  if action == "rename" then
    local new = arg or ""
    if new == "" or new:find(BAD_NAME) or new:find("^%s") or new:find("%s$")
      or new:find("^%.") or new:find("%.$") or new:find("[\0-\31]") then
      plan.warnings[#plan.warnings + 1] = "A name cannot be empty, start or end with a space or a dot, "
        .. 'or contain control characters or / \\ : * ? " < > |'
      return plan
    end
    if new == base then
      plan.warnings[#plan.warnings + 1] = "The name is unchanged."
      return plan
    end
    if new:lower() == base:lower() then
      plan.warnings[#plan.warnings + 1] = "Only the letter case changes; rename to a different name."
      return plan
    end
    for _, v in ipairs(song.versions) do
      local name = last_component(v.path)
      if name:sub(1, #base) ~= base then
        plan.changes = {}
        plan.warnings[#plan.warnings + 1] = "A version file does not match the song name: " .. name
        return plan
      end
      plan.changes[#plan.changes + 1] = { from = v.path, to = P.join(dir, new .. name:sub(#base + 1)) }
    end
    if owned then
      plan.changes[#plan.changes + 1] = { from = dir, to = P.join(parent(dir), new) }
    end
    -- refuse up front rather than stop half-way on an existing name
    local taken = {}
    -- case-insensitive: macOS and Windows treat "know me" and "Know Me" as one name
    for _, e in ipairs(P.list_dir(dir)) do taken[e.path:lower()] = true end
    if owned then
      for _, e in ipairs(P.list_dir(parent(dir))) do taken[e.path:lower()] = true end
    end
    for _, c in ipairs(plan.changes) do
      if taken[c.to:lower()] then
        plan.changes = {}
        plan.warnings[#plan.warnings + 1] = "Something named " .. last_component(c.to) .. " is already there."
        return plan
      end
    end
    return plan
  elseif action == "move" then
    return plan_move(P, plan, song, arg, dir, owned)
  elseif action == "archive" then
    local archive = P.join(arg, "_Archive")
    local found = false
    for _, e in ipairs(P.list_dir(arg)) do
      if e.name == "_Archive" and e.is_dir then found = true end
    end
    plan_move(P, plan, song, archive, dir, owned)
    if not found and #plan.changes > 0 then
      table.insert(plan.changes, 1, { from = nil, to = archive, mkdir = true })
    end
    return plan
  elseif action == "delete" then
    local mine, seen = {}, 0
    for _, v in ipairs(song.versions) do
      mine[last_component(v.path)] = true
      plan.changes[#plan.changes + 1] = { from = v.path, to = nil }
    end
    if owned then
      local only_song, subs = true, {}
      for _, e in ipairs(P.list_dir(dir)) do
        if mine[e.name] and not e.is_dir then
          seen = seen + 1
        elseif not e.is_dir and CLUTTER[e.name:lower()] then
          -- ignored; goes to the Trash with the folder
        elseif e.is_dir and KEEP_DIRS[e.name] then
          subs[#subs + 1] = e.name .. "/"
        elseif not e.is_dir and e.name:sub(1, #base) == base and e.name:lower():find("%.rpp%-bak$") then
          -- the song's own backup
        else
          only_song = false
        end
      end
      -- an unreadable listing never counts as "only the song"
      if only_song and seen == #song.versions then
        table.sort(subs)
        plan.changes = { { from = dir, to = nil } }
        plan.warnings[#plan.warnings + 1] = "The whole folder " .. last_component(dir) .. " goes to the Trash."
        if #subs > 0 then
          plan.warnings[#plan.warnings + 1] = "Audio files in " .. table.concat(subs, ", ") .. " go to the Trash too."
        end
        return plan
      end
    end
    plan.warnings[#plan.warnings + 1] = "Only the project files go to the Trash; the folder "
      .. last_component(dir) .. " stays."
    return plan
  end
  plan.warnings[#plan.warnings + 1] = "Unknown action: " .. tostring(action)
  return plan
end

-- apply(plan, ctx) -> ok, err, done. Stops at the first failure.
function edit.apply(plan, ctx)
  local P = ctx.P
  local done = {}
  for _, p in ipairs(plan.song_paths or {}) do
    if ctx.is_open(p) then return false, "open", done end
  end
  for _, c in ipairs(plan.changes) do
    if c.from and ctx.is_open(c.from) then return false, "open", done end
  end
  if #plan.changes == 0 then return false, "nothing to change", done end
  for _, c in ipairs(plan.changes) do
    local ok, err
    if c.mkdir then
      ok, err = P.mkdir(c.to)
    elseif c.to == nil then
      ok, err = P.trash(c.from)
    else
      ok, err = P.move(c.from, c.to)
    end
    if not ok then return false, err or "failed", done end
    done[#done + 1] = c
  end
  return true, nil, done
end

return edit
