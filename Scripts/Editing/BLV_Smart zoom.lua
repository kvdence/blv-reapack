-- @description BLV Smart zoom
-- @author BLV
-- @version 1.0.0
-- @about
--   Cycles the arrange view through set bar lengths, then fits the loop, the selected items, the region or the whole project.
--   Copyright (c) 2026 BLV. All rights reserved. Free to use. You may not copy, modify, repackage or redistribute this software.

-- =========================================================
-- USER CONFIGURATION
-- =========================================================

-- Define your cycle steps here (in Bars).
-- The script will cycle through these in order, then go to "Smart Max".
local ZOOM_LEVELS = { 1, 4, 8, 16, 32 }

-- If true, the script will automatically turn ON "Auto-View-Scroll" when 
-- zooming to the smallest level (ZOOM_LEVELS[1]), and turn it OFF for all other levels.
local AUTO_SCROLL_TIGHT = true 

local FALLBACK_LENGTH   = 300  -- 5 Mins (fallback for empty projects)
local SHOW_TOOLTIP      = true -- Show popup text?

-- =========================================================

function ShowTooltip(text)
    if not SHOW_TOOLTIP then return end
    local x, y = reaper.GetMousePosition()
    reaper.TrackCtl_SetToolTip(text, x + 15, y - 30, true)
end

-- Helper to Toggle Auto-Scroll (Command ID 40036)
function SetAutoScroll(enable)
    local state = reaper.GetToggleCommandState(40036)
    if enable then
        if state == 0 then reaper.Main_OnCommand(40036, 0) end
    else
        if state == 1 then reaper.Main_OnCommand(40036, 0) end
    end
end

-- =========================================================
-- MUSICAL MATH & TARGETING
-- =========================================================

function GetBarLength()
    -- Calculates the duration of 1 Bar in seconds at the current cursor position
    local cursor = reaper.GetCursorPosition()
    local idx = reaper.TimeMap2_timeToBeats(0, cursor) -- returns measures, beats, cml
    local current_measure = math.floor(idx)
    
    local start_of_bar = reaper.TimeMap2_beatsToTime(0, 0, current_measure)
    local end_of_bar   = reaper.TimeMap2_beatsToTime(0, 0, current_measure + 1)
    
    return end_of_bar - start_of_bar
end

function GetCurrentZoomInBars()
    local start_time, end_time = reaper.GetSet_ArrangeView2(0, false, 0, 0)
    local view_dur = end_time - start_time
    local one_bar = GetBarLength()
    return view_dur / one_bar
end

function GetProjectLimit()
    if not reaper.GetProjectStateChunk then return 0 end
    local success, retval, chunk = pcall(reaper.GetProjectStateChunk, 0, "", false)
    if success and chunk then
        local limit_min = chunk:match("PROJLEN (%d+)")
        if limit_min then return tonumber(limit_min) * 60 end
    end
    return 0
end

function GetRegionBounds(pos_check)
    local _, num_markers, num_regions = reaper.CountProjectMarkers(0)
    for i = 0, num_markers + num_regions - 1 do
        local retval, isrgn, pos, rgnend, name = reaper.EnumProjectMarkers(i)
        if isrgn and pos_check >= pos and pos_check <= rgnend then
            return true, pos, rgnend, name
        end
    end
    return false, 0, 0, ""
end

