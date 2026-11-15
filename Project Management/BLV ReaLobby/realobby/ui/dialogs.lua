-- The right-click song menu and the dialogs: confirm a change, rename, move,
-- edit notes, edit title and author, new from template, settings and the
-- first run. Every dialog is one ImGui modal popup over the glass, in the
-- theme's popup colour. The work itself is in actions.lua.
--
-- state.dialog names the open dialog and state.dialog_args holds what it is
-- about ({ song = ..., plan = ..., title = ... }). Esc closes the dialog
-- (the shell closes the window on Esc only when no dialog is open).
--
-- Reads from state: env (actions' env), data, templates, template_path,
-- startup_on, reaper_prompt, file_manager, P.
local theme = require("realobby.ui.theme")
local draw = require("realobby.ui.draw")
local format = require("realobby.ui.format")
local details = require("realobby.ui.details")
local A = require("realobby.ui.actions")
local folders = require("realobby.ui.folders")
local cleanup = require("realobby.cleanup")

local M = {}

local POPUP = "##realobby_dialog"
local WIDTH = { confirm = 640, settings = 660, first_run = 600, new_from_template = 600, cleanup = 640 }
local DEFAULT_W = 560

local COUNT_BUDGET = 0.008   -- seconds of folder listings per frame for the browsers' counts
local count_deadline, counted = 0, false

local ImGui
local d = {}          -- the open dialog's own fields (buffers, errors)
local cur = {}        -- { name, args } the fields belong to
local frame_ctx       -- the context M.draw is drawing (close() needs it)

-- Opening ---------------------------------------------------------------------

local function open(state, name, args)
  state.dialog = name
  state.dialog_args = args or {}
end

-- arg: the new name (rename) or folder (move); "Do it" plans again with it.
function M.confirm(state, song, plan, title, arg)
  open(state, "confirm", { song = song, plan = plan, title = title, action = plan.action, arg = arg })
end

-- kind: "notes" or "fields" (title and author).
function M.edit_fields(state, song, kind)
  open(state, kind == "notes" and "edit_notes" or "edit_fields", { song = song })
end

function M.new_from_template(state) open(state, "new_from_template") end
function M.settings(state) open(state, "settings") end
function M.cleanup(state, song) open(state, "cleanup", { song = song }) end
function M.first_run(state) open(state, "first_run") end

local function close(state)
  if state.dialog == "new_from_template" then state.template_path = nil end
  state.dialog, state.dialog_args = nil, nil
  ImGui.CloseCurrentPopup(frame_ctx)
end

-- Pieces ----------------------------------------------------------------------

local function avail_w(ctx)
  return (select(1, ImGui.GetContentRegionAvail(ctx)))
end

-- Text in a container, wrapped to the dialog's width. kind: nil (plain tile),
-- "warn" (amber), "faint" or "mono" (paths).
local function box(ctx, s, kind)
  local c = theme.colors
  local fg, bg, border = c.cell, c.tile, c.line
  if kind == "warn" then fg, bg, border = c.warn, c.warn_bg, c.warn_border
  elseif kind == "faint" then fg = c.meta end
  local font = kind == "mono" and "mono" or "ui"
  local size = kind == "mono" and theme.sizes.mono or theme.sizes.small
  local w = avail_w(ctx)
  theme.push_font(ctx, font, size)
  local _, th = ImGui.CalcTextSize(ctx, s, nil, nil, false, w - 20)
  theme.pop_font(ctx)
  local x, y = ImGui.GetCursorScreenPos(ctx)
  local dl = ImGui.GetWindowDrawList(ctx)
  local h = th + 14
  ImGui.DrawList_AddRectFilled(dl, x, y, x + w, y + h, bg, 9)
  ImGui.DrawList_AddRect(dl, x + 0.5, y + 0.5, x + w - 0.5, y + h - 0.5, border, 9, 0, 1)
  ImGui.DrawList_AddTextEx(dl, theme.fonts[font], size, x + 10, y + 7, fg, s, w - 20)
  ImGui.Dummy(ctx, w, h)
end

local function heading(ctx, s)
  theme.push_font(ctx, "ui_bold", 16)
  ImGui.Text(ctx, s)
  theme.pop_font(ctx)
  ImGui.Dummy(ctx, 0, 2)
end

local function section(ctx, s)
  ImGui.Dummy(ctx, 0, 4)
  theme.push_font(ctx, "ui_bold", theme.sizes.group)
  ImGui.PushStyleColor(ctx, ImGui.Col_Text, theme.colors.group)
  ImGui.Text(ctx, s:upper())
  ImGui.PopStyleColor(ctx)
  theme.pop_font(ctx)
end

local function button(ctx, label, primary) return details.button(ctx, label, primary) end

local function button_w(ctx, label)
  return draw.measure(ctx, "ui_bold", theme.sizes.button, label) + 24
end

-- A single-line field taking the width left after `reserve` px.
local function field(ctx, id, hint, value, reserve, flags)
  ImGui.SetNextItemWidth(ctx, math.max(80, avail_w(ctx) - (reserve or 0)))
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_FrameBorderSize, 1)
  ImGui.PushStyleColor(ctx, ImGui.Col_Border, theme.colors.control_border)
  ImGui.PushStyleColor(ctx, ImGui.Col_FrameBg, theme.colors.tile)
  local changed, v = ImGui.InputTextWithHint(ctx, id, hint or "", value or "", flags or 0)
  ImGui.PopStyleColor(ctx, 2)
  ImGui.PopStyleVar(ctx)
  return changed, v
