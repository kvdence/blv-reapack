-- @description BLV Reset all track volumes to 0 dB
-- @author BLV
-- @version 1.0.0
-- @about
--   Sets every track's volume fader to 0 dB.
--   Copyright (c) 2026 BLV. All rights reserved. Free to use. You may not copy, modify, repackage or redistribute this software.

reaper.ShowConsoleMsg("Script started...\n") -- This will print to the Reaper ReaScript console

reaper.Undo_BeginBlock()

local track_count = reaper.CountTracks(0)
reaper.ShowConsoleMsg("Number of tracks found: " .. track_count .. "\n")

if track_count == 0 then
  reaper.ShowConsoleMsg("No tracks found in the project. Script will not change any volumes.\n")
end

for i = 0, track_count - 1 do
  local track = reaper.GetTrack(0, i)
  if track then
    reaper.ShowConsoleMsg("Processing track " .. (i + 1) .. "\n")
    reaper.SetMediaTrackInfo_Value(track, "D_VOL", 1.0)
  else
    reaper.ShowConsoleMsg("Could not get track object for index " .. i .. "\n")
  end
end

reaper.Undo_EndBlock("Reset All Track Volumes to 0dB", -1) -- The -1 flag is for "don't add undo options"
reaper.UpdateArrange()

reaper.ShowConsoleMsg("Script finished.\n")

reaper.defer(function() end) -- Keep this to prevent the script from returning a value to Reaper
