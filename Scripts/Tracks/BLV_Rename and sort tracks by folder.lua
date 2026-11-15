-- @description BLV Rename and sort tracks by folder
-- @author BLV
-- @version 1.0.0
-- @about
--   Renames tracks after their folder and sorts them by the folder hierarchy.
--   Copyright (c) 2026 BLV. All rights reserved. Free to use. You may not copy, modify, repackage or redistribute this software.

function main()
    reaper.Undo_BeginBlock()
    reaper.PreventUIRefresh(1)

    -- =========================================================
    -- CONFIGURATION
    -- =========================================================
    local separator = "_"       
    local strip_spaces = true   
    local use_padding = false   

    -- HIERARCHY MAP (Lower Rank = Higher in the list)
    local drum_map = {
        -- 1. KICK
        { target = "Kick",  rank = 10, patterns = {"kick", "bd", "bassdrum"} },
        
        -- 2. SNARE / RIM / CLAP (The Backbeat Group)
        { target = "Snare", rank = 20, patterns = {"snare", "sd", "sidestick"} }, 
        { target = "Rim",   rank = 21, patterns = {"rim", "cross", "stick"} },    
        { target = "Clap",  rank = 22, patterns = {"clap", "cp", "hand", "snap"} },
        
        -- 3. HATS (Timekeepers)
        { target = "Hat",   rank = 30, patterns = {"hat", "hh", "closed", "open", "pedal"} },
        
        -- 4. TOMS & CYMBALS
        { target = "Tom",   rank = 40, patterns = {"tom", "floor", "rack"} },
        { target = "Ride",  rank = 50, patterns = {"ride", "bell"} },             
        { target = "Crash", rank = 60, patterns = {"crash", "splash", "china"} }, 
        
        -- 5. PERC & BASS
        { target = "Perc",  rank = 70, patterns = {"perc", "shaker", "tamb", "bongo", "conga", "cowbell"} },
        { target = "Bass",  rank = 80, patterns = {"808", "sub"} } 
    }

    local passthrough_folders = {
        ["Transient"] = true, ["Sustained"] = true,
        ["transient"] = true, ["sustained"] = true
    }
    -- =========================================================

    local count_sel_tracks = reaper.CountSelectedTracks(0)
    if count_sel_tracks == 0 then return end

    -- Save original selection to restore later (optional, but nice)
    local original_selection = {}
    for i = 0, count_sel_tracks - 1 do
        table.insert(original_selection, reaper.GetSelectedTrack(0, i))
    end

    local track_data = {}         
    local type_counts = {}        
    local parent_groups = {}      

    -- =========================================================
    -- PASS 1: ANALYZE & RANK
    -- =========================================================
    for i = 0, count_sel_tracks - 1 do
        local track = reaper.GetSelectedTrack(0, i)
        local parent = reaper.GetParentTrack(track)
        
        if parent then
            -- 1. Context
            local _, parent_name = reaper.GetSetMediaTrackInfo_String(parent, "P_NAME", "", false)
            local parent_guid = reaper.GetTrackGUID(parent) 
            
            if passthrough_folders[parent_name] then
                local grandparent = reaper.GetParentTrack(parent)
                if grandparent then
                    local _, gp_name = reaper.GetSetMediaTrackInfo_String(grandparent, "P_NAME", "", false)
                    parent_name = gp_name
                else
                    parent_name = "Instruments"
                end
            end
            
            local clean_parent = parent_name
            if strip_spaces then clean_parent = clean_parent:gsub("%s+", "") end
            
            if clean_parent ~= "" then
                -- 2. Identify & Rank
                local _, current_name = reaper.GetSetMediaTrackInfo_String(track, "P_NAME", "", false)
                local lower_name = string.lower(current_name)
                
                local detected_type = nil
                local sort_rank = 100 -- Default rank (Bottom)

                for _, item in ipairs(drum_map) do
                    for _, pattern in ipairs(item.patterns) do
                        if string.find(lower_name, pattern) then
                            detected_type = item.target
                            sort_rank = item.rank
                            break
                        end
                    end
                    if detected_type then break end
                end

                -- 3. Base Name Logic
                local base_name = ""
                if detected_type then
                    base_name = detected_type
                else
                    -- Custom Name Preservation Logic
                    local temp_name = current_name
                    local sep_start, sep_end = string.find(temp_name, separator)
                    if sep_start then
                        local potential_prefix = string.sub(temp_name, 1, sep_start - 1)
                        if potential_prefix ~= clean_parent then
                            temp_name = string.sub(temp_name, sep_end + 1)
                        end
                    end
                    local esc_parent = clean_parent:gsub("[%(%)%.%%%+%-%*%?%[%]%^%$]", "%%%1")
                    local pattern = "^" .. esc_parent .. separator
                    temp_name = string.gsub(temp_name, pattern, "")
                    base_name = temp_name
                end

                -- 4. Count
                if not type_counts[clean_parent] then type_counts[clean_parent] = {} end
                if not type_counts[clean_parent][base_name] then type_counts[clean_parent][base_name] = 0 end
                type_counts[clean_parent][base_name] = type_counts[clean_parent][base_name] + 1

                -- 5. Store
                table.insert(track_data, {
                    track = track,
                    parent_clean = clean_parent,
                    parent_guid = parent_guid,
                    base_name = base_name,
                    rank = sort_rank,
                    original_name = current_name
                })
                
                if not parent_groups[parent_guid] then parent_groups[parent_guid] = {} end
            end
        end
    end

    -- =========================================================
    -- PASS 2: RENAME
    -- =========================================================
    local running_counts = {}

    for _, data in ipairs(track_data) do
        local p_name = data.parent_clean
        local b_name = data.base_name
        
        if not running_counts[p_name] then running_counts[p_name] = {} end
        if not running_counts[p_name][b_name] then running_counts[p_name][b_name] = 0 end
        running_counts[p_name][b_name] = running_counts[p_name][b_name] + 1
        
        local current_run = running_counts[p_name][b_name]
        local total_instances = type_counts[p_name][b_name]
        
        local final_suffix = b_name
        
        if total_instances > 1 then
            local num_str = tostring(current_run)
            if use_padding and current_run < 10 then num_str = "0" .. num_str end
            final_suffix = final_suffix .. " " .. num_str
        end
        
        local final_full_name = p_name .. separator .. final_suffix
        reaper.GetSetMediaTrackInfo_String(data.track, "P_NAME", final_full_name, true)
        
        data.final_name_for_sort = final_full_name
        table.insert(parent_groups[data.parent_guid], data)
    end

    -- =========================================================
    -- PASS 3: FORCE HIERARCHICAL SORT
    -- =========================================================
    
    for guid, group in pairs(parent_groups) do
        -- 1. Sort the internal table first
        table.sort(group, function(a, b) 
            if a.rank ~= b.rank then
                return a.rank < b.rank 
            else
                return a.final_name_for_sort < b.final_name_for_sort
            end
        end)
        
        -- 2. Find Insertion Point (The topmost track index in this folder group)
        local start_index = 99999999
        for _, item in ipairs(group) do
            local idx = reaper.GetMediaTrackInfo_Value(item.track, "IP_TRACKNUMBER")
            if idx < start_index then start_index = idx end
        end
        
        -- 3. Execute The Physical Move
        -- We use 'ReorderSelectedTracks' which is more robust than SetMediaTrackInfo
        for k, item in ipairs(group) do
            -- A. Select ONLY the current track we want to move
            reaper.SetOnlyTrackSelected(item.track)
            
            -- B. Calculate target index (1-based)
            local target_idx = start_index + k - 1
            
            -- C. Force Move
            -- Note: SetMediaTrackInfo with IP_TRACKNUMBER is generally safe if we do it one by one
            -- in a strictly sorted order.
            reaper.SetMediaTrackInfo_Value(item.track, "IP_TRACKNUMBER", target_idx)
        end
    end

    -- Restore Selection
    reaper.Main_OnCommand(40297, 0) -- Unselect all
    for _, t in ipairs(original_selection) do
        reaper.SetTrackSelected(t, true)
    end

    reaper.Undo_EndBlock("Organize Drums (Force Sort)", -1)
end

main()
reaper.PreventUIRefresh(-1)
reaper.UpdateArrange()