end

local function error_box(ctx, s)
  if s and s ~= "" then box(ctx, s, "warn") end
end

-- Buttons laid out from the right edge: list of { label, primary, disabled }.
-- Returns the index of the clicked one.
local function buttons(ctx, list)
  ImGui.Dummy(ctx, 0, 4)
  local total = 0
  for i, b in ipairs(list) do total = total + button_w(ctx, b[1]) + (i > 1 and 8 or 0) end
  local x = ImGui.GetCursorPosX(ctx) + avail_w(ctx) - total
  ImGui.SetCursorPosX(ctx, x)
  local clicked
  for i, b in ipairs(list) do
    if i > 1 then ImGui.SameLine(ctx, 0, 8) end
    ImGui.BeginDisabled(ctx, b[3] == true)
    if button(ctx, b[1], b[2]) then clicked = i end
    ImGui.EndDisabled(ctx)
  end
  return clicked
end

-- A clickable container with one line of text; returns clicked, hovered.
local function chip(ctx, id, s, w, kind)
  local c = theme.colors
  local font, size = "ui", theme.sizes.small
  local tw, th = draw.measure(ctx, font, size, s)
  w = w or (tw + 20)
  local h = th + 12
  local x, y = ImGui.GetCursorScreenPos(ctx)
  local clicked = ImGui.InvisibleButton(ctx, id, w, h)
  local hovered = ImGui.IsItemHovered(ctx)
  local dl = ImGui.GetWindowDrawList(ctx)
  local bg = kind == "suggest" and theme.with_alpha(c.teal, hovered and 0.22 or 0.13)
    or (hovered and c.row_hover or c.tile)
  ImGui.DrawList_AddRectFilled(dl, x, y, x + w, y + h, bg, 8)
  ImGui.DrawList_AddRect(dl, x + 0.5, y + 0.5, x + w - 0.5, y + h - 0.5, c.line, 8, 0, 1)
  draw.text_fit(ctx, dl, font, size, x + 10, y + 6, kind == "suggest" and c.teal or c.cell, s, w - 20)
  if hovered then ImGui.SetMouseCursor(ctx, ImGui.MouseCursor_Hand) end
  return clicked, hovered
end

-- Chips in rows that wrap at the dialog's width; returns the clicked index.
local function chip_row(ctx, id, labels, sep)
  local clicked
  local x0 = ImGui.GetCursorScreenPos(ctx)
  local right = x0 + avail_w(ctx)
  for i, label in ipairs(labels) do
    local w = draw.measure(ctx, "ui", theme.sizes.small, label) + 20
    if i > 1 then
      ImGui.SameLine(ctx, 0, sep and 4 or 6)
      local sep_w = sep and (draw.measure(ctx, "ui", theme.sizes.small, "›") + 8) or 0
      if select(1, ImGui.GetCursorScreenPos(ctx)) + sep_w + w > right then
        ImGui.NewLine(ctx)
      elseif sep then
        theme.push_font(ctx, "ui", theme.sizes.small)
        ImGui.PushStyleColor(ctx, ImGui.Col_Text, theme.colors.faint)
        ImGui.AlignTextToFramePadding(ctx)
        ImGui.Text(ctx, "›")
        ImGui.PopStyleColor(ctx)
        theme.pop_font(ctx)
        ImGui.SameLine(ctx, 0, 4)
      end
    end
    if chip(ctx, id .. i, label) then clicked = i end
  end
  return clicked
end

