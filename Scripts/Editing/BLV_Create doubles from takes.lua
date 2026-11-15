-- @description BLV Create doubles from takes
-- @author BLV
-- @version 1.0.0
-- @about
--   Makes a staggered left and right pair from a lead track's takes, named "1 L" and "2 R" and panned hard left and right.
--   Copyright (c) 2026 BLV. All rights reserved. Free to use. You may not copy, modify, repackage or redistribute this software.

function Main()
  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1) 

  -- 1. VALIDATION
  local selected_tracks_count = reaper.CountSelectedTracks(0)
  if selected_tracks_count == 0 then 
    reaper.ShowMessageBox("Please select at least one track.", "No Track Selected", 0)
    return 
  end

  local sources = {}
  for i = 0, selected_tracks_count - 1 do
    sources[i+1] = reaper.GetSelectedTrack(0, i)
  end
  
  reaper.Main_OnCommand(40297, 0) -- Unselect all

  -- 2. MAIN PROCESSING LOOP
  for _, lead_track in ipairs(sources) do
    
    -- A. DETERMINE CORE NAME
    local _, lead_name = reaper.GetSetMediaTrackInfo_String(lead_track, "P_NAME", "", false)
    local core_name = lead_name:gsub("%s*%(.-%)", ""):gsub("Lead", ""):gsub("LEAD", "")
    core_name = core_name:match("^%s*(.-)%s*$")
    if core_name == "" then core_name = "Double" end

    -- =========================================================
    -- PHASE 1: CREATE "1 L" (LEFT)
    -- =========================================================
    
    -- Duplicate Lead
    reaper.SetOnlyTrackSelected(lead_track)
    reaper.Main_OnCommand(40062, 0) -- Duplicate
    local track_L = reaper.GetSelectedTrack(0, 0)
    
    -- Rename & Pan
    reaper.GetSetMediaTrackInfo_String(track_L, "P_NAME", core_name .. " 1 L", true)
    reaper.SetMediaTrackInfo_Value(track_L, "D_PAN", -1.0) -- Hard Left
    
    -- Strip FX & Sends
    local fx_count = reaper.TrackFX_GetCount(track_L)
    for fx = fx_count - 1, 0, -1 do reaper.TrackFX_Delete(track_L, fx) end
    local rec_fx = reaper.TrackFX_GetRecCount(track_L)
    for fx = rec_fx - 1, 0, -1 do reaper.TrackFX_Delete(track_L, 0x1000000 + fx) end
    local sends = reaper.GetTrackNumSends(track_L, 0)
    for s = sends - 1, 0, -1 do reaper.RemoveTrackSend(track_L, 0, s) end

    -- Purge Take 1 & Clean Ghosts
    local items_L = reaper.CountTrackMediaItems(track_L)
    reaper.Main_OnCommand(40289, 0) 
    for j = items_L - 1, 0, -1 do
       local item = reaper.GetTrackMediaItem(track_L, j)
       if item and reaper.ValidatePtr(item, "MediaItem*") then
         if reaper.CountTakes(item) > 0 then
            reaper.SetMediaItemSelected(item, true)
            reaper.Main_OnCommand(40129, 0) -- Delete active take
            reaper.Main_OnCommand(40613, 0) -- Remove empty lanes
            
            if reaper.CountTakes(item) == 0 then 
                reaper.SetMediaItemInfo_Value(item, "B_MUTE", 1) 
            end
            reaper.SetMediaItemSelected(item, false)
         end
       end
    end

    -- =========================================================
    -- PHASE 2: CREATE "2 R" (RIGHT)
    -- =========================================================
    
    -- Duplicate Track L (Peels the next layer)
    reaper.SetOnlyTrackSelected(track_L)
    reaper.Main_OnCommand(40062, 0) -- Duplicate
    local track_R = reaper.GetSelectedTrack(0, 0)
    
    -- Rename & Pan
    reaper.GetSetMediaTrackInfo_String(track_R, "P_NAME", core_name .. " 2 R", true)
    reaper.SetMediaTrackInfo_Value(track_R, "D_PAN", 1.0) -- Hard Right
    
    -- Purge Take 2 (Layer 2) - WITH SAFETY CHECK
    local items_R = reaper.CountTrackMediaItems(track_R)
    reaper.Main_OnCommand(40289, 0) 
    for j = items_R - 1, 0, -1 do
       local item = reaper.GetTrackMediaItem(track_R, j)
       if item and reaper.ValidatePtr(item, "MediaItem*") then
         if reaper.CountTakes(item) > 1 then
            reaper.SetMediaItemSelected(item, true)
            reaper.Main_OnCommand(40129, 0) -- Delete active take
            reaper.Main_OnCommand(40613, 0) -- Remove empty lanes
            reaper.SetMediaItemSelected(item, false)
         end
       end
    end

    -- =========================================================
    -- PHASE 3: MOVE TO BOTTOM
    -- =========================================================
    
    reaper.Main_OnCommand(40297, 0) -- Unselect all
    reaper.SetTrackSelected(track_L, true)
    reaper.SetTrackSelected(track_R, true)
    reaper.ReorderSelectedTracks(reaper.CountTracks(0), 0)

  end

  -- 3. FINALIZE
  reaper.PreventUIRefresh(-1)
  reaper.TrackList_AdjustWindows(false)
  reaper.UpdateArrange()
  
  reaper.Main_OnCommand(40913, 0) -- Scroll to view
  
  reaper.Undo_EndBlock("Simple Staggered Pairs v3.2", -1)
end

Main()
