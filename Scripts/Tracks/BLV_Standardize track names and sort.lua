-- @description BLV Standardize track names and sort
-- @author BLV
-- @version 1.0.0
-- @about
--   Tidies track names to one standard and sorts them.
--   Copyright (c) 2026 BLV. All rights reserved. Free to use. You may not copy, modify, repackage or redistribute this software.

function main()
    reaper.Undo_BeginBlock()
    reaper.PreventUIRefresh(1)

    -- =========================================================
    -- CONFIGURATION
    -- =========================================================
    local use_padding = false   -- false: "Snare 1" | true: "Snare 01"

    -- HIERARCHY MAP
    local drum_map = {
        { target = "Kick",  rank = 10, patterns = {"kick", "bd", "bassdrum"} },
        { target = "Snare", rank = 20, patterns = {"snare", "sd", "sidestick"} }, 
        { target = "Rim",   rank = 21, patterns = {"rim", "cross", "stick"} },    
        { target = "Clap",  rank = 22, patterns = {"clap", "cp", "hand", "snap"} },
        { target = "Hat",   rank = 30, patterns = {"hat", "hh", "closed", "open", "pedal"} },
        { target = "Tom",   rank = 40, patterns = {"tom", "floor", "rack"} },
        { target = "Ride",  rank = 50, patterns = {"ride", "bell"} },             
        { target = "Crash", rank = 60, patterns = {"crash", "splash", "china"} }, 
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

    local track_data = {}         
    local type_counts = {}        
    local parent_groups = {}      

    -- =========================================================
    -- PASS 1: ANALYZE & RENAME
    -- =========================================================
    for i = 0, count_sel_tracks - 1 do
        local track = reaper.GetSelectedTrack(0, i)
        local parent = reaper.GetParentTrack(track)
        
        if parent then
            -- Identify Parent Group
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
            
            local clean_parent = parent_name:gsub("%s+", "")
            
            if clean_parent ~= "" then
                -- Analyze Name
                local _, current_name = reaper.GetSetMediaTrackInfo_String(track, "P_NAME", "", false)
                local lower_name = string.lower(current_name)
                
                local detected_type = nil
                local sort_rank = 100 

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

                -- Determine Base Name
                local base_name = ""
                if detected_type then
                    base_name = detected_type
                else
                    local temp_name = current_name
                    local esc_parent = clean_parent:gsub("[%(%)%.%%%+%-%*%?%[%]%^%$]", "%%%1")
                    local match = string.match(temp_name, "^" .. esc_parent .. "_(.*)")
                    if match then temp_name = match end
                    match = string.match(temp_name, "^" .. esc_parent .. "%s+(.*)")
                    if match then temp_name = match end
                    base_name = temp_name
                end

                -- Count
                if not type_counts[parent_guid] then type_counts[parent_guid] = {} end
                if not type_counts[parent_guid][base_name] then type_counts[parent_guid][base_name] = 0 end
                type_counts[parent_guid][base_name] = type_counts[parent_guid][base_name] + 1

                -- Store
                table.insert(track_data, {
                    track = track,
                    parent_guid = parent_guid,
                    base_name = base_name,
                    rank = sort_rank,
                    original_name = current_name
                })
                
                if not parent_groups[parent_guid] then parent_groups[parent_guid] = {} end
            end
        end
    end

    -- Apply Names
    local running_counts = {}
    for _, data in ipairs(track_data) do
        local p_guid = data.parent_guid
        local b_name = data.base_name
        
        if not running_counts[p_guid] then running_counts[p_guid] = {} end
        if not running_counts[p_guid][b_name] then running_counts[p_guid][b_name] = 0 end
        running_counts[p_guid][b_name] = running_counts[p_guid][b_name] + 1
        
        local current_run = running_counts[p_guid][b_name]
        local total_instances = type_counts[p_guid][b_name]
        
        local final_name = b_name
        if total_instances > 1 then
            local num_str = tostring(current_run)
            if use_padding and current_run < 10 then num_str = "0" .. num_str end
            final_name = final_name .. " " .. num_str
        end
        
        reaper.GetSetMediaTrackInfo_String(data.track, "P_NAME", final_name, true)
        data.final_name_for_sort = final_name
        table.insert(parent_groups[p_guid], data)
    end

    -- =========================================================
    -- PASS 2: THE REORDER LOGIC (Native Only)
    -- =========================================================
    
    for guid, group in pairs(parent_groups) do
        -- 1. Sort the internal list
        table.sort(group, function(a, b) 
            if a.rank ~= b.rank then
                return a.rank < b.rank 
            else
                return a.final_name_for_sort < b.final_name_for_sort
            end
        end)
        
        -- 2. Find the TOP track of the current selection in this folder
        local top_index = 99999999
        
        for _, item in ipairs(group) do
            local idx = reaper.GetMediaTrackInfo_Value(item.track, "IP_TRACKNUMBER")
            if idx < top_index then top_index = idx end
        end
        
        -- 3. Execute Move
        for k, item in ipairs(group) do
            local target_idx = top_index + k - 1
            
            -- Check current index
            local current_idx = reaper.GetMediaTrackInfo_Value(item.track, "IP_TRACKNUMBER")
            
            if current_idx ~= target_idx then
                -- ReorderSelectedTracks requires the track to be selected
                reaper.SetOnlyTrackSelected(item.track)
                reaper.ReorderSelectedTracks(target_idx - 1, 0) 
            end
        end
    end

    -- Restore selection so you can see what happened
    reaper.Main_OnCommand(40297, 0)
    for _, data in ipairs(track_data) do
        reaper.SetTrackSelected(data.track, true)
    end

    reaper.Undo_EndBlock("Standardize & Sort", -1)
end

main()
reaper.PreventUIRefresh(-1)
reaper.UpdateArrange()