-- The folder browser under a folder field (realobby/ui/folders.lua does the
-- navigation): REAPER's project folder as a one-click suggestion, shortcuts,
-- the breadcrumb, the folders here with their project counts, then "Use this
-- folder", "Open" and "Cancel". Returns the chosen folder, or nil; closed is
-- true when the browser should close.
local function browser(ctx, state, b)
  local c = theme.colors
  local nav = b.nav
  -- Project counts: listings until this frame's ~8 ms budget, shared by
  -- every open browser, is spent; the first browser lists at least one.
  nav:step({ clock = state.clock or os.clock, deadline = count_deadline, min = counted and 0 or 1 })
  counted = true
  local chosen, closed

  if chip(ctx, "##suggest", b.suggest_label, avail_w(ctx), "suggest") then
    if folders.usable(b.suggest) then chosen = b.suggest else b.err = A.ROOT_MSG end
  end
  ImGui.Dummy(ctx, 0, 2)
  local labels = {}
  for i, sc in ipairs(b.shortcuts) do labels[i] = sc.label end
  local hit = chip_row(ctx, "##short", labels)
  if hit then nav:go(b.shortcuts[hit].path); b.sel = nil; b.err = nil end
  ImGui.Dummy(ctx, 0, 2)
  local crumbs = nav:crumbs()
  labels = {}
  for i, cr in ipairs(crumbs) do labels[i] = cr.label end
  hit = chip_row(ctx, "##crumb", labels, true)
  if hit then nav:go(crumbs[hit].path); b.sel = nil; b.err = nil end
  ImGui.Dummy(ctx, 0, 2)

  -- The folders here: a click selects, a double-click (or Open) goes in.
  local list = nav:entries()
  local _, lh = draw.measure(ctx, "ui", theme.sizes.small, "A")
  local rh = lh + 12
  local w = avail_w(ctx)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_WindowPadding, 0, 0)
  local visible = ImGui.BeginChild(ctx, "##folders", w, 200, ImGui.ChildFlags_None, ImGui.WindowFlags_NoBackground)
  ImGui.PopStyleVar(ctx)
  if visible then
    local dl = ImGui.GetWindowDrawList(ctx)
    local cw = select(1, ImGui.GetContentRegionAvail(ctx))
    local enter
    for i, e in ipairs(list) do
      local x, y = ImGui.GetCursorScreenPos(ctx)
      local click = ImGui.InvisibleButton(ctx, "##f" .. i, cw, rh)
      local hovered = ImGui.IsItemHovered(ctx)
      if click then b.sel = e.name end
      if hovered and ImGui.IsMouseDoubleClicked(ctx, ImGui.MouseButton_Left) then enter = e.name end
      local on = b.sel == e.name
      ImGui.DrawList_AddRectFilled(dl, x, y, x + cw, y + rh, on and c.selected or (hovered and c.row_hover or c.bounce_bg), 7)
      local right = e.rpp == nil and "…" or (e.rpp == 0 and "no projects" or format.count(e.rpp, "project"))
      local rw, rhh = draw.measure(ctx, "ui", theme.sizes.small, right)
      draw.text(dl, "ui", theme.sizes.small, x + cw - 10 - rw, y + (rh - rhh) / 2,
        (e.rpp or 0) > 0 and c.teal or c.faint, right)
      draw.text_fit(ctx, dl, "ui", theme.sizes.small, x + 10, y + 6, c.cell, e.name, cw - 30 - rw)
      ImGui.Dummy(ctx, 0, 0)
      ImGui.SetCursorScreenPos(ctx, x, y + rh + 2)
    end
    if #list == 0 then box(ctx, "No folders here.", "faint") end
    ImGui.Dummy(ctx, 0, 0)
    ImGui.EndChild(ctx)
    if enter then nav:into(enter); b.sel = nil; b.err = nil end
  end

  local here = nav:path()
  local hit2 = buttons(ctx, { { "Cancel", false }, { "Open", false, b.sel == nil }, { "Use this folder", true, not folders.usable(here) } })
  if hit2 == 1 then closed = true
  elseif hit2 == 2 and b.sel then nav:into(b.sel); b.sel = nil; b.err = nil
  elseif hit2 == 3 then chosen = here end
  if not folders.usable(here) then box(ctx, A.ROOT_MSG, "faint") end
  error_box(ctx, b.err)
  if chosen then closed = true end
  return chosen, closed
end

-- Opens the browser for field id at REAPER's project folder (or
-- state.browse_start, set by the preview).
local function open_browser(state, id)
  local B = state.env.B
  local home = B.home()
  local suggest, from_ini = folders.project_folder(B.ini_text(), home)
  d.browse[id] = {
    nav = folders.new({ P = state.P, start = state.browse_start or suggest }),
    suggest = suggest,
    suggest_label = folders.suggestion_label(suggest, from_ini, home),
    shortcuts = folders.shortcuts({ P = state.P, os = B.os(), home = home, drives = B.drives() }),
  }
end

-- A folder: path field, "Choose…" (opens the folder browser below it) and an
-- optional action button. Returns the new text and whether the action button
-- was clicked.
local function folder_field(ctx, state, id, value, action)
  d.browse = d.browse or {}
  local open_b = d.browse[id]
  local choose = open_b and "Close" or "Choose…"
  local reserve = button_w(ctx, "Choose…") + 8 + (action and (button_w(ctx, action) + 8) or 0)
  local _, v = field(ctx, id, "Folder path", value, reserve)
  ImGui.SameLine(ctx, 0, 8)
  if button(ctx, choose, false) then
    if open_b then d.browse[id] = nil else open_browser(state, id) end
  end
  if state.preview_browse == id then   -- tools/realobby/preview.sh
    state.preview_browse = nil
    open_browser(state, id)
  end
  local clicked = false
  if action then
    ImGui.SameLine(ctx, 0, 8)
    clicked = button(ctx, action, false)
  end
  if d.browse[id] then
    local picked, closed = browser(ctx, state, d.browse[id])
    if picked then v = picked end
    if closed then d.browse[id] = nil end
  end
  return v, clicked
end

-- Confirm ---------------------------------------------------------------------

