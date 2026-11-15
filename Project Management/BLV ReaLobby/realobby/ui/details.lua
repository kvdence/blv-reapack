-- The right column: the selected song's title, author and file name; tiles
-- for BPM and time signature, length, tracks and plug-ins; an amber warning
-- for missing plug-ins or media (names on hover); the latest bounces (a click
-- shows the file in Finder or Explorer; bounce files are never opened);
-- up to 8 backups and the older versions (a click opens one, shift-click
-- with FX offline, a right-click offers Open in new tab); the notes; Open and
-- Open safely. The size sits beside the file name.
--
-- Bounces and backups are listed only for the selected song, once it has
-- rested for M.SETTLE seconds (and again when its newest version changes).
-- The media check (L:check_media) runs once per selection, after the same
-- rest. The unused-audio check (realobby/cleanup.lua) then runs a few
-- milliseconds per frame (M.CLEANUP_BUDGET), so the window stays responsive.
-- The heading and tiles show at once.
--
-- Reads from state: library, P, data, backup_dir, fx_offline_supported,
-- notice, open(song, override, path), use_template(row, kind), view, clock (seconds).
local theme = require("realobby.ui.theme")
local draw = require("realobby.ui.draw")
local format = require("realobby.ui.format")
local bounces = require("realobby.bounces")
local backups = require("realobby.backups")
local cleanup = require("realobby.cleanup")

local M = {}

M.MAX_BOUNCES = 5
M.FX_OFFLINE_NOTE = "Needs REAPER 7.74 or newer."
M.CLOUD_NOTE = "Not downloaded: open it in REAPER to download it."

local GAP = 11
local menu_rows = {}   -- list id -> { song, path } of the row whose right-click menu is open
M.SETTLE = 0.15     -- seconds a selection rests before its lists load
M.CLEANUP_BUDGET = 0.006   -- seconds of the unused-audio check per frame
local loaded = {}   -- { key, id, since, ready, bounces, backups } for the selected song

-- The selected song's bounces and backups. They are listed (and the media
-- check runs) once the selection has rested for M.SETTLE seconds at clock
-- time now, so arrowing through the table lists nothing on the way; until
-- then ready is false and the lists are empty. Listed again when the song's
-- newest version changes.
function M.lists(state, song, now)
  local id = song.key .. "\0" .. tostring(song.newest) .. "\0" .. tostring(song.mtime)
  if loaded.id ~= id then
    if loaded.key ~= song.key then state.notice = nil end
    loaded = { key = song.key, id = id, since = now, ready = false, bounces = {}, backups = {},
      checked = loaded.key == song.key and loaded.checked }
  end
  if loaded.ready or now - loaded.since < M.SETTLE then return loaded end
  local P = M.view_P(state)
  if not loaded.checked and state.library then state.library:check_media(song.key, P and P.list_dir) end
  loaded.checked = true
  if P then
    local extra = state.data and state.data.bounce_folders or nil
    loaded.bounces = bounces.list(song.info or {}, song.newest, P, extra)
    loaded.backups = backups.list(song.newest, P, state.backup_dir)
  end
  loaded.ready = true
  return loaded
end

