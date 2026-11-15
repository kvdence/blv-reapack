-- @description BLV Clean up FX names in focused chain
-- @author BLV
-- @version 1.0.0
-- @about
--   Tidies the plug-in names in the FX chain you are looking at: drops prefixes such as "VST3:" and "AU:", maker names in brackets and UADx tags. Names you renamed yourself are left alone.
--   Copyright (c) 2026 BLV. All rights reserved. Free to use. You may not copy, modify, repackage or redistribute this software.

-- 1. Targets the Focused FX Chain (The window you are looking at).
-- 2. Scans ALL plugins in that chain.
-- 3. SAFETY: Only renames plugins that look "dirty" (Prefixes, UADx, Developer suffixes).
-- 4. IGNORES plugins you have already manually renamed.

function Msg(str)
    reaper.ShowConsoleMsg(tostring(str) .. "\n")
end

function IsDirty(name)
    -- Check if name starts with a known messy prefix
    if name:match("^VST") or name:match("^AU:") or name:match("^JS:") or name:match("^CLAP:") or name:match("^DX:") then
        return true
    end
    -- NEW: Check for UADx or UAD
    if name:match("UADx") or name:match("UAD%s") then
        return true
    end
    -- Check if it has the developer suffix (e.g. " (FabFilter)")
    if name:match("%s?%(.+%)$") then
        return true
    end
    return false
end

function CleanFXName(name)
    -- 1. Strip the Type Prefix (VST3:, JS:, etc.)
    local cleaned = name:gsub("^%w+%d?:%s?", "") 
    
    -- 2. NEW: Strip UADx / UAD
    -- We replace them with an empty string
    cleaned = cleaned:gsub("UADx%s?", "")
    cleaned = cleaned:gsub("UAD%s?", "")

    -- 3. Strip the (Developer) Suffix
    cleaned = cleaned:gsub("%s?%(.+%)$", "")
    
    -- 4. Trim and Cleanup
    -- Collapse double spaces that might result from removing words in the middle
    cleaned = cleaned:gsub("%s+", " ") 
    -- Trim leading/trailing whitespace
    cleaned = cleaned:match("^%s*(.-)%s*$")
    
    return cleaned
end

function Main()
    reaper.ClearConsole()
    reaper.Undo_BeginBlock()

    -- 1. Get Focused Window
    -- retval: 1=TrackFX, 2=ItemFX
    local retval, track_idx, item_idx, fx_idx = reaper.GetFocusedFX()

    if retval ~= 1 then
        Msg("Error: No FX window focused.\nPlease click inside your FX Chain window first.")
        return
    end

    -- 2. Get the Track
    local track
    if track_idx == 0 then
        track = reaper.GetMasterTrack(0)
    else
        track = reaper.GetTrack(0, track_idx - 1)
    end

    local fx_count = reaper.TrackFX_GetCount(track)
    local changes = 0

    -- 3. Loop through ALL plugins in this chain
    for i = 0, fx_count - 1 do
        local _, current_name = reaper.TrackFX_GetFXName(track, i, "")
        
        -- SMART CHECK: Only clean if it looks like a default system name
        if IsDirty(current_name) then
            local new_name = CleanFXName(current_name)
            
            if new_name ~= current_name then
                reaper.TrackFX_SetNamedConfigParm(track, i, "renamed_name", new_name)
                Msg("Cleaned: " .. new_name)
                changes = changes + 1
            end
        else
            -- Msg("Skipped (Custom Name): " .. current_name)
        end
    end

    if changes > 0 then
        Msg("\nSuccess! Cleaned " .. changes .. " plugins in this chain.")
    else
        Msg("\nNo 'dirty' plugins found in this chain.")
    end

    reaper.Undo_EndBlock("BLV: clean up FX names", -1)
end

Main()