local function confirm_body(ctx, state, args)
  local plan, song = args.plan, args.song
  heading(ctx, (args.title or "Confirm") .. ": " .. (song.display_title or format.file_name(song.newest)))
  for _, w in ipairs(plan.warnings or {}) do box(ctx, w, "warn") end
  local view = A.confirm_view(plan)
  if #view.lines > 0 then
    section(ctx, d.failed and "Planned changes" or "These changes will happen")
    box(ctx, "In " .. view.folder .. ":", "faint")
    for i, l in ipairs(view.lines) do
      ImGui.PushID(ctx, i)
      box(ctx, l.text, "mono")
      if ImGui.IsItemHovered(ctx) then ImGui.SetTooltip(ctx, l.full) end
      ImGui.PopID(ctx)
    end
  else
    box(ctx, "Nothing will change.", "faint")
  end
  error_box(ctx, d.error)
  local can = A.can_apply(plan) and not d.failed
  local hit = buttons(ctx, d.failed and { { "Close", true } } or { { "Cancel", false }, { "Do it", true, not can } })
  if hit == 1 then
    close(state)
  elseif hit == 2 then
    local ok, msg, fresh = A.do_it(state.env, args)
    if ok then
      close(state)
    elseif msg == A.CHANGED_MSG then
      args.plan, d.error = fresh, msg   -- show the new list; Do it confirms it
    else
      d.error, d.failed = msg, true
    end
  end
end

-- Clean up unused audio -------------------------------------------------------

M.CLEANUP_NOTE = "Only the song's media folders are checked (where its projects record and keep audio). "
  .. "A file is kept when any project or backup in the song's folder, or any other song in the list, uses it, "
  .. "and bounces are never offered. Plug-ins that save their settings compressed (some samplers) cannot be "
  .. "checked, so look down the list if one of them plays a file from this folder. "
  .. "The files go to the Trash, so they can be put back."

