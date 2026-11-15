-- @description BLV Alphabetize selected tracks
-- @author BLV
-- @version 1.0.0
-- @about
--   Sorts the selected tracks A to Z by name. Selected folders move as whole blocks and the folder structure is kept.
--   Copyright (c) 2026 BLV. All rights reserved. Free to use. You may not copy, modify, repackage or redistribute this software.

local SCRIPT_TITLE = "Alphabetize selected tracks only"

local function get_track_guid(track)
  return reaper.GetTrackGUID(track)
end

local function get_track_name(track)
  local _, name = reaper.GetSetMediaTrackInfo_String(track, "P_NAME", "", false)
  return name or ""
end

local function sort_key(name)
  name = name:gsub("^%s+", ""):gsub("%s+$", "")
  if name == "" then
    return "\255"
  end
  return name:lower()
end

local function capture_original_state()
  local state = {
    tracks = {},
    depth_by_guid = {},
    selected_by_guid = {},
  }

  for i = 0, reaper.CountTracks(0) - 1 do
    local track = reaper.GetTrack(0, i)
    local guid = get_track_guid(track)
    state.tracks[#state.tracks + 1] = track
    state.depth_by_guid[guid] = math.floor(reaper.GetTrackDepth(track))
  end

  for i = 0, reaper.CountSelectedTracks(0) - 1 do
    local track = reaper.GetSelectedTrack(0, i)
    state.selected_by_guid[get_track_guid(track)] = true
  end

  return state
end

local function get_original_depth(track, state)
  return state.depth_by_guid[get_track_guid(track)]
end

local function has_selected_ancestor(track, state)
  local parent = reaper.GetParentTrack(track)

  while parent do
    if state.selected_by_guid[get_track_guid(parent)] then
      return true
    end

    parent = reaper.GetParentTrack(parent)
  end

  return false
end

local function get_track_index(track)
  if not track or not reaper.ValidatePtr(track, "MediaTrack*") then
    return nil
  end

  return math.floor(reaper.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER")) - 1
end

local function get_immediate_units(parent_track, state)
  local units = {}
  local parent_depth = -1
  local start_index = 0

  if parent_track then
    parent_depth = get_original_depth(parent_track, state)
    local parent_index = get_track_index(parent_track)
    if not parent_index then
      return units
    end
    start_index = parent_index + 1
  end

  local child_depth = parent_depth + 1
  local track_count = reaper.CountTracks(0)

  for i = start_index, track_count - 1 do
    local track = reaper.GetTrack(0, i)
    local depth = get_original_depth(track, state)

    if not depth then
      break
    end

    if parent_track and depth <= parent_depth then
      break
    end

    if depth == child_depth then
      units[#units + 1] = track
    end
  end

  return units
end

local function get_unit_block_tracks(unit_track, state)
  local block = { unit_track }
  local root_depth = get_original_depth(unit_track, state)
  local start_index = get_track_index(unit_track)

  if not root_depth or not start_index then
    return block
  end

  for i = start_index + 1, reaper.CountTracks(0) - 1 do
    local track = reaper.GetTrack(0, i)
    local depth = get_original_depth(track, state)

    if not depth or depth <= root_depth then
      break
    end

    block[#block + 1] = track
  end

  return block
end

local function select_unit_block(unit_track, state)
  reaper.Main_OnCommand(40297, 0) -- Track: Unselect all tracks

  for _, track in ipairs(get_unit_block_tracks(unit_track, state)) do
    reaper.SetTrackSelected(track, true)
  end
end

local function restore_folder_depths(state)
  local track_count = reaper.CountTracks(0)

  for i = 0, track_count - 1 do
    local track = reaper.GetTrack(0, i)
    local current_depth = get_original_depth(track, state)

    if current_depth then
      local next_depth = 0

      if i < track_count - 1 then
        local next_track = reaper.GetTrack(0, i + 1)
        next_depth = get_original_depth(next_track, state) or 0
      end

      reaper.SetMediaTrackInfo_Value(track, "I_FOLDERDEPTH", next_depth - current_depth)
    end
  end
end

local function restore_selection(state)
  reaper.Main_OnCommand(40297, 0) -- Track: Unselect all tracks

  for _, track in ipairs(state.tracks) do
    if reaper.ValidatePtr(track, "MediaTrack*") and state.selected_by_guid[get_track_guid(track)] then
      reaper.SetTrackSelected(track, true)
    end
  end
end

local function guid_list_from_units(units)
  local guids = {}
  for i, track in ipairs(units) do
    guids[i] = get_track_guid(track)
  end
  return guids
end

local function build_sort_groups(state)
  local groups_by_parent = {}

  for _, track in ipairs(state.tracks) do
    local guid = get_track_guid(track)

    if state.selected_by_guid[guid] and not has_selected_ancestor(track, state) then
      local parent = reaper.GetParentTrack(track)
      local parent_guid = parent and get_track_guid(parent) or "__ROOT__"

      if not groups_by_parent[parent_guid] then
        groups_by_parent[parent_guid] = {
          parent = parent,
          parent_depth = parent and get_original_depth(parent, state) or -1,
          selected_units = {},
        }
      end

      groups_by_parent[parent_guid].selected_units[#groups_by_parent[parent_guid].selected_units + 1] = track
    end
  end

  local groups = {}

  for _, group in pairs(groups_by_parent) do
    if #group.selected_units > 1 then
      local current_units = get_immediate_units(group.parent, state)
      local selected_at_slot = {}
      local selected_units = {}

      for _, track in ipairs(group.selected_units) do
        selected_units[#selected_units + 1] = track
        selected_at_slot[get_track_guid(track)] = true
      end

      table.sort(selected_units, function(a, b)
        local a_key = sort_key(get_track_name(a))
        local b_key = sort_key(get_track_name(b))

        if a_key == b_key then
          return (get_track_index(a) or 0) < (get_track_index(b) or 0)
        end

        return a_key < b_key
      end)

      local sorted_i = 1
      local target_units = {}

      for i, unit in ipairs(current_units) do
        if selected_at_slot[get_track_guid(unit)] then
          target_units[i] = selected_units[sorted_i]
          sorted_i = sorted_i + 1
        else
          target_units[i] = unit
        end
      end

      group.target_guids = guid_list_from_units(target_units)
      groups[#groups + 1] = group
    end
  end

  table.sort(groups, function(a, b)
    return a.parent_depth > b.parent_depth
  end)

  return groups
end

local function find_unit_by_guid(units, guid)
  for _, unit in ipairs(units) do
    if get_track_guid(unit) == guid then
      return unit
    end
  end

  return nil
end

local function reorder_group(group, state)
  for slot = 1, #group.target_guids do
    local current_units = get_immediate_units(group.parent, state)
    local current_unit = current_units[slot]
    local target_unit = find_unit_by_guid(current_units, group.target_guids[slot])

    if current_unit and target_unit and current_unit ~= target_unit then
      local before_index = get_track_index(current_unit)

      if before_index then
        select_unit_block(target_unit, state)
        reaper.ReorderSelectedTracks(before_index, 0)
        restore_folder_depths(state)
      end
    end
  end
end

local function main()
  if reaper.CountSelectedTracks(0) == 0 then
    reaper.ShowMessageBox("Select two or more tracks to alphabetize.", SCRIPT_TITLE, 0)
    return
  end

  local state = capture_original_state()
  local groups = build_sort_groups(state)

  if #groups == 0 then
    reaper.ShowMessageBox("Select at least two tracks with the same parent/root level to alphabetize.", SCRIPT_TITLE, 0)
    return
  end

  for _, group in ipairs(groups) do
    reorder_group(group, state)
  end

  restore_folder_depths(state)
  restore_selection(state)
end

reaper.Undo_BeginBlock()
reaper.PreventUIRefresh(1)

local ok, err = pcall(main)

reaper.PreventUIRefresh(-1)
reaper.UpdateArrange()
reaper.Undo_EndBlock(SCRIPT_TITLE, -1)

if not ok then
  reaper.ShowMessageBox(tostring(err), SCRIPT_TITLE .. " - error", 0)
end
