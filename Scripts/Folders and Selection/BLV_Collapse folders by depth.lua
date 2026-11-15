-- @description BLV Collapse folders by depth
-- @author BLV
-- @version 1.0.0
-- @about
--   A small window to expand, collapse or limit folder tracks by how deep they are nested; remembers the last choice per project.
--   Requires: ReaImGui (install from ReaPack).
--   Copyright (c) 2026 BLV. All rights reserved. Free to use. You may not copy, modify, repackage or redistribute this software.

-- USER EDITABLE SETTING:
-- Change this value if you want to allow a deeper maximum layer limit.
-- The options window offers "Show 2 folder levels" through this number.
local MAX_LAYER_DEPTH = 10

local EXT_SECTION = "CollapseUncollapseFolderTracksByDepth"
local WINDOW_TITLE = "Folder Track Collapse"
local WINDOW_W = 500
local WINDOW_H = 280

local COLLAPSED_FOLDERCOMPACT = 2
local UNCOLLAPSED_FOLDERCOMPACT = 0

local DEFAULT_PRESET_VALUE = "collapse_all"
local DEFAULT_HIDDEN_MODE = "include"
local DEFAULT_SUMMARY_MODE = "off"

local ok, ImGui = pcall(function()
  package.path = reaper.ImGui_GetBuiltinPath() .. "/?.lua;" .. package.path
  return require("imgui")("0.9")
end)

if not ok then
  reaper.MB(
    "This version of the script needs ReaImGui. Install or enable ReaImGui, then run it again.",
    WINDOW_TITLE,
    0
  )
  return
end

local ctx = ImGui.CreateContext(WINDOW_TITLE)

local HIDDEN_MODES = {
  { label = "Include hidden tracks", value = "include" },
  { label = "Ignore tracks hidden in TCP", value = "tcp" },
  { label = "Ignore tracks hidden in TCP or mixer", value = "tcp_or_mixer" }
}

local SUMMARY_MODES = {
  { label = "No summary", value = "off" },
  { label = "Show summary after apply", value = "on" }
}

local PRESETS = {}

