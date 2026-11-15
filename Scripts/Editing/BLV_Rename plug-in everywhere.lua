-- @description BLV Rename plug-in everywhere
-- @author BLV
-- @version 1.0.0
-- @about
--   Renames every instance of the selected plug-in across the project in one go.
--   Copyright (c) 2026 BLV. All rights reserved. Free to use. You may not copy, modify, repackage or redistribute this software.

function main()
    local track, fx_idx
    local found = false

    -- METHOD 1: Check for FX selected inside an open FX Chain window
    -- This works if you have the FX Chain open and the plugin highlighted in the list
    local selected_track = reaper.GetSelectedTrack(0, 0)
    if selected_track then
        -- Returns index of the FX currently visible/selected in the chain
        local chain_idx = reaper.TrackFX_GetChainVisible(selected_track)
        if chain_idx >= 0 then
            track = selected_track
            fx_idx = chain_idx
            found = true
        end
    end

    -- METHOD 2: Fallback to "Focused Window" if Method 1 failed
    -- This works if the plugin is floating in its own window
    if not found then
        local retval, tr_idx, item_idx, f_idx = reaper.GetFocusedFX2()
        if retval == 1 then
            if tr_idx == 0 then
                track = reaper.GetMasterTrack(0)
            else
                track = reaper.GetTrack(0, tr_idx - 1)
            end
            fx_idx = f_idx
            found = true
        end
    end

    -- ERROR HANDLING
    if not found then
        reaper.ShowMessageBox(
            "Could not identify a target plugin.\n\n" ..
            "Ensure one of the following:\n" ..
            "1. You have a Track selected and the FX Chain window is open/visible.\n" ..
            "2. Or, you have a Floating FX window focused and use a Shortcut Key.", 
            "Target Not Found", 0)
        return
    end

    -- --------------------------------------------------------
    -- CORE LOGIC: Get Reference Name -> Prompt -> Batch Rename
    -- --------------------------------------------------------
    
    -- Get the "Original Name" (The internal plugin type, e.g., "pro-q 3")
    -- We use this identifier to find all siblings.
    local _, ref_original_name = reaper.TrackFX_GetNamedConfigParm(track, fx_idx, "original_name")
    
    -- Prompt User
    local ok, new_alias = reaper.GetUserInputs("Batch Rename", 1, "New Name for all instances:", "")
    if not ok or new_alias == "" then return end

    reaper.Undo_BeginBlock()
    
    local track_count = reaper.CountTracks(0)
    local rename_count = 0

    -- Function to scan a track
    local function process_track(tr)
        local fx_count = reaper.TrackFX_GetCount(tr)
        for i = 0, fx_count - 1 do
            local _, original_name = reaper.TrackFX_GetNamedConfigParm(tr, i, "original_name")
            
            -- Compare the underlying plugin type
            if original_name == ref_original_name then
                reaper.TrackFX_SetNamedConfigParm(tr, i, "renamed_name", new_alias)
                rename_count = rename_count + 1
            end
        end
    end

    -- Scan Master Track
    process_track(reaper.GetMasterTrack(0))
    
    -- Scan All Regular Tracks
    for t = 0, track_count - 1 do
        local tr = reaper.GetTrack(0, t)
        process_track(tr)
    end

    reaper.Undo_EndBlock("Batch Rename " .. rename_count .. " FX", -1)
    reaper.UpdateArrange()
    
    -- Optional Confirmation (Comment out if annoying)
    -- reaper.ShowConsoleMsg("Renamed " .. rename_count .. " instances.\n")
end

main()