local function cleanup_body(ctx, state, args)
  local song = args.song
  heading(ctx, "Clean up: " .. (song.display_title or format.file_name(song.newest)))
  -- Until every folder is read, other songs' media are not all known.
  if details.library_partial(state) then
    box(ctx, details.WAIT_NOTE, "faint")
    if buttons(ctx, { { "Close", true } }) then close(state) end
    return
  end
  -- A fresh check when the dialog opens (the details' tile can be older).
  if d.result == nil and d.error == nil then
    local res, err = cleanup.scan(song, details.cleanup_ctx(state))
    d.result, d.error = res, (not res) and err or nil
    d.failed = not res
  end
  local res = d.result
  if res then
    local n = #res.files
    if n == 0 then
      box(ctx, "No unused audio in this song's media folders.", "faint")
    else
      box(ctx, format.count(n, "file") .. " (" .. format.size(res.total)
        .. ") will move to the Trash.")
      section(ctx, "Unused audio")
      local _, lh = draw.measure(ctx, "mono", theme.sizes.mono, "A")
      local rows_h = math.min(260, n * (lh + 6) + 8)
      if ImGui.BeginChild(ctx, "##cleanup_files", avail_w(ctx), rows_h, ImGui.ChildFlags_None) then
        local cdl = ImGui.GetWindowDrawList(ctx)
        for i, c in ipairs(res.files) do
          local cx, cy = ImGui.GetCursorScreenPos(ctx)
          local cw = avail_w(ctx)
          local size = format.size(c.size)
          local sw = draw.measure(ctx, "mono", theme.sizes.mono, size)
          draw.text_fit(ctx, cdl, "mono", theme.sizes.mono, cx + 4, cy + 3, theme.colors.cell,
            cleanup.relative(res, c.path), cw - sw - 24)
          draw.text(cdl, "mono", theme.sizes.mono, cx + cw - sw - 4, cy + 3, theme.colors.mono, size)
          ImGui.PushID(ctx, i)
          ImGui.Dummy(ctx, cw, lh + 6)
          if ImGui.IsItemHovered(ctx) then ImGui.SetTooltip(ctx, c.path) end
          ImGui.PopID(ctx)
        end
        ImGui.EndChild(ctx)
      end
    end
    box(ctx, M.CLEANUP_NOTE, "faint")
  end
  error_box(ctx, d.error)
  local can = res and #res.files > 0 and not d.failed
  local hit = buttons(ctx, (not can) and { { "Close", true } } or { { "Cancel", false }, { "Move to Trash", true } })
  if hit == 1 then
    close(state)
  elseif hit == 2 then
    local fresh, err = cleanup.scan(song, details.cleanup_ctx(state))
    if not fresh then
      d.error, d.failed = err, true
    elseif not cleanup.same(fresh, res) then
      d.result, d.error = fresh, A.CHANGED_MSG:gsub("Do it", "Move to Trash")
    else
      local ok, msg = cleanup.apply(fresh, state.P, state.env and state.env.is_open)
      if ok then
        state.notice = "Moved " .. format.count(#fresh.files, "file") .. " (" .. format.size(fresh.total)
          .. ") to the Trash."
        if details.reset then details.reset() end
        close(state)
      else
        d.error, d.failed = msg, true
      end
    end
  end
end

-- Rename and move ------------------------------------------------------------

local function song_base(song)
  local name = format.file_name(song.newest):gsub("%.[Rr][Pp][Pp]$", "")
  return (name:gsub("_%d%d%d+$", ""))
end

local function rename_body(ctx, state, args)
  local song = args.song
  if d.name == nil then d.name = song_base(song) end
  heading(ctx, "Rename " .. song_base(song))
  box(ctx, "Every version file gets the new name, and so does the song's folder when it has the song's name. "
    .. "The next step lists every change.", "faint")
  if ImGui.IsWindowAppearing(ctx) then ImGui.SetKeyboardFocusHere(ctx) end
  local _, v = field(ctx, "##rename", "New name", d.name, 0)
  d.name = v
  local hit = buttons(ctx, { { "Cancel", false }, { "Continue…", true } })
  if hit == 1 then close(state)
  elseif hit == 2 then
    local name = d.name:gsub("^%s+", ""):gsub("%s+$", "")
    M.confirm(state, song, A.plan(state.env, "rename", song, name), "Rename", name)
  end
end

local function move_body(ctx, state, args)
  local song = args.song
  if d.folder == nil then d.folder = "" end
  heading(ctx, "Move " .. (song.display_title or song_base(song)))
  box(ctx, "Type the folder to move the song into, or press Choose… to browse for it. "
    .. "The next step lists every change.", "faint")
  d.folder = folder_field(ctx, state, "##movefolder", d.folder)
  error_box(ctx, d.error)
  local hit = buttons(ctx, { { "Cancel", false }, { "Continue…", true } })
  if hit == 1 then close(state)
  elseif hit == 2 then
    local f = d.folder:gsub("^%s+", ""):gsub("%s+$", "")
    if not A.folder_exists(state.env.P, f) then
      d.error = f == "" and "Type or choose a folder." or ("That folder does not exist: " .. f)
    else
      local dest = f:gsub("([^/\\])[/\\]+$", "%1")
      M.confirm(state, song, A.plan(state.env, "move", song, dest), "Move", dest)
    end
  end
end

-- Edit notes, title and author ----------------------------------------------

local function save_fields(state, song, fields)
  local ok, msg = A.save_fields(state.env, song, fields)
  if ok then close(state) else d.error = msg end
end

local function notes_body(ctx, state, args)
  local song = args.song
  local info = song.info or {}
  if d.notes == nil then d.notes = info.notes or "" end
  heading(ctx, "Notes: " .. (song.display_title or song_base(song)))
  box(ctx, "Saved into the project's Project Notes (" .. format.file_name(song.newest)
    .. "). A backup is made first.", "faint")
  if ImGui.IsWindowAppearing(ctx) then ImGui.SetKeyboardFocusHere(ctx) end
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_FrameBorderSize, 1)
  ImGui.PushStyleColor(ctx, ImGui.Col_Border, theme.colors.control_border)
  ImGui.PushStyleColor(ctx, ImGui.Col_FrameBg, theme.colors.tile)
  local _, v = ImGui.InputTextMultiline(ctx, "##notes", d.notes, avail_w(ctx), 220)
  ImGui.PopStyleColor(ctx, 2)
  ImGui.PopStyleVar(ctx)
  d.notes = v
  error_box(ctx, d.error)
  local hit = buttons(ctx, { { "Cancel", false }, { "Save", true } })
  if hit == 1 then close(state)
  elseif hit == 2 then save_fields(state, song, { notes = d.notes }) end
end

local function fields_body(ctx, state, args)
  local song = args.song
  local info = song.info or {}
  if d.title == nil then d.title, d.author = info.title or "", info.author or "" end
  heading(ctx, "Title and author: " .. song_base(song))
  box(ctx, "Saved into the project's Project Settings (" .. format.file_name(song.newest)
    .. "). A backup is made first.", "faint")
  section(ctx, "Title")
  if ImGui.IsWindowAppearing(ctx) then ImGui.SetKeyboardFocusHere(ctx) end
  local _, t = field(ctx, "##title", song_base(song), d.title, 0)
  d.title = t
  section(ctx, "Author")
  local _, a = field(ctx, "##author", "Artist", d.author, 0)
  d.author = a
  error_box(ctx, d.error)
  local hit = buttons(ctx, { { "Cancel", false }, { "Save", true } })
  if hit == 1 then close(state)
  elseif hit == 2 then save_fields(state, song, { title = d.title, author = d.author }) end
end

-- New from template ------------------------------------------------------------

local function template_name(path)
  return (format.file_name(path):gsub("%.[^%.]*$", ""))
end

local function new_body(ctx, state)
  local list = (state.templates and state.templates.project) or {}
  if d.template == nil then d.template = state.template_path or list[1] or false end
  if d.name == nil then d.name = "" end
  if d.folder == nil then d.folder = (state.data.scan_folders or {})[1] or "" end
  heading(ctx, "New from template")
  if #list == 0 then
    box(ctx, "No project templates in REAPER's ProjectTemplates folder.", "faint")
    error_box(ctx, d.error)
    local hit = buttons(ctx, { { "Cancel", false }, { "Empty project", true } })
    if hit == 1 then close(state)
    elseif hit == 2 then
      local ok, msg = A.new_project(state.env, { empty = true })
      if ok then close(state) else d.error = msg end
    end
    return
  end
  section(ctx, "Template")
  local row_h = ImGui.GetTextLineHeightWithSpacing(ctx) + 4
  local h = math.min(#list, 6) * row_h + 12
  ImGui.PushStyleColor(ctx, ImGui.Col_ChildBg, theme.colors.tile)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_WindowPadding, 6, 6)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_ChildRounding, 9)
  local visible = ImGui.BeginChild(ctx, "##templates", avail_w(ctx), h, ImGui.ChildFlags_AlwaysUseWindowPadding)
  ImGui.PopStyleVar(ctx, 2)
  ImGui.PopStyleColor(ctx)
  if visible then
    for i, p in ipairs(list) do
      if ImGui.Selectable(ctx, template_name(p) .. "##t" .. i, d.template == p) then d.template = p end
      if ImGui.IsItemHovered(ctx) then ImGui.SetTooltip(ctx, p) end
    end
    ImGui.EndChild(ctx)
  end
  section(ctx, "Song name")
  if ImGui.IsWindowAppearing(ctx) then ImGui.SetKeyboardFocusHere(ctx) end
  local _, n = field(ctx, "##newname", "Song name", d.name, 0)
  d.name = n
  section(ctx, "Folder")
  d.folder = folder_field(ctx, state, "##newfolder", d.folder)
  local name = d.name:gsub("^%s+", ""):gsub("%s+$", "")
  local folder = d.folder:gsub("^%s+", ""):gsub("%s+$", "")
  if name ~= "" and folder ~= "" and state.P then
    local dir = state.P.join(folder, name)
    box(ctx, "Makes " .. state.P.join(dir, name .. ".RPP") .. " from " .. template_name(d.template)
      .. " and opens it.", "faint")
  end
  error_box(ctx, d.error)
  local hit = buttons(ctx, { { "Cancel", false }, { "Create and open", true, name == "" or not d.template } })
  if hit == 1 then close(state)
  elseif hit == 2 then
    local ok, msg = A.new_project(state.env, { template = d.template, name = d.name, folder = d.folder })
    if ok then close(state) else d.error = msg end
  end