-- The read and folder context the clean-up uses (also for its dialog).
function M.cleanup_ctx(state, yield)
  local function read(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local text = f:read("a")
    f:close()
    return text
  end
  return { P = state.P, read = read, backup_dir = state.backup_dir,
    bounce_folders = state.data and state.data.bounce_folders or nil,
    refs = state.library and state.library.media_refs and state.library:media_refs() or nil, yield = yield }
end

-- Steps the selected song's unused-audio check; returns the result, or nil
-- while it runs. loaded.cleanup = { result } or { error } once done.
-- True until the library has read every folder once: until then other
-- songs' media are not all known, so nothing may be offered.
function M.library_partial(state)
  local L = state.library
  return state.scanning == true or (L ~= nil and L.first_walk ~= nil and L:first_walk())
end

local function cleanup_step(state, song, clock)
  if not loaded.ready or loaded.cleanup or not state.P or M.library_partial(state) then return end
  if not loaded.cleanup_co then
    loaded.cleanup_co = coroutine.create(function()
      local ctx = M.cleanup_ctx(state, coroutine.yield)
      ctx.P = M.view_P(state) or ctx.P
      return cleanup.scan(song, ctx)
    end)
  end
  local started = clock()
  while coroutine.status(loaded.cleanup_co) ~= "dead" do
    local ok, res, err = coroutine.resume(loaded.cleanup_co)
    if not ok then
      loaded.cleanup = { error = tostring(res) }
      break
    end
    if coroutine.status(loaded.cleanup_co) == "dead" then
      loaded.cleanup = res and { result = res } or { error = err }
      break
    end
    if clock() - started >= M.CLEANUP_BUDGET then break end
  end
  if loaded.cleanup then loaded.cleanup_co = nil end
end

M.MAX_BACKUPS = 8
local BACKUP_KIND = { bak = "Previous save", timestamped = "Timestamped" }

-- Backup rows { path, kind, mtime }: at most M.MAX_BACKUPS, newest first (the
-- order backups.list gives).
function M.backup_rows(list)
  local out = {}
  for i = 1, math.min(M.MAX_BACKUPS, #list) do
    local b = list[i]
    out[i] = { path = b.path, mtime = b.mtime,
      kind = b.realobby and "Before a ReaLobby edit" or BACKUP_KIND[b.kind] or b.kind }
  end
  return out
end

-- The song's older versions { path, label, mtime }, newest first: every
-- version but the newest (which Open opens).
function M.version_rows(song)
  local out = {}
  for i = 2, #(song.versions or {}) do
    local v = song.versions[i]
    out[#out + 1] = { path = v.path, mtime = v.mtime,
      label = v.number and ("Version " .. v.number) or "Original" }
  end
  return out
end

-- Forget the loaded lists (the next draw lists them again).
function M.reset()
  loaded = {}
  M.forget_listings()
end

-- Folder listings for the details, kept M.LISTING_TTL seconds: the song's
-- folder serves the bounces, the backups, the media check and the
-- unused-audio check, and going back to a song lists nothing again. Changes
-- (rename, clean-up) always list afresh through state.P.
M.LISTING_TTL = 10
local listings = {}
function M.forget_listings() listings = {} end

function M.view_P(state)
  local P = state.P
  if not P then return nil end
  local clock = state.clock or os.clock
  local V = setmetatable({}, { __index = P })
  function V.list_dir(dir)
    local now = clock()
    local hit = listings[dir]
    if hit and now - hit.t < M.LISTING_TTL then return hit.entries end
    local entries = P.list_dir(dir) or {}
    listings[dir] = { t = now, entries = entries }
    return entries
  end
  return V
end

-- Buttons ---------------------------------------------------------------------

local function button(ctx, label, primary)
  local ImGui, c = theme.ImGui, theme.colors
  theme.push_font(ctx, "ui_bold", theme.sizes.button)
  local n = 0
  if primary then
    ImGui.PushStyleColor(ctx, ImGui.Col_Button, c.teal)
    ImGui.PushStyleColor(ctx, ImGui.Col_ButtonHovered, 0x6BE0D0FF)
    ImGui.PushStyleColor(ctx, ImGui.Col_ButtonActive, 0x45BFAEFF)
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, c.button_text)
    n = 4
  else
    ImGui.PushStyleColor(ctx, ImGui.Col_Button, 0)
    ImGui.PushStyleColor(ctx, ImGui.Col_Border, c.control_border)
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, c.button2_text)
    n = 3
  end
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_FramePadding, 12, primary and 7 or 6)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_FrameRounding, 9)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_FrameBorderSize, primary and 0 or 1)
  local clicked = ImGui.Button(ctx, label)
  ImGui.PopStyleVar(ctx, 3)
  ImGui.PopStyleColor(ctx, n)
  theme.pop_font(ctx)
  return clicked
end

M.button = button   -- the dialogs use the same buttons

local function button_h(ctx)
  local _, h = draw.measure(ctx, "ui_bold", theme.sizes.button, "Open")
  return h + 14
end

-- Pieces ----------------------------------------------------------------------

