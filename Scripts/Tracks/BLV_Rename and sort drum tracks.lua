-- @description BLV Rename and sort drum tracks
-- @author BLV
-- @version 1.0.0
-- @about
--   Renames drum tracks to standard names (kick, snare, hats, and so on) and sorts them.
--   Copyright (c) 2026 BLV. All rights reserved. Free to use. You may not copy, modify, repackage or redistribute this software.

function main()
    reaper.Undo_BeginBlock()
    reaper.PreventUIRefresh(1)

    -- =========================================================
    -- 1. CONFIGURATION
    -- =========================================================
    local use_padding = false   -- false: "Snare 1" | true: "Snare 01"

    -- DRUM HIERARCHY (The "Rank" determines the sort order)
    local drum_map = {
        -- Priority 1: Low End
        { target = "Kick",  rank = 10, patterns = {"kick", "bd", "bassdrum"} },
        
        -- Priority 2: Backbeat
        { target = "Snare", rank = 20, patterns = {"snare", "sd", "sidestick"} }, 
        { target = "Rim",   rank = 21, patterns = {"rim", "cross", "stick"} },    
        { target = "Clap",  rank = 22, patterns = {"clap", "cp", "hand", "snap"} },
        
        -- Priority 3: Timekeepers
        { target = "Hat",   rank = 30, patterns = {"hat", "hh", "closed", "open", "pedal"} },
        
        -- Priority 4: Fills & Cymbals
        { target = "Tom",   rank = 40, patterns = {"tom", "floor", "rack"} },
        { target = "Ride",  rank = 50, patterns = {"ride", "bell"} },             
        { target = "Crash", rank = 60, patterns = {"crash", "splash", "china"} }, 
        
        -- Priority 5: Percussion & 808s
        { target = "Perc",  rank = 70, patterns = {"perc", "shaker", "tamb", "bongo", "conga", "cowbell"} },
        { target = "Bass",  rank = 80, patterns = {"808", "sub"} } 
    }

    -- PASSTHROUGH FOLDERS (Ignore these names and look at the parent above)
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
    -- PASS 1: ANALYZE & CLEAN NAMES
    -- =========================================================
    for i = 0, count_sel_tracks - 1 do
        local track = reaper.GetSelectedTrack(0, i)
        local parent = reaper.GetParentTrack(track)
        
        if parent then
            -- Identify Parent (for grouping only)
            local _, parent_name = reaper.GetSetMediaTrackInfo_String(parent, "P_NAME", "", false)
            local parent_guid = reaper.GetTrackGUID(parent) 
            
            -- Handle "Transient/Sustained" Passthrough
            if passthrough_folders[parent_name] then
                local grandparent = reaper.GetParentTrack(parent)
                if grandparent then
                    local _, gp_name = reaper.GetSetMediaTrackInfo_String(grandparent, "P_NAME", "", false)
                    parent_name = gp_name
                end
            end
            
            local clean_parent = parent_name:gsub("%s+", "") -- Remove spaces for pattern matching
            
            -- Detect Instrument Type
            local _, current_name = reaper.GetSetMediaTrackInfo_String(track, "P_NAME", "", false)
            local lower_name = string.lower(current_name)
            
            local detected_type = nil
            local sort_rank = 100 -- Default rank (Bottom of the list)

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

            -- Determine the "Base Name" (e.g., "Snare")
            local base_name = ""
            if detected_type then
                base_name = detected_type
            else
                -- If it's an unknown drum, try to clean it up but keep the name
                local temp_name = current_name
                -- Strip existing parent prefixes just in case (e.g. remove "Drums_" from "Drums_Distro")
                if clean_parent ~= "" then
                    local esc_parent = clean_parent:gsub("[%(%)%.%%%+%-%*%?%[%]%^%$]", "%%%1")
                    local match = string.match(temp_name, "^" .. esc_parent .. "_(.*)")
                    if match then temp_name = match end
                end
                base_name = temp_name
            end

            -- Count instances for numbering
            if not type_counts[parent_guid] then type_counts[parent_guid] = {} end
            if not type_counts[parent_guid][base_name] then type_counts[parent_guid][base_name] = 0 end
            type_counts[parent_guid][base_name] = type_counts[parent_guid][base_name] + 1

            -- Store data
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

    -- =========================================================
    -- PASS 2: APPLY NAMES (Conditionals)
    -- =========================================================
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
        
        -- Add Number ONLY if there are multiple of the same type
        if total_instances > 1 then
            local num_str = tostring(current_run)
            if use_padding and current_run < 10 then num_str = "0" .. num_str end
            final_name = final_name .. " " .. num_str
        end
        
        reaper.GetSetMediaTrackInfo_String(data.track, "P_NAME", final_name, true)
        
        -- Store the final name for the sorting tie-breaker
        data.final_name_for_sort = final_name
        
        -- Add to the group list for the next pass
        table.insert(parent_groups[p_guid], data)
    end

    -- =========================================================
    -- PASS 3: NATIVE SORTING (ReorderSelectedTracks)
    -- =========================================================
    
    for guid, group in pairs(parent_groups) do
        -- A. Sort the internal Lua list first
        table.sort(group, function(a, b) 
            if a.rank ~= b.rank then
                return a.rank < b.rank -- Primary: Rank (Kick < Snare)
            else
                return a.final_name_for_sort < b.final_name_for_sort -- Secondary: Name (Snare 1 < Snare 2)
            end
        end)
        
        -- B. Find the insertion point (Topmost track index in this specific folder group)
        local top_index = 99999999
        
        for _, item in ipairs(group) do
            local idx = reaper.GetMediaTrackInfo_Value(item.track, "IP_TRACKNUMBER")
            if idx < top_index then top_index = idx end
        end
        
        -- C. Execute the Physical Move in REAPER
        for k, item in ipairs(group) do
            -- Target index is where we WANT it to be (top_index + 0, + 1, + 2...)
            local target_idx = top_index + k - 1
            
            -- Get its CURRENT index (because previous moves shifted things)
            local current_idx = reaper.GetMediaTrackInfo_Value(item.track, "IP_TRACKNUMBER")
            
            -- If it's not in the right spot, move it.
            if current_idx ~= target_idx then
                reaper.SetOnlyTrackSelected(item.track)
                reaper.ReorderSelectedTracks(target_idx - 1, 0) -- Native Function: (IndexBefore, MakeFolder?)
            end
        end
    end

    -- Restore selection to all processed tracks
    reaper.Main_OnCommand(40297, 0) -- Unselect all
    for _, data in ipairs(track_data) do
        reaper.SetTrackSelected(data.track, true)
    end

    reaper.Undo_EndBlock("Rename and Sort Drum Tracks", -1)
end

main()
reaper.PreventUIRefresh(-1)
reaper.UpdateArrange()