end

-- Settings and first run --------------------------------------------------------

-- Folder list with Remove on each and an add row. which: "scan_folders" | "excludes".
local function folder_list(ctx, state, which)
  local env = state.env
  local list = state.data[which] or {}
  d.add = d.add or {}
  d.ferr = d.ferr or {}
  ImGui.PushID(ctx, which)
  local remove_at
  local rw = button_w(ctx, "Remove")
  for i, f in ipairs(list) do
    ImGui.PushID(ctx, i)
    local x, y = ImGui.GetCursorScreenPos(ctx)
    local w = avail_w(ctx) - rw - 8
    local _, lh = draw.measure(ctx, "ui_bold", theme.sizes.button, "A")
    local bh = lh + 14   -- the height of the Remove button next to it
    local dl = ImGui.GetWindowDrawList(ctx)
    draw.tile(dl, x, y, w, bh, 8)
    local _, th = draw.measure(ctx, "mono", theme.sizes.mono, "A")
    draw.text_fit(ctx, dl, "mono", theme.sizes.mono, x + 10, y + (bh - th) / 2, theme.colors.cell, f, w - 20)
    ImGui.Dummy(ctx, w, bh)
    if ImGui.IsItemHovered(ctx) then ImGui.SetTooltip(ctx, f) end
    ImGui.SameLine(ctx, 0, 8)
    if button(ctx, "Remove", false) then remove_at = i end
    ImGui.PopID(ctx)
  end
  if #list == 0 then
    local none = { scan_folders = "No scan folders yet.", excludes = "No excluded folders.",
      bounce_folders = "No bounce folders. Bounces are found in each project's render folder." }
    box(ctx, none[which], "faint")
  end
  local v, add = folder_field(ctx, state, "##add_" .. which, d.add[which] or "", "Add")
  d.add[which] = v
  if add then
    local ok, err = A.folder_add(env, which, v)
    if ok then d.add[which], d.ferr[which] = "", nil else d.ferr[which] = err end
  end
  if remove_at then A.folder_remove(env, which, remove_at); d.ferr[which] = nil end
  error_box(ctx, d.ferr[which])
  ImGui.PopID(ctx)
end