-- Small text in a faint container, full width; returns its height.
local function note_row(ctx, dl, x, y, w, s, color)
  local size = theme.sizes.small
  local _, h = draw.measure(ctx, "ui", size, "A")
  local rh = h + 10
  theme.ImGui.DrawList_AddRectFilled(dl, x, y, x + w, y + rh, theme.colors.bounce_bg, 7)
  draw.text_fit(ctx, dl, "ui", size, x + 8, y + 5, color or theme.colors.meta, s, w - 16)
  return rh
end

local function heading(ctx, dl, x, y, w, title, sub)
  local c = theme.colors
  local _, th = draw.measure(ctx, "ui_bold", theme.sizes.title, "A")
  draw.text_fit(ctx, dl, "ui_bold", theme.sizes.title, x, y, c.ink, title, w)
  local _, sh = draw.measure(ctx, "ui", theme.sizes.meta, "A")
  draw.text_fit(ctx, dl, "ui", theme.sizes.meta, x, y + th + 2, c.meta, sub, w)
  return th + 2 + sh
end

local function tile(ctx, dl, x, y, w, value, label)
  local c = theme.colors
  local _, vh = draw.measure(ctx, "ui_bold", theme.sizes.tile_value, "A")
  local _, lh = draw.measure(ctx, "ui", theme.sizes.tile_label, "A")
  local h = 8 + vh + 1 + lh + 8
  draw.tile(dl, x, y, w, h, 10)
  draw.text_fit(ctx, dl, "ui_bold", theme.sizes.tile_value, x + 10, y + 8, c.ink, value, w - 20)
  draw.text_fit(ctx, dl, "ui", theme.sizes.tile_label, x + 10, y + 8 + vh + 1, c.mono, label, w - 20)
  return h
end

-- An amber warning tile; hovering it shows names (one per line).
local function warning(ctx, dl, x, y, w, s, names, id)
  local ImGui, c = theme.ImGui, theme.colors
  local size = theme.sizes.small
  local _, th = draw.measure(ctx, "ui", size, "A")
  local h = th + 14
  ImGui.SetCursorScreenPos(ctx, x, y)
  ImGui.InvisibleButton(ctx, id, w, h)
  ImGui.DrawList_AddRectFilled(dl, x, y, x + w, y + h, c.warn_bg, 9)
  ImGui.DrawList_AddRect(dl, x + 0.5, y + 0.5, x + w - 0.5, y + h - 0.5, c.warn_border, 9, 0, 1)
  draw.text_fit(ctx, dl, "ui", size, x + 9, y + 7, c.warn, s, w - 18)
  if ImGui.IsItemHovered(ctx) and #names > 0 then
    ImGui.SetTooltip(ctx, table.concat(names, "\n"))
  end
  return h
end

local function group_label(ctx, dl, x, y, s)
  local _, h = draw.measure(ctx, "ui_bold", theme.sizes.group, "A")
  draw.text(dl, "ui_bold", theme.sizes.group, x, y, theme.colors.group, s:upper())
  return h
end

