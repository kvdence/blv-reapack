-- @description BLV Pan selected tracks 100 left
-- @author BLV
-- @version 1.0.0
-- @about
--   Pans the selected tracks hard left.
--   Copyright (c) 2026 BLV. All rights reserved. Free to use. You may not copy, modify, repackage or redistribute this software.

-- =========================================================
-- USER CONFIGURATION AREA
-- Change these values to create new versions of this script
-- =========================================================

-- Enter a number between 0 and 100
local pan_amount = 100

-- Enter "left" or "right" (must be lowercase, inside quotes)
local direction = "left"

-- =========================================================
-- SCRIPT LOGIC (DO NOT EDIT BELOW)
-- =========================================================

function main()
    -- Get number of selected tracks
    local track_count = reaper.CountSelectedTracks(0)

    -- If no tracks are selected, stop the script
    if track_count == 0 then return end

    -- Start Undo Block so you can Ctrl+Z this action
    reaper.Undo_BeginBlock()

    -- Calculate the Reaper Pan Value (-1.0 to 1.0)
    local final_pan = pan_amount / 100
    if direction == "left" then
        final_pan = final_pan * -1
    end

    -- Loop through all selected tracks and apply pan
    for i = 0, track_count - 1 do
        local track = reaper.GetSelectedTrack(0, i)
        reaper.SetMediaTrackInfo_Value(track, "D_PAN", final_pan)
    end

    -- End Undo Block
    reaper.Undo_EndBlock("Set Pan to " .. pan_amount .. "% " .. direction, -1)
end

-- Run the function
reaper.PreventUIRefresh(1)
main()
reaper.PreventUIRefresh(-1)
reaper.UpdateArrange()