local function statuses(ctx, state)
  local env, data = state.env, state.data
  d.sbuf = d.sbuf or {}
  local list = data.statuses
  local arrow_w = ImGui.GetFrameHeight(ctx)
  local rw = button_w(ctx, "Remove")
  local rename, action
  for i, name in ipairs(list) do
    ImGui.PushID(ctx, "status" .. i)
    local x, y = ImGui.GetCursorScreenPos(ctx)
    local fh = ImGui.GetFrameHeight(ctx)
    ImGui.DrawList_AddCircleFilled(ImGui.GetWindowDrawList(ctx), x + 6, y + fh / 2, 4,
      theme.status_color(name, list, data.status_builtin))
    ImGui.SetCursorScreenPos(ctx, x + 18, y)
    local _, v = field(ctx, "##name", name, d.sbuf[i] or name, 2 * (arrow_w + 6) + rw + 8)
    d.sbuf[i] = v
    if ImGui.IsItemDeactivatedAfterEdit(ctx) then rename = { name, v } end
    ImGui.SameLine(ctx, 0, 6)
    ImGui.BeginDisabled(ctx, i == 1)
    if ImGui.ArrowButton(ctx, "##up", ImGui.Dir_Up) then action = { "move", i, -1 } end
    ImGui.EndDisabled(ctx)
    ImGui.SameLine(ctx, 0, 6)
    ImGui.BeginDisabled(ctx, i == #list)
    if ImGui.ArrowButton(ctx, "##down", ImGui.Dir_Down) then action = { "move", i, 1 } end
    ImGui.EndDisabled(ctx)
    ImGui.SameLine(ctx, 0, 8)
    if button(ctx, "Remove", false) then action = { "ask_remove", name } end
    ImGui.PopID(ctx)
  end
  if d.remove then
    local n = A.status_users(data, d.remove)
    box(ctx, 'Remove the status "' .. d.remove .. '"? ' .. (n == 0 and "No songs have it."
      or (format.count(n, "song") .. " have it; their status is cleared.")), "warn")
    local hit = buttons(ctx, { { "Keep it", false }, { "Remove", true } })
    if hit == 1 then d.remove = nil
    elseif hit == 2 then A.status_remove(env, d.remove); d.remove = nil; d.sbuf = {} end
  end
  local _, v = field(ctx, "##newstatus", "New status", d.new_status or "", button_w(ctx, "Add") + 8)
  d.new_status = v
  ImGui.SameLine(ctx, 0, 8)
  if button(ctx, "Add", false) then action = { "add", v } end
  if rename or action then
    local ok, err, ask = A.status_commit(env, rename, action)
    if ask then d.remove = ask end
    if action and action[1] == "add" and ok then d.new_status = "" end
    d.serr = (not ok) and err or nil
    d.sbuf = {}
  end
  error_box(ctx, d.serr)
end

local function checkbox(ctx, label, value)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_FramePadding, 1, 1)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_FrameRounding, 3)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_FrameBorderSize, 1)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_ItemInnerSpacing, 6, 4)
  ImGui.PushStyleColor(ctx, ImGui.Col_Border, theme.colors.checkbox_border)
  local changed, v = ImGui.Checkbox(ctx, label, value and true or false)
  ImGui.PopStyleColor(ctx)
  ImGui.PopStyleVar(ctx, 4)
  return changed, v
end

local function settings_body(ctx, state)
  heading(ctx, "Settings")
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_WindowPadding, 0, 0)
  local visible = ImGui.BeginChild(ctx, "##settings_scroll", avail_w(ctx), 470, ImGui.ChildFlags_None)
  ImGui.PopStyleVar(ctx)
  if visible then
    ImGui.PushItemWidth(ctx, -1)
    section(ctx, "Scan folders")
    box(ctx, A.SCAN_NOTE, "faint")
    folder_list(ctx, state, "scan_folders")
    section(ctx, "Excluded folders")
    folder_list(ctx, state, "excludes")
    section(ctx, "Bounce folders")
    folder_list(ctx, state, "bounce_folders")
    box(ctx, A.CHOOSE_NOTE, "faint")
    section(ctx, "Statuses")
    statuses(ctx, state)
    section(ctx, "Glass")
    local pct = math.floor((state.opacity or theme.OPACITY) * 100 + 0.5)
    ImGui.SetNextItemWidth(ctx, avail_w(ctx))
    local ch, v = ImGui.SliderInt(ctx, "##opacity", pct, 80, 100, "Opacity %d %%")
    if ch then A.opacity(state.env, v) end
    section(ctx, "Startup")
    local sch, on = checkbox(ctx, "Run ReaLobby when REAPER starts", state.startup_on)
    if sch then
      local ok, err = A.set_startup(state.env, on)
      d.start_err = (not ok) and err or nil
    end
    error_box(ctx, d.start_err)
    section(ctx, "Time worked")
    local tch, ton = checkbox(ctx, "Count time worked on each song", state.data.count_time ~= false)
    if tch then A.set_count_time(state.env, ton) end
    box(ctx, A.TIME_NOTE, "faint")
    ImGui.PopItemWidth(ctx)
    ImGui.EndChild(ctx)
  end
  if buttons(ctx, { { "Close", true } }) then close(state) end
end

local function first_run_body(ctx, state)
  if d.startup == nil then d.startup = true end
  heading(ctx, "Welcome to BLV ReaLobby")
  box(ctx, A.SCAN_NOTE .. " You can change this later in Settings.", "faint")
  section(ctx, "Scan folders")
  folder_list(ctx, state, "scan_folders")
  box(ctx, A.CHOOSE_NOTE, "faint")
  section(ctx, "Startup")
  local ch, on = checkbox(ctx, "Run ReaLobby when REAPER starts", d.startup)
  if ch then d.startup = on end
  if state.reaper_prompt then box(ctx, A.PROMPT_NOTE) end
  error_box(ctx, d.error)
  if buttons(ctx, { { "Done", true } }) then
    local ok, err = A.finish_first_run(state.env, d.startup)
    if ok then close(state) else d.error = err end
  end