local function bounce_rows(ctx, dl, state, x, y, w, list)
  local ImGui, c = theme.ImGui, theme.colors
  local _, lh = draw.measure(ctx, "ui", theme.sizes.small, "A")
  local rh = lh + 10
  local n = math.min(M.MAX_BOUNCES, #list)
  for i = 1, n do
    local b = list[i]
    local ry = y + (i - 1) * (rh + 2)
    ImGui.SetCursorScreenPos(ctx, x, ry)
    local clicked = ImGui.InvisibleButton(ctx, "##bounce" .. i, w, rh)
    local hovered = ImGui.IsItemHovered(ctx)
    ImGui.DrawList_AddRectFilled(dl, x, ry, x + w, ry + rh, hovered and c.row_hover or c.bounce_bg, 7)
    local right = b.cloud_only and "not downloaded" or format.date(b.mtime)
    local rf = b.cloud_only and "ui" or "mono"
    local rs = b.cloud_only and theme.sizes.small or theme.sizes.bounce_date
    local rw, rhh = draw.measure(ctx, rf, rs, right)
    draw.text(dl, rf, rs, x + w - 8 - rw, ry + (rh - rhh) / 2, b.cloud_only and c.faint or c.mono, right)
    draw.text_fit(ctx, dl, "ui", theme.sizes.small, x + 8, ry + 5, b.cloud_only and c.faint or c.cell,
      format.bounce_label(b), w - 24 - rw)
    if hovered then ImGui.SetTooltip(ctx, b.name .. "\nClick to show it in " .. (state.file_manager or "the file manager") .. ".") end
    if clicked and state.P then state.P.reveal(b.path) end
  end
  if n == 0 then
    return note_row(ctx, dl, x, y, w, "No bounces found", c.faint)
  end
  return n * (rh + 2) - 2
end

-- Rows a click opens: label on the left, date on the right, each in its own
-- container. A click opens without "Open with FX offline" (the footer's
-- other choices apply), Shift-click opens with FX offline; a right-click
-- menu offers Open in new tab. Returns the height.
local function open_rows(ctx, dl, state, song, x, y, w, list, id, empty)
  local ImGui, c = theme.ImGui, theme.colors
  local _, lh = draw.measure(ctx, "ui", theme.sizes.small, "A")
  local rh = lh + 10
  for i, r in ipairs(list) do
    local ry = y + (i - 1) * (rh + 2)
    ImGui.SetCursorScreenPos(ctx, x, ry)
    local clicked = ImGui.InvisibleButton(ctx, id .. i, w, rh)
    local hovered = ImGui.IsItemHovered(ctx)
    ImGui.DrawList_AddRectFilled(dl, x, ry, x + w, ry + rh, hovered and c.row_hover or c.bounce_bg, 7)
    local right = format.date(r.mtime)
    local rw, rhh = draw.measure(ctx, "mono", theme.sizes.bounce_date, right)
    draw.text(dl, "mono", theme.sizes.bounce_date, x + w - 8 - rw, ry + (rh - rhh) / 2, c.mono, right)
    draw.text_fit(ctx, dl, "ui", theme.sizes.small, x + 8, ry + 5, c.cell, r.kind or r.label, w - 24 - rw)
    if hovered then
      ImGui.SetMouseCursor(ctx, ImGui.MouseCursor_Hand)
      ImGui.SetTooltip(ctx, format.file_name(r.path)
        .. "\nClick to open it. Shift-click opens it with FX offline. Right-click to open it in a new tab.")
    end
    if clicked and state.open then
      state.open(song, { fx_offline = ImGui.IsKeyDown(ctx, ImGui.Mod_Shift) }, r.path)
    end
    if ImGui.IsItemClicked(ctx, ImGui.MouseButton_Right) then
      menu_rows[id] = { song = song, path = r.path }
      ImGui.OpenPopup(ctx, id .. "menu")
    end
  end
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_WindowPadding, 8, 8)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_ItemSpacing, 8, 6)
  local menu_open = ImGui.BeginPopup(ctx, id .. "menu")
  ImGui.PopStyleVar(ctx, 2)
  if menu_open then
    local m = menu_rows[id]
    if m and ImGui.MenuItem(ctx, "Open in new tab") and state.open then
      state.open(m.song, { fx_offline = false, new_tab = true }, m.path)
    end
    ImGui.EndPopup(ctx)
  end
  if #list == 0 then return note_row(ctx, dl, x, y, w, empty, c.faint) end
  return #list * (rh + 2) - 2
end

-- Bottom of the column: notice, the FX-offline note and the buttons, laid
-- out upwards from `bottom`. Returns the top of what it drew.
local function actions(ctx, dl, state, song, x, bottom, w, template_kind)
  local ImGui, c = theme.ImGui, theme.colors
  local by = bottom - button_h(ctx)
  local supported = state.fx_offline_supported ~= false
  ImGui.SetCursorScreenPos(ctx, x, by)
  if template_kind then
    if template_kind == "project" and button(ctx, "New from this template", true) and state.use_template then
      state.use_template(song, template_kind)
    end
  else
    if button(ctx, "Open", true) and state.open then state.open(song, nil) end
    ImGui.SameLine(ctx, 0, 6)
    if not supported then ImGui.BeginDisabled(ctx) end
    if button(ctx, "Open safely", false) and state.open then state.open(song, { fx_offline = true }) end
    if not supported then ImGui.EndDisabled(ctx) end
    ImGui.SameLine(ctx, 0, 6)
    if button(ctx, "Open folder", false) and state.P and song.newest then state.P.open_folder(song.newest) end
  end
  local top = by
  local _, nh = draw.measure(ctx, "ui", theme.sizes.small, "A")
  if not template_kind and not supported then
    top = top - (nh + 10) - 8
    note_row(ctx, dl, x, top, w, M.FX_OFFLINE_NOTE, c.faint)
  end
  if state.notice then
    top = top - (nh + 10) - 8
    note_row(ctx, dl, x, top, w, state.notice, c.warn)
  end
  return top
