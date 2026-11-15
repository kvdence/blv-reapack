-- @description BLV Prefix tracks with parent name
-- @author BLV
-- @version 1.0.0
-- @about
--   Puts each track's parent folder name in front of its name, with exceptions for pass-through folders.
--   Copyright (c) 2026 BLV. All rights reserved. Free to use. You may not copy, modify, repackage or redistribute this software.

function main()
    reaper.Undo_BeginBlock()

    -- =========================================================
    -- CONFIGURATION
    -- =========================================================
    local separator = "_"           
    local strip_spaces = true       
    
    -- PASSTHROUGH EXCEPTIONS (Case Sensitive)
    -- If a track is inside one of these, the script looks at the GRANDPARENT instead.
    local passthrough_folders = {
        ["Transient"] = true,
        ["Sustained"] = true,
        ["transient"] = true, -- covering lowercase just in case
        ["sustained"] = true
    }
    -- =========================================================

    local count_sel_tracks = reaper.CountSelectedTracks(0)
    if count_sel_tracks == 0 then return end

    for i = 0, count_sel_tracks - 1 do
        local track = reaper.GetSelectedTrack(0, i)
        local parent = reaper.GetParentTrack(track)
        
        if parent then
            -- 1. Get Initial Parent Name
            local _, parent_name = reaper.GetSetMediaTrackInfo_String(parent, "P_NAME", "", false)
            
            -- 2. CHECK FOR EXCEPTIONS (The "Passthrough" Logic)
            -- If the parent is in our exception list, try to grab the Grandparent
            if passthrough_folders[parent_name] then
                local grandparent = reaper.GetParentTrack(parent)
                if grandparent then
                    local _, gp_name = reaper.GetSetMediaTrackInfo_String(grandparent, "P_NAME", "", false)
                    parent_name = gp_name -- Override the name with the grandparent
                else
                    -- Fallback: If "Transient" is the top level (no grandparent), 
                    -- force "Instruments" based on your request, or keep existing.
                    -- We'll assume the structure implies a grandparent exists.
                    parent_name = "Instruments" 
                end
            end

            -- Clean the Name (remove spaces if requested)
            local target_prefix = parent_name
            if strip_spaces then
                target_prefix = target_prefix:gsub("%s+", "")
            end

            if target_prefix ~= "" then
                local _, track_name = reaper.GetSetMediaTrackInfo_String(track, "P_NAME", "", false)
                
                -- 3. Smart Swap (Legacy Removal)
                local sep_start, sep_end = string.find(track_name, separator)
                if sep_start then
                    local current_prefix = string.sub(track_name, 1, sep_start - 1)
                    if current_prefix ~= target_prefix and current_prefix ~= "" then
                        track_name = string.sub(track_name, sep_end + 1)
                    end
                end

                -- 4. Stutter Prevention & Final Rename
                local esc_target = target_prefix:gsub("[%(%)%.%%%+%-%*%?%[%]%^%$]", "%%%1")
                local pattern = "^" .. esc_target .. separator
                
                if not string.find(track_name, pattern) then
                    local new_name = target_prefix .. separator .. track_name
                    reaper.GetSetMediaTrackInfo_String(track, "P_NAME", new_name, true)
                end
            end
        end
    end

    reaper.Undo_EndBlock("Smart Rename (Passthrough)", -1)
end

reaper.PreventUIRefresh(1)
main()
reaper.PreventUIRefresh(-1)
reaper.UpdateArrange()