function GetSmartMaxTarget()
    local cursor = reaper.GetCursorPosition()

    -- PRIORITY 1: Time Selection (Loop Points)
    local t_start, t_end = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)
    if t_start ~= t_end then
        return (t_end - t_start), t_start, t_end, "Loop Selection"
    end

    -- PRIORITY 2: Selected Items
    local num_sel = reaper.CountSelectedMediaItems(0)
    if num_sel > 0 then
        local min_start = math.huge
        local max_end = 0
        for i = 0, num_sel - 1 do
            local item = reaper.GetSelectedMediaItem(0, i)
            local pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
            local len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
            if pos < min_start then min_start = pos end
            if (pos + len) > max_end then max_end = pos + len end
        end
        return (max_end - min_start) * 1.05, min_start, max_end, "Selection"
    end

    -- PRIORITY 3: Current Region
    local in_region, r_start, r_end, r_name = GetRegionBounds(cursor)
    if in_region then
        local len = r_end - r_start
        return len * 1.02, r_start, r_end, "Region: " .. r_name
    end

    -- PRIORITY 4: Project Limit
    local item_end_len = reaper.GetProjectLength(0)
    local setting_len = GetProjectLimit()
    local target = math.max(item_end_len, setting_len)
    if target == 0 then target = FALLBACK_LENGTH end
    
    return target + 1, 0, target, "Project End"
end

-- =========================================================
-- ZOOM EXECUTION
-- =========================================================

function CenterZoom(duration)
    local play_state = reaper.GetPlayState()
    local center_target_pos
    
    if play_state == 1 or play_state == 5 then
        center_target_pos = reaper.GetPlayPosition()
    else
        center_target_pos = reaper.GetCursorPosition()
    end
    
    local start_time, end_time = reaper.GetSet_ArrangeView2(0, false, 0, 0)
    local current_view_center = start_time + ((end_time - start_time) / 2)
    
    local final_center
    if (play_state == 1 or play_state == 5) then
        final_center = center_target_pos
    elseif center_target_pos >= start_time and center_target_pos <= end_time then
        final_center = center_target_pos
    else
        final_center = current_view_center
    end
    
    local new_start = final_center - (duration / 2)
    local new_end = final_center + (duration / 2)
    
    if new_start < 0 then
        new_start = 0
        new_end = duration
    end
    
    reaper.GetSet_ArrangeView2(0, true, 0, 0, new_start, new_end)
end

function main()
    -- 1. Get Musical Context
    local one_bar_sec = GetBarLength()
    local current_bars = GetCurrentZoomInBars()
    
    -- 2. Calculate Max Target
    local max_len_sec, max_start, max_end, type_label = GetSmartMaxTarget()
    local max_bars = max_len_sec / one_bar_sec
    local tolerance = 0.5 
    
    local target_sec = nil
    local target_bar_level = nil -- To track which level we picked
    local label = ""
    local is_max = false
    
    -- 3. Dynamic Cycle Logic
    for _, bars in ipairs(ZOOM_LEVELS) do
        -- Check if current zoom is tighter than this level
        if current_bars < (bars - tolerance) then
            target_sec = one_bar_sec * bars
            target_bar_level = bars
            label = "View: " .. bars .. " Bars"
            break 
        end
    end
    
    -- 4. Check Smart Max / Reset
    if not target_sec then
        if current_bars < (max_bars - tolerance) then
            target_sec = max_len_sec
            is_max = true
            target_bar_level = -1 -- Mark as Max
            label = "View: " .. type_label
        else
            -- Reset to first level
            target_sec = one_bar_sec * ZOOM_LEVELS[1]
            target_bar_level = ZOOM_LEVELS[1]
            label = "Reset: " .. ZOOM_LEVELS[1] .. " Bar"
        end
    end
    
    -- 5. Auto Scroll Logic
    if AUTO_SCROLL_TIGHT then
        if target_bar_level == ZOOM_LEVELS[1] then
            -- Force Scroll ON for smallest level
            SetAutoScroll(true)
        else
            -- Force Scroll OFF for all other levels (Standard behavior)
            SetAutoScroll(false)
        end
    end

    -- 6. Execute Zoom
    if is_max then
        local buffer = target_sec * 0.01
        if max_start == 0 then
            reaper.GetSet_ArrangeView2(0, true, 0, 0, 0, max_end)
        else
            reaper.GetSet_ArrangeView2(0, true, 0, 0, max_start - buffer, max_end + buffer)
        end
    else
        CenterZoom(target_sec)
    end
    
    ShowTooltip(label)
    reaper.UpdateArrange()
end

reaper.defer(main)