end

M.WAIT_NOTE = "Waiting until ReaLobby has read every folder, so audio other songs use is known."
M.TIME_TIP = "Time worked on this song in REAPER: it counts while the song is the open tab,\n"
  .. "and pauses after 5 minutes without mouse movement, edits or playback."

-- The unused-audio tile: "…" while checking, the size once known; a click
-- opens the clean-up when there is something to clean.
function M.unused_tile(ctx, dl, state, song, x, y, w)
  local ImGui = theme.ImGui
  local cu = loaded.cleanup
  local value, label, tip = "…", "unused audio", "Checking the song's media folders…"
  if M.library_partial(state) then tip = M.WAIT_NOTE end
  local can = false
  if cu and cu.result then
    local n = #cu.result.files
    if n == 0 then
      value, tip = "None", "No unused audio in the song's media folders."
    else
      value = format.size(cu.result.total)
      label = "unused · " .. format.count(n, "file")
      tip = "Audio in the song's media folders that no project or backup uses.\nClick to review it and move it to the Trash."
      can = true
    end
  elseif cu then
    value, tip = "—", cu.error or "Could not check."
  end
  ImGui.SetCursorScreenPos(ctx, x, y)
  local h = tile(ctx, dl, x, y, w, value, label)
  ImGui.SetCursorScreenPos(ctx, x, y)
  local clicked = ImGui.InvisibleButton(ctx, "##unused", w, h)
  if ImGui.IsItemHovered(ctx) then
    if can then ImGui.SetMouseCursor(ctx, ImGui.MouseCursor_Hand) end
    ImGui.SetTooltip(ctx, tip)
  end
  if clicked and can and state.cleanup then state.cleanup(song) end
  return h
end

-- Panels ----------------------------------------------------------------------

local function template_panel(ctx, dl, state, row, x, y0, w, h)
  local kind = state.view and state.view.value or "project"
  local y = y0 + heading(ctx, dl, x, y0, w, row.name, format.file_name(row.path)) + GAP
  note_row(ctx, dl, x, y, w, row.path)
  actions(ctx, dl, state, row, x, y0 + h, w, kind)
end

