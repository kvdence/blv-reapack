-- @description BLV Copy selected track numbers
-- @author BLV
-- @version 1.0.0
-- @about
--   Copies the numbers of the selected tracks to the clipboard, separated by commas.
--   Requires: SWS (install from ReaPack).
--   Copyright (c) 2026 BLV. All rights reserved. Free to use. You may not copy, modify, repackage or redistribute this software.

-- Main function
function main()
  local count = reaper.CountSelectedTracks(0)
  if count == 0 then
    reaper.ShowMessageBox("No tracks selected!", "Error", 0)
    return
  end

  local track_numbers = {}

  for i = 0, count - 1 do
    local track = reaper.GetSelectedTrack(0, i)
    local track_index = reaper.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER")
    table.insert(track_numbers, tostring(math.floor(track_index)))
  end

  local track_string = table.concat(track_numbers, ",")
  reaper.CF_SetClipboard(track_string)  -- Requires SWS extension

  reaper.ShowConsoleMsg("Copied track numbers to clipboard: " .. track_string .. "\n")
end

-- Check for SWS extension (needed for CF_SetClipboard)
if reaper.CF_SetClipboard then
  reaper.Undo_BeginBlock()
  main()
  reaper.Undo_EndBlock("Copy Selected Track Numbers to Clipboard", -1)
else
  reaper.ShowMessageBox("SWS Extension is required for this script to work.\nDownload from: https://www.sws-extension.org", "Missing Dependency", 0)
end