end

local BODIES = {
  confirm = confirm_body, rename = rename_body, move = move_body, edit_notes = notes_body,
  edit_fields = fields_body, new_from_template = new_body, settings = settings_body, first_run = first_run_body,
  cleanup = cleanup_body,
}

-- Drawing -----------------------------------------------------------------------

-- Called inside the main window (after its Esc check), so the popup shares
-- its ID stack.
function M.draw(ctx, state)
  ImGui = theme.ImGui
  frame_ctx = ctx
  count_deadline = (state.clock or os.clock)() + COUNT_BUDGET
  counted = false
  local name = state.dialog
  if not name then
    cur = {}
    return
  end
  local body = BODIES[name]
  if not body then
    state.dialog, state.dialog_args = nil, nil
    return
  end
  if cur.name ~= name or cur.args ~= state.dialog_args then
    cur = { name = name, args = state.dialog_args }
    d = {}
  end
  if not ImGui.IsPopupOpen(ctx, POPUP) then ImGui.OpenPopup(ctx, POPUP) end

  local wx, wy = ImGui.GetWindowPos(ctx)
  local ww, wh = ImGui.GetWindowSize(ctx)
  local w = WIDTH[name] or DEFAULT_W
  ImGui.SetNextWindowPos(ctx, wx + ww / 2, wy + wh / 2, ImGui.Cond_Always, 0.5, 0.5)
  ImGui.SetNextWindowSizeConstraints(ctx, w, 0, w, math.max(200, wh - 40))
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_WindowPadding, 22, 20)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_PopupBorderSize, 1)
  ImGui.PushStyleColor(ctx, ImGui.Col_Border, theme.colors.border)
  local flags = ImGui.WindowFlags_NoTitleBar | ImGui.WindowFlags_AlwaysAutoResize | ImGui.WindowFlags_NoMove
    | ImGui.WindowFlags_NoSavedSettings
  local visible = ImGui.BeginPopupModal(ctx, POPUP, nil, flags)
  ImGui.PopStyleColor(ctx)
  ImGui.PopStyleVar(ctx, 2)
  if visible then
    if ImGui.IsKeyPressed(ctx, ImGui.Key_Escape, false) then
      close(state)
    else
      body(ctx, state, state.dialog_args or {})
    end
    ImGui.EndPopup(ctx)
  end
end

-- The right-click song menu ---------------------------------------------------

-- Drawn between BeginPopup and EndPopup by the table.
function M.row_menu(ctx, state, song)
  ImGui = theme.ImGui
  local env, data = state.env, state.data
  -- The footer's FX choices apply; the current tab stays open.
  if ImGui.MenuItem(ctx, "Open in new tab") and state.open then state.open(song, { new_tab = true }) end
  ImGui.Separator(ctx)
  if ImGui.MenuItem(ctx, song.pinned and "Unpin" or "Pin") then A.toggle_pin(env, song) end
  if ImGui.BeginMenu(ctx, "Status") then
    local dl = ImGui.GetWindowDrawList(ctx)
    local function item(label, value, color)
      if ImGui.MenuItem(ctx, "      " .. label, nil, song.status == value) then A.set_status(env, song, value) end
      local x, y = ImGui.GetItemRectMin(ctx)
      local _, h = ImGui.GetItemRectSize(ctx)
      ImGui.DrawList_AddCircleFilled(dl, x + 8, y + h / 2, 4, color)
    end
    for _, s in ipairs(data.statuses or {}) do
      item(s, s, theme.status_color(s, data.statuses, data.status_builtin))
    end
    item("None", nil, theme.colors.sub)
    ImGui.EndMenu(ctx)
  end
  ImGui.Separator(ctx)
  if ImGui.MenuItem(ctx, "Edit notes…") then M.edit_fields(state, song, "notes") end
  if ImGui.MenuItem(ctx, "Edit title and author…") then M.edit_fields(state, song, "fields") end
  ImGui.Separator(ctx)
  if ImGui.MenuItem(ctx, "Rename…") then open(state, "rename", { song = song }) end
  if ImGui.MenuItem(ctx, "Move…") then open(state, "move", { song = song }) end
  if ImGui.MenuItem(ctx, "Archive") then M.confirm(state, song, A.plan(env, "archive", song), "Archive") end
  if ImGui.MenuItem(ctx, "Move to Trash…") then
    M.confirm(state, song, A.plan(env, "delete", song), "Move to Trash")
  end
  if ImGui.MenuItem(ctx, "Clean up unused audio…") then M.cleanup(state, song) end
  ImGui.Separator(ctx)
  if ImGui.MenuItem(ctx, song.hidden and "Unhide" or "Hide") then A.set_hidden(env, song, not song.hidden) end
  if ImGui.MenuItem(ctx, "Open folder") and state.P and song.newest then state.P.open_folder(song.newest) end
  if ImGui.MenuItem(ctx, "Show in " .. (state.file_manager or "the file manager")) and state.P then
    state.P.reveal(song.newest)
  end
end

return M