local function add_preset(preset)
  PRESETS[#PRESETS + 1] = preset
end

add_preset({
  group = "Whole project",
  label = "Expand all folders",
  value = "expand_all",
  mode = "set",
  target = "project",
  compact = UNCOLLAPSED_FOLDERCOMPACT,
  description = "Opens every matching folder parent in the project."
})

add_preset({
  group = "Whole project",
  label = "Collapse all folders",
  value = "collapse_all",
  mode = "set",
  target = "project",
  compact = COLLAPSED_FOLDERCOMPACT,
  description = "Collapses every matching folder parent in the project."
})

for depth = 2, MAX_LAYER_DEPTH do
  add_preset({
    group = "Folder levels",
    label = "Show " .. tostring(depth) .. " folder levels",
    value = "show_" .. tostring(depth) .. "_levels",
    mode = "show_depth",
    target = "project",
    visible_depth = depth,
    description = "Opens folders above level " .. tostring(depth)
        .. " and collapses level " .. tostring(depth) .. " and deeper."
  })
end

add_preset({
  group = "Selected folders",
  label = "Toggle selected folder tree",
  value = "toggle_selected_tree",
  mode = "smart",
  target = "selected_trees",
  description = "Uses selected folder tracks, or the nearest parent folder of selected child tracks."
})

add_preset({
  group = "Selected folders",
  label = "Collapse selected folder tree",
  value = "collapse_selected_tree",
  mode = "set",
  target = "selected_trees",
  compact = COLLAPSED_FOLDERCOMPACT,
  description = "Collapses selected folder trees, including nearest parent folders for selected child tracks."
})

add_preset({
  group = "Selected folders",
  label = "Expand selected folder tree",
  value = "expand_selected_tree",
  mode = "set",
  target = "selected_trees",
  compact = UNCOLLAPSED_FOLDERCOMPACT,
  description = "Opens selected folder trees, including nearest parent folders for selected child tracks."
})

add_preset({
  group = "Selected folders",
  label = "Collapse selected folder tracks only",
  value = "collapse_selected_folders_only",
  mode = "set",
  target = "selected_folders",
  compact = COLLAPSED_FOLDERCOMPACT,
  description = "Collapses selected folder tracks, or nearest parent folders for selected child tracks."
})

add_preset({
  group = "Selected folders",
  label = "Expand selected folder tracks only",
  value = "expand_selected_folders_only",
  mode = "set",
  target = "selected_folders",
  compact = UNCOLLAPSED_FOLDERCOMPACT,
  description = "Opens selected folder tracks, or nearest parent folders for selected child tracks."
})

local ui = {
  preset_index = 1,
  hidden_index = 1,
  summary_index = 1,
  closed = false,
  positioned = false,
  last_window_x = nil,
  last_window_y = nil,
  last_window_w = nil,
  last_window_h = nil,
  status = "",
  status_is_error = false
}

local function get_project_state(key, default_value)
  local _, value = reaper.GetProjExtState(0, EXT_SECTION, key)

  if value ~= nil and value ~= "" then
    return value
  end

  return default_value
end

local function set_project_state(key, value)
  reaper.SetProjExtState(0, EXT_SECTION, key, tostring(value or ""))
end

local function get_ext_number(key, default_value)
  local value = tonumber(reaper.GetExtState(EXT_SECTION, key))
  if value ~= nil then
    return value
  end

  return default_value
end

local function set_ext_number(key, value)
  if value ~= nil then
    reaper.SetExtState(EXT_SECTION, key, tostring(math.floor(value)), true)
  end
end

local function get_index_by_value(items, value, default_index)
  for index, item in ipairs(items) do
    if item.value == value then
      return index
    end
  end

  return default_index or 1
end

local function find_preset_by_value(value)
  for index, preset in ipairs(PRESETS) do
    if preset.value == value then
      return index
    end
  end

  return nil
end

local function set_selected_preset(value)
  ui.preset_index = find_preset_by_value(value)
      or find_preset_by_value(DEFAULT_PRESET_VALUE)
      or 1
end

local function get_selected_value(items, index)
  local item = items[index] or items[1]
  return item.value
end

local function get_hidden_mode()
  return get_selected_value(HIDDEN_MODES, ui.hidden_index)
end

local function get_summary_mode()
  return get_selected_value(SUMMARY_MODES, ui.summary_index)
end

local function load_state()
  set_selected_preset(get_project_state("preset_value", DEFAULT_PRESET_VALUE))
  ui.hidden_index = get_index_by_value(
    HIDDEN_MODES,
    get_project_state("hidden_mode", DEFAULT_HIDDEN_MODE),
    1
  )
  ui.summary_index = get_index_by_value(
    SUMMARY_MODES,
    get_project_state("summary_mode", DEFAULT_SUMMARY_MODE),
    1
  )
end

local function save_project_state()
  local preset = PRESETS[ui.preset_index] or PRESETS[1]

  set_project_state("preset_value", preset.value)
  set_project_state("hidden_mode", get_hidden_mode())
  set_project_state("summary_mode", get_summary_mode())
end

local function save_window_bounds()
  set_ext_number("window_x", ui.last_window_x)
  set_ext_number("window_y", ui.last_window_y)
  set_ext_number("window_w", ui.last_window_w)
  set_ext_number("window_h", ui.last_window_h)
end

local function close_window()
  if not ui.closed then
    save_window_bounds()
  end

  ui.closed = true
end

local function track_is_visible(track, hidden_mode)
  if hidden_mode == "include" then
    return true
  end

  local show_tcp = reaper.GetMediaTrackInfo_Value(track, "B_SHOWINTCP") ~= 0
  local show_mixer = reaper.GetMediaTrackInfo_Value(track, "B_SHOWINMIXER") ~= 0

  if hidden_mode == "tcp" then
    return show_tcp
  end

  return show_tcp and show_mixer
end

local function prune_folder_stack(stack, open_folder_depth)
  while #stack > 0 and stack[#stack].depth > open_folder_depth do
    stack[#stack] = nil
  end
end

local function add_selected_root(roots, root_map, track, folder_depth)
  if not track or root_map[track] then
    return
  end

  local root = {
    track = track,
    depth = folder_depth
  }

  root_map[track] = root
  roots[#roots + 1] = root
end

local function collect_selected_folder_roots()
  local project = 0
  local track_count = reaper.CountTracks(project)
  local open_folder_depth = 0
  local open_folders = {}
  local roots = {}
  local root_map = {}
  local selected_folder_count = 0
  local selected_child_count = 0

  for track_index = 0, track_count - 1 do
    prune_folder_stack(open_folders, open_folder_depth)

    local track = reaper.GetTrack(project, track_index)
    local folder_depth_delta = reaper.GetMediaTrackInfo_Value(track, "I_FOLDERDEPTH")
    local is_folder_parent = folder_depth_delta > 0
    local is_selected = reaper.GetMediaTrackInfo_Value(track, "I_SELECTED") ~= 0
    local folder_depth = open_folder_depth + 1

    if is_selected then
      if is_folder_parent then
        selected_folder_count = selected_folder_count + 1
        add_selected_root(roots, root_map, track, folder_depth)
      elseif #open_folders > 0 then
        selected_child_count = selected_child_count + 1
        local nearest_parent = open_folders[#open_folders]
        add_selected_root(roots, root_map, nearest_parent.track, nearest_parent.depth)
      end
    end

    if is_folder_parent then
      open_folders[#open_folders + 1] = {
        track = track,
        depth = folder_depth
      }
    end

    open_folder_depth = open_folder_depth + folder_depth_delta
    if open_folder_depth < 0 then
      open_folder_depth = 0
    end
  end

  return roots, root_map, selected_folder_count, selected_child_count
end

local function collect_folder_candidates(preset, hidden_mode)
  local project = 0
  local track_count = reaper.CountTracks(project)
  local open_folder_depth = 0
  local selected_root_stack = {}
  local candidates = {}
  local selected_roots = {}
  local selected_root_map = {}

  if preset.target ~= "project" then
    selected_roots, selected_root_map = collect_selected_folder_roots()
  end

  for track_index = 0, track_count - 1 do
    prune_folder_stack(selected_root_stack, open_folder_depth)

    local track = reaper.GetTrack(project, track_index)
    local folder_depth_delta = reaper.GetMediaTrackInfo_Value(track, "I_FOLDERDEPTH")
    local is_folder_parent = folder_depth_delta > 0

    if is_folder_parent then
      local folder_depth = open_folder_depth + 1
      local effective_depth = folder_depth
      local target_matches = false
      local is_selected_root = selected_root_map[track] ~= nil

      if preset.target == "project" then
        target_matches = true
      elseif preset.target == "selected_folders" then
        target_matches = is_selected_root
        effective_depth = 1
      elseif preset.target == "selected_trees" then
        if is_selected_root then
          target_matches = true
          effective_depth = 1
        elseif #selected_root_stack > 0 then
          target_matches = true
          effective_depth = folder_depth - selected_root_stack[#selected_root_stack].depth + 1
        end
      end

      if target_matches and track_is_visible(track, hidden_mode) then
        candidates[#candidates + 1] = {
          track = track,
          current_compact = reaper.GetMediaTrackInfo_Value(track, "I_FOLDERCOMPACT"),
          effective_depth = effective_depth
        }
      end

      if preset.target == "selected_trees" and is_selected_root then
        selected_root_stack[#selected_root_stack + 1] = {
          track = track,
          depth = folder_depth
        }
      end
    end

    open_folder_depth = open_folder_depth + folder_depth_delta
    if open_folder_depth < 0 then
      open_folder_depth = 0
    end
  end

  return candidates, #selected_roots
end

local function choose_smart_target(candidates)
  local open_count = 0
  local collapsed_count = 0

  for _, candidate in ipairs(candidates) do
    if candidate.current_compact == UNCOLLAPSED_FOLDERCOMPACT then
      open_count = open_count + 1
    else
      collapsed_count = collapsed_count + 1
    end
  end

  if open_count >= collapsed_count then
    return COLLAPSED_FOLDERCOMPACT, "Collapse", open_count, collapsed_count
  end

  return UNCOLLAPSED_FOLDERCOMPACT, "Expand", open_count, collapsed_count
end

local function get_target_compact(preset, candidate, smart_target_compact)
  if preset.mode == "show_depth" then
    if candidate.effective_depth < preset.visible_depth then
      return UNCOLLAPSED_FOLDERCOMPACT
    end

    return COLLAPSED_FOLDERCOMPACT
  end

  if preset.mode == "smart" then
    return smart_target_compact
  end

  return preset.compact
end

local function apply_folder_preset(preset, hidden_mode)
  local candidates, selected_root_count = collect_folder_candidates(preset, hidden_mode)
  local requires_selection = preset.target == "selected_folders"
      or preset.target == "selected_trees"

  if requires_selection and selected_root_count == 0 then
    return {
      missing_selection = true,
      matched_count = 0,
      changed_count = 0,
      preset = preset
    }
  end

  local smart_target_compact = nil
  local smart_action = nil
  local smart_open_count = 0
  local smart_collapsed_count = 0

  if preset.mode == "smart" then
    smart_target_compact,
    smart_action,
    smart_open_count,
    smart_collapsed_count = choose_smart_target(candidates)
  end

  local changes = {}

  for _, candidate in ipairs(candidates) do
    local target_compact = get_target_compact(preset, candidate, smart_target_compact)

    if candidate.current_compact ~= target_compact then
      changes[#changes + 1] = {
        track = candidate.track,
        target_compact = target_compact
      }
    end
  end

  if #changes > 0 then
    local project = 0
    local undo_text = preset.label

    if smart_action then
      undo_text = undo_text .. ": " .. smart_action
    end

    reaper.Undo_BeginBlock2(project)
    reaper.PreventUIRefresh(1)

    for _, change in ipairs(changes) do
      reaper.SetMediaTrackInfo_Value(change.track, "I_FOLDERCOMPACT", change.target_compact)
    end

    reaper.PreventUIRefresh(-1)
    reaper.TrackList_AdjustWindows(false)
    reaper.UpdateArrange()
    reaper.Undo_EndBlock2(project, undo_text, -1)
  end

  return {
    missing_selection = false,
    matched_count = #candidates,
    changed_count = #changes,
    preset = preset,
    smart_action = smart_action,
    smart_open_count = smart_open_count,
    smart_collapsed_count = smart_collapsed_count
  }
end

local function plural(count, singular, plural_value)
  if count == 1 then
    return singular
  end

  return plural_value or singular .. "s"
end

local function get_status_message(stats)
  if stats.missing_selection then
    return "No selected folder track or selected child track inside a folder was found.", true
  end

  if stats.matched_count == 0 then
    return "No matching folder tracks were found.", true
  end

  return "Changed " .. tostring(stats.changed_count)
      .. " of " .. tostring(stats.matched_count) .. " matching "
      .. plural(stats.matched_count, "folder track") .. ".", false
end

local function show_report(stats, summary_mode)
  if stats.missing_selection then
    reaper.MB(get_status_message(stats), WINDOW_TITLE, 0)
    return
  end

  if summary_mode ~= "on" then
    return
  end

  local message = stats.preset.label .. "\n\n" .. get_status_message(stats)

  if stats.smart_action and stats.matched_count > 0 then
    message = message .. "\n\nSmart toggle chose " .. stats.smart_action:lower()
        .. " after seeing " .. tostring(stats.smart_open_count) .. " open and "
        .. tostring(stats.smart_collapsed_count) .. " collapsed."
  end

  reaper.MB(message, WINDOW_TITLE, 0)
end

local function apply_current(close_after)
  local preset = PRESETS[ui.preset_index] or PRESETS[1]
  local hidden_mode = get_hidden_mode()
  local summary_mode = get_summary_mode()
  local stats = apply_folder_preset(preset, hidden_mode)

  ui.status, ui.status_is_error = get_status_message(stats)

  if not stats.missing_selection then
    save_project_state()
  end

  show_report(stats, summary_mode)

  if close_after and not stats.missing_selection then
    close_window()
  end
end

local function draw_item_combo(label, items, selected_index)
  ImGui.Text(ctx, label)
  ImGui.SetNextItemWidth(ctx, -1)

  local selected_item = items[selected_index] or items[1]
  if ImGui.BeginCombo(ctx, "##" .. label, selected_item.label) then
    for index, item in ipairs(items) do
      if ImGui.Selectable(ctx, item.label, index == selected_index) then
        selected_index = index
      end

      if index == selected_index then
        ImGui.SetItemDefaultFocus(ctx)
      end
    end

    ImGui.EndCombo(ctx)
  end

  return selected_index
end

local function draw_preset_combo()
  local selected_preset = PRESETS[ui.preset_index] or PRESETS[1]
  local current_group = nil

  ImGui.Text(ctx, "Preset")
  ImGui.SetNextItemWidth(ctx, -1)

  if ImGui.BeginCombo(ctx, "##Preset", selected_preset.label) then
    for index, preset in ipairs(PRESETS) do
      if preset.group ~= current_group then
        if current_group ~= nil then
          ImGui.Separator(ctx)
        end

        current_group = preset.group
        ImGui.TextDisabled(ctx, current_group)
      end

      if ImGui.Selectable(ctx, preset.label, index == ui.preset_index) then
        ui.preset_index = index
        ui.status = ""
      end

      if index == ui.preset_index then
        ImGui.SetItemDefaultFocus(ctx)
      end
    end

    ImGui.EndCombo(ctx)
  end
end

local function draw_buttons()
  if ImGui.Button(ctx, "Apply", 100, 0) then
    apply_current(false)
  end

  ImGui.SameLine(ctx)

  if ImGui.Button(ctx, "Apply & Close", 130, 0) then
    apply_current(true)
  end

  ImGui.SameLine(ctx)

  if ImGui.Button(ctx, "Close", 90, 0) then
    close_window()
  end
end

local function draw_status()
  if ui.status == "" then
    return
  end

  if ui.status_is_error then
    ImGui.TextColored(ctx, 0xFF6D6DFF, ui.status)
  else
    ImGui.TextColored(ctx, 0x8EDB8EFF, ui.status)
  end
end

local function draw_window_contents()
  local preset = PRESETS[ui.preset_index] or PRESETS[1]

  draw_preset_combo()
  ImGui.Spacing(ctx)

  ui.hidden_index = draw_item_combo("Hidden tracks", HIDDEN_MODES, ui.hidden_index)
  ImGui.Spacing(ctx)

  ui.summary_index = draw_item_combo("Summary", SUMMARY_MODES, ui.summary_index)
  ImGui.Separator(ctx)

  ImGui.PushTextWrapPos(ctx, 0)
  ImGui.TextWrapped(ctx, preset.description)
  ImGui.PopTextWrapPos(ctx)

  ImGui.Spacing(ctx)
  draw_status()
  ImGui.Spacing(ctx)
  draw_buttons()
end

local function prepare_window()
  if not ui.positioned then
    local window_x = get_ext_number("window_x", nil)
    local window_y = get_ext_number("window_y", nil)
    local window_w = get_ext_number("window_w", nil)
    local window_h = get_ext_number("window_h", nil)

    if window_w and window_h then
      ImGui.SetNextWindowSize(ctx, window_w, window_h, ImGui.Cond_Appearing)
    else
      ImGui.SetNextWindowSize(ctx, WINDOW_W, WINDOW_H, ImGui.Cond_FirstUseEver)
    end

    if window_x and window_y then
      ImGui.SetNextWindowPos(ctx, window_x, window_y, ImGui.Cond_Appearing)
    end

    ui.positioned = true
  end
end

local function main()
  prepare_window()

  local visible, open = ImGui.Begin(ctx, WINDOW_TITLE, true)

  if visible then
    ui.last_window_x, ui.last_window_y = ImGui.GetWindowPos(ctx)
    ui.last_window_w, ui.last_window_h = ImGui.GetWindowSize(ctx)
    local ok_draw, draw_error = pcall(draw_window_contents)
    ImGui.End(ctx)

    if not ok_draw then
      reaper.MB(tostring(draw_error), WINDOW_TITLE, 0)
      close_window()
    end
  end

  if open and not ui.closed then
    reaper.defer(main)
  else
    close_window()
  end
end

load_state()
reaper.defer(main)