local function song_panel(ctx, dl, state, song, x, y0, w, h)
  local c = theme.colors
  local info = song.info or {}
  local L = M.lists(state, song, (state.clock or os.clock)())
  local y = y0

  local sub = format.file_name(song.newest) .. " · " .. format.size(song.size)
  if (song.display_author or "") ~= "" then sub = song.display_author .. " · " .. sub end
  y = y + heading(ctx, dl, x, y, w, song.display_title or "", sub) + GAP
  -- Ruling R28: a song inside an _Archive folder.
  if song.archived then y = y + note_row(ctx, dl, x, y, w, "Archived", c.warn) + GAP end
  if song.cloud_only then y = y + note_row(ctx, dl, x, y, w, M.CLOUD_NOTE, c.faint) + GAP end

  local tw = (w - 8) / 2
  local bpm_label = info.timesig and ("BPM · " .. info.timesig) or "BPM"
  local th = tile(ctx, dl, x, y, tw, format.bpm(info.tempo), bpm_label)
  tile(ctx, dl, x + tw + 8, y, tw, format.length(info.length), "length")
  y = y + th + 8
  tile(ctx, dl, x, y, tw, tostring(info.track_count or 0), "tracks")
  tile(ctx, dl, x + tw + 8, y, tw, tostring(#(info.fx or {})), "plug-ins")
  y = y + th + 8
  local wt = tile(ctx, dl, x, y, tw, format.worked(song.time_worked), "time worked")
  if theme.ImGui.IsMouseHoveringRect(ctx, x, y, x + tw, y + wt) then
    theme.ImGui.SetTooltip(ctx, M.TIME_TIP)
  end
  cleanup_step(state, song, state.clock or os.clock)
  M.unused_tile(ctx, dl, state, song, x + tw + 8, y, tw)
  y = y + th + GAP

  local fx, media = song.missing_fx or {}, song.missing_media or {}
  if #fx > 0 then
    y = y + warning(ctx, dl, x, y, w, format.count(#fx, "plug-in") .. " not installed", fx, "##warn_fx") + 8
  end
  if #media > 0 then
    local names = {}
    for i, p in ipairs(media) do names[i] = format.file_name(p) end
    y = y + warning(ctx, dl, x, y, w, format.count(#media, "media file") .. " missing", names, "##warn_media") + 8
  end
  if #fx > 0 or #media > 0 then y = y + GAP - 8 end

  y = y + group_label(ctx, dl, x, y + 4, "Latest bounces") + 4 + 6
  if L.ready then
    y = y + bounce_rows(ctx, dl, state, x, y, w, L.bounces) + GAP
  else
    y = y + note_row(ctx, dl, x, y, w, "") + GAP   -- an empty row while the selection settles
  end

  local top = actions(ctx, dl, state, song, x, y0 + h, w)

  -- Backups, older versions and notes scroll between the bounces and the buttons.
  local room = top - GAP - y
  if room < 24 then return end
  local ImGui = theme.ImGui
  ImGui.SetCursorScreenPos(ctx, x, y)
  if ImGui.BeginChild(ctx, "##details_lists", w, room, ImGui.ChildFlags_None, ImGui.WindowFlags_NoBackground) then
    local cdl = ImGui.GetWindowDrawList(ctx)
    local cx, cy0 = ImGui.GetCursorScreenPos(ctx)
    local cw = select(1, ImGui.GetContentRegionAvail(ctx))
    local cy = cy0

    cy = cy + group_label(ctx, cdl, cx, cy + 4, "Backups " .. (L.ready and tostring(#L.backups) or "")) + 4 + 6
    if L.ready then
      cy = cy + open_rows(ctx, cdl, state, song, cx, cy, cw, M.backup_rows(L.backups), "##backup", "No backups found") + GAP
    else
      cy = cy + note_row(ctx, cdl, cx, cy, cw, "") + GAP
    end

    local older = M.version_rows(song)
    cy = cy + group_label(ctx, cdl, cx, cy + 4, "Versions " .. #(song.versions or {})) + 4 + 6
    cy = cy + open_rows(ctx, cdl, state, song, cx, cy, cw, older, "##version", "No older versions") + GAP

    local notes = info.notes or ""
    if notes:find("%S") then
      local size = theme.sizes.small
      local _, lh = draw.measure(ctx, "ui", size, "A")
      local lines = draw.wrap(ctx, "ui", size, notes, cw - 20, 400)
      local nh = #lines * (lh + 2) - 2 + 16
      draw.tile(cdl, cx, cy, cw, nh, 10)
      for i, line in ipairs(lines) do
        draw.text(cdl, "ui", size, cx + 10, cy + 8 + (i - 1) * (lh + 2), c.cell, line)
      end
      cy = cy + nh
    end

    ImGui.SetCursorScreenPos(ctx, cx, cy0)
    ImGui.Dummy(ctx, cw, math.max(1, cy - cy0))
    ImGui.EndChild(ctx)
  end
end

function M.draw(ctx, state, song, w, h)
  local ImGui = theme.ImGui
  local dl = ImGui.GetWindowDrawList(ctx)
  local x, y = ImGui.GetCursorScreenPos(ctx)
  if not w or not h then w, h = ImGui.GetContentRegionAvail(ctx) end
  if not song then
    loaded = {}
    note_row(ctx, dl, x, y, w, state.view and state.view.group == "templates"
      and "Select a template to see it here." or "Select a song to see its details.")
    return
  end
  if song.info == nil and song.path then
    template_panel(ctx, dl, state, song, x, y, w, h)
  else
    song_panel(ctx, dl, state, song, x, y, w, h)
  end
end

return M
