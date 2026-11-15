-- @description BLV Select children of selected folders
-- @author BLV
-- @version 1.0.0
-- @about
--   Selects every track inside the selected folder tracks.
--   Copyright (c) 2026 BLV. All rights reserved. Free to use. You may not copy, modify, repackage or redistribute this software.

function main()
    reaper.Undo_BeginBlock()
    
    -- Store initially selected tracks to process
    local selected_tracks = {}
    local count_sel = reaper.CountSelectedTracks(0)
    
    if count_sel == 0 then return end
    
    for i = 0, count_sel - 1 do
        selected_tracks[i+1] = reaper.GetSelectedTrack(0, i)
    end
    
    -- Clear current selection
    reaper.Main_OnCommand(40297, 0) -- Unselect all tracks

    for _, track in ipairs(selected_tracks) do
        -- Check if it is a folder
        local depth = reaper.GetMediaTrackInfo_Value(track, "I_FOLDERDEPTH")
        
        if depth == 1 then -- It is a folder start
            local track_idx = reaper.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER")
            local total_tracks = reaper.CountTracks(0)
            
            -- Look forward from the folder
            local folder_depth = 1
            for j = track_idx, total_tracks - 1 do
                local next_track = reaper.GetTrack(0, j)
                local next_depth = reaper.GetMediaTrackInfo_Value(next_track, "I_FOLDERDEPTH")
                
                -- Select this child
                reaper.SetTrackSelected(next_track, true)
                
                -- Track hierarchy depth to know when the folder ends
                folder_depth = folder_depth + next_depth
                
                if folder_depth <= 0 then
                    -- We have reached the end of this folder
                    break 
                end
            end
        end
    end

    reaper.Undo_EndBlock("Select Children Tracks", -1)
end

reaper.PreventUIRefresh(1)
main()
reaper.PreventUIRefresh(-1)
reaper.UpdateArrange()
