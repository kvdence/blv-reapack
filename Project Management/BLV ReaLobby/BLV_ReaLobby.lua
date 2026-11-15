-- @description BLV ReaLobby
-- @author BLV
-- @version 0.1.1
-- @about A project launcher for REAPER. Requires REAPER 7.74 or newer and ReaImGui.
--   Copyright (c) 2026 BLV. All rights reserved. Free to use. You may not copy, modify, repackage or redistribute this software.
-- @provides
--   [nomain] BLV_ReaLobby_Timer.lua
--   [nomain] realobby/*.lua
--   [nomain] realobby/ui/*.lua
--   [nomain] realobby/assets/grain.png
--
-- Entry script: loads ReaImGui and the modules, then runs the window with
-- reaper.defer. The startup hook runs this file with dofile, so the script's
-- own folder comes from debug.getinfo (controller ruling R20), not
-- get_action_context.
local source = debug.getinfo(1, "S").source:gsub("^@", "")
local here = source:match("^(.*)[/\\][^/\\]*$") or "."
package.path = here .. "/?.lua;" .. package.path

local IMGUI_API = "0.10"   -- ReaImGui 0.10.x (checked against 0.10.0.5)
local SAVE_EVERY = 1.0     -- seconds between saves while settings change

local function fail(msg)
  reaper.MB(msg, "BLV ReaLobby", 0)
end

-- ReaImGui's API shim (imgui.lua). ImGui_GetBuiltinPath names the folder
-- ReaPack installs it to (Scripts/ReaTeam Extensions/API).
local function load_imgui()
  if not reaper.ImGui_GetBuiltinPath then return nil, "ReaImGui is not installed" end
  local paths = {
    reaper.ImGui_GetBuiltinPath() .. "/imgui.lua",
    reaper.GetResourcePath() .. "/Scripts/ReaTeam Extensions/API/imgui.lua",
  }
  local why = "imgui.lua not found"
  for _, path in ipairs(paths) do
    if reaper.file_exists(path) then
      local ok, ImGui = pcall(function() return dofile(path)(IMGUI_API) end)
      if ok then return ImGui end
      why = tostring(ImGui)
    end
  end
  return nil, why
end

local ImGui, imgui_err = load_imgui()
if not ImGui then
  return fail("BLV ReaLobby needs ReaImGui " .. IMGUI_API .. " or newer (" .. tostring(imgui_err) .. ").\n"
    .. "Install it with ReaPack (Extensions > ReaPack > Browse packages > ReaImGui), then restart REAPER.")
end

-- The work area of the screen REAPER's main window is on, as two corners in
-- ImGui coordinates (realobby/placement.lua sorts them). Nil when this REAPER
-- or ReaImGui lacks the calls; the window then centres on REAPER's window.
local function screen_area(ctx)
  if not (reaper.my_getViewport and ImGui.PointConvertNative) then return nil end
  local vx, vy = ImGui.Viewport_GetCenter(ImGui.GetMainViewport(ctx))
  local nx, ny = ImGui.PointConvertNative(ctx, vx, vy, true)
  local l, t, r, b = reaper.my_getViewport(0, 0, 0, 0, nx, ny, nx, ny, true)
  if not (l and t and r and b) then return nil end
  local x1, y1 = ImGui.PointConvertNative(ctx, l, t, false)
  local x2, y2 = ImGui.PointConvertNative(ctx, r, b, false)
  return x1, y1, x2, y2
end

-- One window per REAPER: a second start brings the running one forward.
local instance = require("realobby.instance")
local B = require("realobby.bridge")
local single = instance.new({ get = reaper.GetExtState, set = reaper.SetExtState, now = reaper.time_precise })
-- Run again from the action list while this window is open (it was started
-- as that action): REAPER closes it and starts it afresh, centred, instead of
-- asking what to do with the running script.
local as_action = B.run_as_action(source) and reaper.set_action_options ~= nil
if as_action then reaper.set_action_options(1 | 2) end
if not single:claim() then return end
-- Lists ReaLobby in REAPER's action list, once (a copy installed by hand).
pcall(B.ensure_action, source)

local store = require("realobby.store")
local saver = require("realobby.saver")
local library = require("realobby.library")
local rpp = require("realobby.rpp")
local theme = require("realobby.ui.theme")
local shell = require("realobby.ui.shell")
local rows = require("realobby.ui.rows")
local format = require("realobby.ui.format")
local sidebar = require("realobby.ui.sidebar")
local table_ui = require("realobby.ui.table")
local details = require("realobby.ui.details")
local dialogs = require("realobby.ui.dialogs")
local actions = require("realobby.ui.actions")
local open_options = require("realobby.open_options")
local online = require("realobby.online")
local timelog = require("realobby.timelog")

local P = B.platform()
local data_dir = P.join(P.join(reaper.GetResourcePath(), "Data"), "BLV ReaLobby")
local data_path = P.join(data_dir, "realobby.dat")
local data = store.load(data_path)
local time_path = P.join(data_dir, "time.dat")
local timer_path = P.join(here, "BLV_ReaLobby_Timer.lua")

-- Time worked, keyed by normalize(song key) (realobby/timelog.lua).
local function load_time(L)
  local raw, map = timelog.load(time_path), {}
  for k, v in pairs(raw) do map[B.normalize(k)] = (map[B.normalize(k)] or 0) + v end
  L:set_time(map)
end

local recent = B.recent()
local L = library.new({ P = P, recent = recent, normalize = B.normalize, data = data, read = rpp.read, budget = 8,
  clock = reaper.time_precise })
L:set_installed_fx(B.installed_fx())
load_time(L)

local fx_offline_supported = B.fx_offline_supported()
local sort_column = rows.SORT_COLUMNS[data.sort.column] and data.sort.column or "opened"

local state = {
  query = "",
  view = { group = "recent" },
  selected_key = nil,
  sort = { column = sort_column, descending = data.sort.descending == true },
  opacity = data.opacity,
  dialog = nil,
  -- The footer's opening choices. data.fx_offline is 0.1.0's name for the first.
  fx_offline = data.fx_offline_default == true or (data.fx_offline_default == nil and data.fx_offline == true),
  online_after = data.fx_online_after == true,
  new_tab = data.open_new_tab == true,
  ignore_default = data.ignore_default == true,
  online_note = nil,      -- "Bringing FX online: n of m" while a pass runs
  online_warning = nil,   -- the last pass never finished (shown over the song list)
  -- Not saved: for the panes (Tasks 12-13).
  library = L,
  data = data,
  data_changed = false,   -- a pane sets this after changing data
  P = P,
  clock = reaper.time_precise,   -- the details' settle delay
  templates = B.templates(),
  fx_offline_supported = fx_offline_supported,
  backup_dir = B.backup_dir(),
  file_manager = ({ mac = "Finder", win = "Explorer" })[B.os()] or "the file manager",
  scanning = true,        -- until L:step() has read every folder
  no_sources = #(data.scan_folders or {}) == 0 and #recent == 0,
  notice = nil,           -- a short message under the details (open errors)
  scroll_to_selected = false,
  template_path = nil,    -- the template chosen for "new_from_template"
  -- Ruling R25: set after anything opened a project (an open here; new from
  -- template or new empty in Task 13's dialogs). The window then saves and
  -- closes. On a failure it stays open and shows the error.
  close_requested = false,
  dialog_args = nil,      -- what the open dialog is about (dialogs.lua)
  menu_song = nil,        -- the song whose right-click menu is open
  startup_on = B.startup_installed(),
  reaper_prompt = data.first_run_done ~= true and B.reaper_prompt_on(),
  recenter = true,        -- the shell centres the window on the screen
  placement = nil,        -- where the shell centred it (realobby/placement.lua)
  screen_area = screen_area,
}

-- What the menu and dialogs work with (realobby/ui/actions.lua).
-- Changes check REAPER's tabs afresh, and a folder counts as open when it
-- holds an open project.
state.env = {
  P = P, is_open = actions.open_checker(B.open_projects, B.normalize), library = L, data = data, state = state, B = B,
  now = os.time, entry_path = source, recent = recent, reset_details = details.reset,
  -- A renamed or moved song keeps its time worked.
  move_time = function(from, to)
    timelog.move(time_path, B.normalize(from), B.normalize(to))
    load_time(L)
  end,
  start_timer = function() return B.start_timer(timer_path) end,
  stop_timer = B.stop_timer,
}

-- The unused-audio clean-up for a song (the details' tile, the song menu).
function state.cleanup(song) dialogs.cleanup(state, song) end

-- The first run: shown until its Done is pressed (data.first_run_done).
if data.first_run_done ~= true then dialogs.first_run(state) end

-- A "Bring FX online after load" pass that never finished (REAPER stopped the
-- script) may have left plug-ins offline: say so once.
if online.interrupted(B.online_progress_get(), reaper.time_precise()) then
  state.online_warning = online.INTERRUPTED_NOTE
  B.online_progress_set("")
end

-- Opening ---------------------------------------------------------------------

-- Opens run after the frame is drawn: REAPER may ask to save the current
-- project first, and that prompt should not interrupt a frame.
local pending_open = nil

-- override (realobby/open_options.lua) changes the footer's choices for this
-- open: { fx_offline = true } for Open safely, { new_tab = true } for Open in
-- new tab; nil keeps them. path opens another file of the song (a backup or
-- an older version) instead of its newest version; the song's opened time is
-- recorded the same way.
function state.open(song, override, path)
  local opts = open_options.resolve(state, override, fx_offline_supported)
  if open_options.offline_open(opts) and not fx_offline_supported then
    state.notice = details.FX_OFFLINE_NOTE
    return
  end
  pending_open = { song = song, opts = opts, path = path }
end

-- "Bring FX online after load": runs after the window closed (ruling R25),
-- one time budget per defer frame, until every FX saved online is online.
local online_pass = nil

local function run_open()
  local song, opts, path = pending_open.song, pending_open.opts, pending_open.path
  pending_open = nil
  local file = path or song.newest
  -- Which FX the file saved offline, read before the open: right after an
  -- FX-offline open REAPER reports every FX offline. A file that cannot be
  -- read opens normally, so the FX saved offline stay offline.
  local chains = opts.online_after and rpp.read_fx_chains(file)
  if opts.online_after and not chains then opts.online_after = false end
  local ok, res, how = B.open(file, opts)
  if not ok then
    state.notice = format.open_error(res)
    return
  end
  -- Already open in a tab: REAPER switched to it, nothing was loaded.
  if opts.online_after and how ~= "switched" then
    online_pass = B.fx_online_pass(res, chains)
  end
  -- Ruling R1: opening through ReaLobby records the time.
  data.songs[song.key] = data.songs[song.key] or {}
  data.songs[song.key].opened = os.time()
  L:touch()
  state.data_changed = true
  state.notice = nil
  state.close_requested = true
end

-- A project template starts the "new from template" dialog.
function state.use_template(row, kind)
  if kind ~= "project" then return end
  state.template_path = row.path
  dialogs.new_from_template(state)
end

-- Rows ------------------------------------------------------------------------

-- Rows are recomputed only when the songs table, query, view or sort changes.
local frame_rows = {}   -- the rows the panes draw this frame
local song_memo, template_memo = {}, {}
local last_query = state.query
local selected_memo = {}

local function template_rows()
  local kind = state.view.value == "track" and "track" or "project"
  if template_memo.kind ~= kind or template_memo.query ~= state.query then
    template_memo.kind, template_memo.query = kind, state.query
    template_memo.rows = rows.templates(state.templates[kind], state.query)
    return template_memo.rows, true
  end
  return template_memo.rows, false
end

local function current_rows()
  local list, changed
  if state.view.group == "templates" then
    list, changed = template_rows()
  else
    local src = state.view.group == "hidden" and L:songs({ include_hidden = true }) or L:songs()
    list, changed = rows.memo(song_memo, src, state.query, state.view, state.sort)
  end
  -- frame_rows is last frame's list: switching between the song and
  -- template lists can bring back a cached list that did not "change".
  if changed or list ~= frame_rows then
    -- A new query selects its best match; otherwise the selection stays
    -- while it is still listed.
    local query_changed = state.query ~= last_query
    last_query = state.query
    local key = rows.reselect(list, state.selected_key, query_changed)
    if key ~= state.selected_key then
      state.selected_key = key
      state.scroll_to_selected = true
    end
  end
  return list
end

-- The selected row, looked up once per change of rows or selection.
local function selected_row(list)
  if selected_memo.rows ~= list or selected_memo.key ~= state.selected_key then
    selected_memo.rows, selected_memo.key = list, state.selected_key
    local i = rows.index_of(list, state.selected_key)
    selected_memo.row = i and list[i] or nil
  end
  return selected_memo.row
end

shell.panes.sidebar = function(ctx, st, w, h)
  sidebar.draw(ctx, st, L:songs({ include_hidden = true }), data, w, h)
end
shell.panes.table = function(ctx, st, w, h)
  table_ui.draw(ctx, st, frame_rows, w, h)
end
shell.panes.details = function(ctx, st, w, h)
  details.draw(ctx, st, selected_row(frame_rows), w, h)
end
shell.panes.dialogs = dialogs.draw

-- Saving --------------------------------------------------------------------

local made_dir = false

-- A failed save stays unsaved: it is tried again each second and on close,
-- and logged once per run of failures.
local saver_ = saver.new({
  every = SAVE_EVERY,
  now = reaper.time_precise,
  save = function()
    if not made_dir then made_dir = P.mkdir(data_dir) ~= false end
    return store.save(data_path, data)
  end,
  log = function(err)
    reaper.ShowConsoleMsg("BLV ReaLobby: could not save " .. data_path .. ": " .. err .. "\n")
  end,
})

-- Copies the saved parts of state into data; true when something changed.
local function sync()
  local changed = state.data_changed
  state.data_changed = false
  local function set(k, v)
    if data[k] ~= v then data[k] = v; changed = true end
  end
  set("opacity", state.opacity)
  set("fx_offline_default", state.fx_offline)
  set("fx_online_after", state.online_after)
  set("open_new_tab", state.new_tab)
  set("fx_offline", nil)   -- 0.1.0's name, replaced by fx_offline_default
  set("ignore_default", state.ignore_default)
  if data.sort.column ~= state.sort.column or data.sort.descending ~= state.sort.descending then
    data.sort = { column = state.sort.column, descending = state.sort.descending }
    changed = true
  end
  return changed
end

-- Preview ---------------------------------------------------------------------

-- tools/realobby/preview.sh can open one dialog once the library is read, for
-- a screenshot: BLV_REALOBBY_PREVIEW = { dialog = "settings" } or
-- { dialog = "confirm", song = "<end of a song key>", action = "rename", arg = "New name" }
-- (song also serves edit_notes, edit_fields, rename and move).
local preview = rawget(_G, "BLV_REALOBBY_PREVIEW")
local function run_preview()
  local p = preview
  preview = nil
  local song
  if p.song and p.song ~= "" then
    for _, s in ipairs(L:songs({ include_hidden = true })) do
      if s.key:sub(-#p.song) == p.song then song = s end
    end
    if not song then return end
    state.view = { group = "all" }   -- so a song outside Recent stays selected
    state.selected_key = song.key
  end
  if p.dialog == nil or p.dialog == "" then return end
  if p.dialog == "confirm" then
    local titles = { rename = "Rename", move = "Move", archive = "Archive", delete = "Move to Trash" }
    dialogs.confirm(state, song, actions.plan(state.env, p.action, song, p.arg), titles[p.action], p.arg)
  elseif p.dialog then
    state.dialog, state.dialog_args = p.dialog, { song = song }
    -- settings with an arg: the scan-folder browser, opened at that folder
    if p.dialog == "settings" and (p.arg or "") ~= "" then
      state.browse_start, state.preview_browse = p.arg, "##add_scan_folders"
    end
  end
end

-- Loop ----------------------------------------------------------------------

local ctx = ImGui.CreateContext("BLV ReaLobby")
theme.init(ImGui, ctx, P.join(P.join(P.join(here, "realobby"), "assets"), "grain.png"))

-- Saves whatever is still unsaved; runs when the window closes and when
-- REAPER stops the script (once).
local closed = false
local function close()
  if closed then return end
  closed = true
  if sync() then saver_:mark() end
  saver_:flush()
  single:release()
end

local window_open = true

-- One frame of the online pass. Its progress goes to REAPER's ExtState, so a
-- ReaLobby window (this one, or one started while the pass runs) shows it.
local function online_step()
  local done = online_pass:step(window_open and online.BUDGET or online.BUDGET_CLOSED)
  B.online_progress_set(done and "" or online.encode(online_pass.done, online_pass.total, reaper.time_precise()))
  if done then online_pass = nil end
end

local timer_checked = false

local function loop()
  if not timer_checked then
    -- The time counter runs in the background while REAPER is open.
    timer_checked = true
    if data.count_time ~= false then pcall(B.start_timer, timer_path) end
  end
  if window_open then
    state.scanning = not L:step()
    if preview and not state.scanning then run_preview() end
    frame_rows = current_rows()
    single:beat()
    if single:focus_requested() then
      state.recenter = true
      if ImGui.SetNextWindowFocus then ImGui.SetNextWindowFocus(ctx) end
    end
    local d, n = online.decode(B.online_progress_get(), reaper.time_precise())
    state.online_note = d and online.note(d, n) or nil
    local open = shell.frame(ctx, state)
    if pending_open then run_open() end
    if state.close_requested then open = false end
    if sync() then saver_:mark() end
    saver_:tick()
    if not open then
      window_open = false
      close()
      -- FX still coming online: running the action again must not stop the
      -- pass, so REAPER asks again instead of restarting this copy.
      if as_action and online_pass then reaper.set_action_options(0) end
    end
  end
  if online_pass then online_step() end
  -- The window is gone but FX are still coming online: keep going, silently.
  if window_open or online_pass then reaper.defer(loop) end
end

-- REAPER stopping the script mid-pass (for example "Terminate instances" when
-- ReaLobby is run again) leaves FX offline: the next start says so.
reaper.atexit(function()
  close()
  if online_pass then B.online_progress_set(online.INTERRUPTED) end
end)
reaper.defer(loop)
