-- @description BLV Set project end and render range to cursor
-- @author BLV
-- @version 1.0.0
-- @about
--   After asking, ends the project at the edit cursor and sets the render range from the start to the cursor.
--   Requires: SWS (install from ReaPack).
--   Copyright (c) 2026 BLV. All rights reserved. Free to use. You may not copy, modify, repackage or redistribute this software.

local SCRIPT_NAME = "Set Project Limit and Render Range to Cursor"
local PROJECT = 0

local function format_time(seconds)
  local formatted = reaper.format_timestr(seconds, "")

  if formatted and formatted ~= "" then
    return formatted
  end

  return string.format("%.6f seconds", seconds)
end

local function require_sws()
  if reaper.APIExists("SNM_SetDoubleConfigVar")
      and reaper.APIExists("SNM_SetIntConfigVar") then
    return true
  end

  reaper.MB(
    "This script needs SWS Extensions to change the project length limit.",
    SCRIPT_NAME,
    0
  )
  return false
end

local function confirm(cursor_pos)
  local cursor_text = format_time(cursor_pos)
  local message = "Set project and render limits to the edit cursor?\n\n"
      .. "Edit cursor: " .. cursor_text .. "\n\n"
      .. "This will:\n"
      .. "- Enable \"Limit project length\"\n"
      .. "- Set the project length limit to " .. cursor_text .. "\n"
      .. "- Set Render Bounds to \"Custom time range\"\n"
      .. "- Set render Start to 0:00.000 and End to " .. cursor_text

  return reaper.MB(message, SCRIPT_NAME, 4) == 6
end

local function apply(cursor_pos)
  reaper.Undo_BeginBlock2(PROJECT)

  reaper.SNM_SetIntConfigVar("stopprojlen", 1)
  reaper.SNM_SetDoubleConfigVar("projmaxlen", cursor_pos)

  reaper.GetSetProjectInfo(PROJECT, "RENDER_BOUNDSFLAG", 0, true)
  reaper.GetSetProjectInfo(PROJECT, "RENDER_STARTPOS", 0, true)
  reaper.GetSetProjectInfo(PROJECT, "RENDER_ENDPOS", cursor_pos, true)

  reaper.UpdateTimeline()
  reaper.MarkProjectDirty(PROJECT)
  reaper.Undo_EndBlock2(
    PROJECT,
    "Set project length limit and render range to edit cursor",
    -1
  )
end

if not require_sws() then
  return
end

local cursor_pos = reaper.GetCursorPositionEx(PROJECT)

if cursor_pos <= 0 then
  reaper.MB(
    "Move the edit cursor later than 0:00.000 before running this script.",
    SCRIPT_NAME,
    0
  )
  return
end

if confirm(cursor_pos) then
  apply(cursor_pos)
end

reaper.defer(function() end)
