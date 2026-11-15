-- @description BLV Prefix selected tracks with parent name (skip BUS)
-- @author BLV
-- @version 1.0.0
-- @about
--   Puts each selected track's parent folder name in front of its name; "BUS" is left out of the parent name and BUS tracks are skipped.
--   Copyright (c) 2026 BLV. All rights reserved. Free to use. You may not copy, modify, repackage or redistribute this software.

function main()
    reaper.Undo_BeginBlock()

    -- =========================================================
    -- CONFIGURATION
    -- =========================================================
    local separator = "_"            
    local strip_spaces = true        
    
    local passthrough_folders = {
        ["Transient"] = true, ["Sustained"] = true,
        ["transient"] = true, ["sustained"] = true
    }
    -- =========================================================

    local count_sel_tracks = reaper.CountSelectedTracks(0)
    if count_sel_tracks == 0 then return end

    for i = 0, count_sel_tracks - 1 do
        local track = reaper.GetSelectedTrack(0, i)
        local parent = reaper.GetParentTrack(track)
        
        if parent then
            -- 1. Get Parent Name
            local _, parent_name = reaper.GetSetMediaTrackInfo_String(parent, "P_NAME", "", false)
            
            -- =========================================================
            -- NEW: STRIP "BUS" FROM PARENT NAME
            -- =========================================================
            -- This ensures "BGV BUS" becomes just "BGV" for the prefix.
            -- Matches space(optional) + BUS (case insensitive) at the end of the string.
            parent_name = parent_name:gsub("%s-[Bb][Uu][Ss]$", "")

            -- Passthrough Logic
            if passthrough_folders[parent_name] then
                local grandparent = reaper.GetParentTrack(parent)
                if grandparent then
                    local _, gp_name = reaper.GetSetMediaTrackInfo_String(grandparent, "P_NAME", "", false)
                    parent_name = gp_name
                    -- Also strip BUS from grandparent if that's what we are using
                    parent_name = parent_name:gsub("%s-[Bb][Uu][Ss]$", "")
                else
                    parent_name = "Instruments" 
                end
            end

            -- Prepare Target Prefix
            local target_prefix = parent_name
            if strip_spaces then
                target_prefix = target_prefix:gsub("%s+", "")
            end

            if target_prefix ~= "" then
                local _, track_name = reaper.GetSetMediaTrackInfo_String(track, "P_NAME", "", false)
                
                -- =========================================================
                -- EXCEPTION: Ignore "BUS" Tracks (Don't rename the bus itself)
                -- =========================================================
                local is_bus_track = string.match(string.upper(track_name), "BUS%s*$")
                
                if not is_bus_track then

                    -- =========================================================
                    -- EXISTING LOGIC: Advanced Cleaning
                    -- =========================================================
                    
                    local esc_target = target_prefix:gsub("[%(%)%.%%%+%-%*%?%[%]%^%$]", "%%%1")
                    
                    -- A. Check if track ALREADY starts with parent name
                    local found_redundancy = false
                    
                    local patterns = {
                        "^" .. esc_target .. "_",        
                        "^" .. esc_target .. "%s+-%s+",  
                        "^" .. esc_target .. "%-",       
                        "^" .. esc_target .. "%s+"       
                    }
                    
                    for _, pat in ipairs(patterns) do
                        if string.find(track_name, pat) then
                            track_name = string.gsub(track_name, pat, "", 1)
                            found_redundancy = true
                            break
                        end
                    end

                    -- B. Legacy Swap
                    if not found_redundancy then
                        local sep_start, sep_end = string.find(track_name, separator)
                        if sep_start then
                            local current_prefix = string.sub(track_name, 1, sep_start - 1)
                            if current_prefix ~= target_prefix and current_prefix ~= "" then
                                track_name = string.sub(track_name, sep_end + 1)
                            end
                        end
                    end

                    -- =========================================================
                    -- APPLY NEW NAME
                    -- =========================================================
                    local new_name = target_prefix .. separator .. track_name
                    reaper.GetSetMediaTrackInfo_String(track, "P_NAME", new_name, true)
                end
            end
        end
    end

    reaper.Undo_EndBlock("Smart Rename (Strip BUS)", -1)
end

reaper.PreventUIRefresh(1)
main()
reaper.PreventUIRefresh(-1)
reaper.UpdateArrange()
