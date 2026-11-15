-- @description BLV Exclusive solo click mode
-- @author BLV
-- @version 1.0.0
-- @about
--   A toggle: while it is on, clicking a track's solo button solos only that track.
--   Requires: js_ReaScriptAPI (install from ReaPack).
--   Copyright (c) 2026 BLV. All rights reserved. Free to use. You may not copy, modify, repackage or redistribute this software.

------------------------------------------------------------
-- CONFIG
------------------------------------------------------------
local SCRIPT_KEY = "JP_ExclusiveSoloClickMode"
local DEBUG = false
local ONE_SHOT = false -- set true if you want the mode to auto-exit after one successful exclusive-solo click
local POPUP_ON_ERROR = true

------------------------------------------------------------
-- ACTION CONTEXT / TOOLBAR TOGGLE STATE
------------------------------------------------------------
local _, _, sectionID, cmdID = reaper.get_action_context()

local function set_toggle_state(state)
  if cmdID and cmdID >= 0 and sectionID and sectionID >= 0 then
    reaper.SetToggleCommandState(sectionID, cmdID, state)
    reaper.RefreshToolbar2(sectionID, cmdID)
  end
end

------------------------------------------------------------
-- LOGGING / ERRORS
------------------------------------------------------------
local function log(msg)
  if DEBUG then
    reaper.ShowConsoleMsg(tostring(msg) .. "\n")
  end
end

local function popup(msg)
  if POPUP_ON_ERROR then
    reaper.MB(tostring(msg), "Exclusive Solo Click Mode", 0)
  end
end

local function hard_fail(msg)
  log("ERROR: " .. tostring(msg))
  popup(msg)
end

------------------------------------------------------------
-- EXTSTATE CONTROL
------------------------------------------------------------
local function is_running()
  return reaper.GetExtState(SCRIPT_KEY, "RUNNING") == "1"
end

local function mark_running(state)
  reaper.SetExtState(SCRIPT_KEY, "RUNNING", state and "1" or "0", false)
end

local function stop_requested()
  return reaper.GetExtState(SCRIPT_KEY, "STOP") == "1"
end

local function request_stop()
  reaper.SetExtState(SCRIPT_KEY, "STOP", "1", false)
end

------------------------------------------------------------
-- REQUIREMENTS
------------------------------------------------------------
if not reaper.APIExists("JS_Mouse_GetState") then
  hard_fail(
    "This script requires js_ReaScriptAPI.\n\n" ..
    "Install it with ReaPack, restart REAPER, then run the script again."
  )
  return
end

------------------------------------------------------------
-- TOGGLE BEHAVIOR
------------------------------------------------------------
-- If already running, this invocation simply asks the existing instance to stop.
if is_running() then
  request_stop()
  return
end

mark_running(true)
reaper.SetExtState(SCRIPT_KEY, "STOP", "0", false)
set_toggle_state(1)

local function cleanup()
  mark_running(false)
  reaper.SetExtState(SCRIPT_KEY, "STOP", "0", false)
  set_toggle_state(0)
end

reaper.atexit(cleanup)

------------------------------------------------------------
-- SOLO HELPERS
------------------------------------------------------------
local function is_track_panel_hit(info)
  if not info then return false end
  return info:match("^tcp") or info:match("^mcp")
end

local function is_solo_hit(info)
  if not info then return false end
  return info:match("^tcp%.solo")
      or info:match("^mcp%.solo")
      or info:match("%.solo")
end

local function is_track_soloed(track)
  if not track then return false end
  return (reaper.GetMediaTrackInfo_Value(track, "I_SOLO") or 0) > 0
end

local function clear_track_solo(track)
  if not track then return end
  local rv = reaper.SetTrackUISolo(track, 0, 0)
  if rv == -1 then
    reaper.SetMediaTrackInfo_Value(track, "I_SOLO", 0)
  end
end

local function set_track_plain_solo(track)
  if not track then return end
  -- 2 = explicit non-SIP solo
  local rv = reaper.SetTrackUISolo(track, 2, 0)
  if rv == -1 then
    reaper.SetMediaTrackInfo_Value(track, "I_SOLO", 1)
  end
end

local function exclusive_solo(target)
  if not target then return end

  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  local master = reaper.GetMasterTrack(0)
  if master and master ~= target then
    clear_track_solo(master)
  end

  local track_count = reaper.CountTracks(0)
  for i = 0, track_count - 1 do
    local tr = reaper.GetTrack(0, i)
    if tr ~= target then
      clear_track_solo(tr)
    end
  end

  set_track_plain_solo(target)

  reaper.TrackList_AdjustWindows(false)
  reaper.UpdateArrange()

  reaper.PreventUIRefresh(-1)
  reaper.Undo_EndBlock("Exclusive solo clicked track", -1)
end

------------------------------------------------------------
-- MOUSE WATCHER
------------------------------------------------------------
local prev_state = reaper.JS_Mouse_GetState(1) or 0
local prev_down = (prev_state & 1) == 1

local press_track = nil
local press_info = ""
local press_was_solo = false
local press_explicit_solo_hit = false

local function reset_press_state()
  press_track = nil
  press_info = ""
  press_was_solo = false
  press_explicit_solo_hit = false
end

local function tick()
  if stop_requested() then
    return
  end

  local mouse_state = reaper.JS_Mouse_GetState(1) or 0
  local mouse_down = (mouse_state & 1) == 1

  -- Mouse down: remember what was clicked
  if mouse_down and not prev_down then
    local x, y = reaper.GetMousePosition()
    local tr, info = reaper.GetThingFromPoint(x, y)
    info = info or ""

    if tr and is_track_panel_hit(info) then
      press_track = tr
      press_info = info
      press_was_solo = is_track_soloed(tr)
      press_explicit_solo_hit = is_solo_hit(info)

      log("MOUSEDOWN hit info: " .. info)
      log("MOUSEDOWN explicit solo hit: " .. tostring(press_explicit_solo_hit))
      log("MOUSEDOWN solo before click: " .. tostring(press_was_solo))
    else
      reset_press_state()
    end
  end

  -- Mouse up: decide whether that click was a solo-button click
  if (not mouse_down) and prev_down then
    if press_track then
      local x, y = reaper.GetMousePosition()
      local release_track, release_info = reaper.GetThingFromPoint(x, y)
      release_info = release_info or ""

      local released_on_same_track_panel =
        (release_track == press_track) and is_track_panel_hit(release_info)

      if released_on_same_track_panel then
        local now_solo = is_track_soloed(press_track)

        -- Two ways to recognize a solo-button click:
        -- 1) REAPER explicitly reports .solo in hit info
        -- 2) fallback: the click changed the track's solo state
        local solo_click_detected =
          press_explicit_solo_hit or (press_was_solo ~= now_solo)

        log("MOUSEUP hit info: " .. release_info)
        log("MOUSEUP same track panel: " .. tostring(released_on_same_track_panel))
        log("MOUSEUP solo after click: " .. tostring(now_solo))
        log("SOLO click detected: " .. tostring(solo_click_detected))

        if solo_click_detected then
          exclusive_solo(press_track)

          if ONE_SHOT then
            request_stop()
          end
        end
      end
    end

    reset_press_state()
  end

  prev_down = mouse_down
end

local function loop()
  local ok, err = xpcall(tick, debug.traceback)
  if not ok then
    log("LUA ERROR:\n" .. tostring(err))
    popup("Script error:\n\n" .. tostring(err) .. "\n\nCheck the ReaScript console if DEBUG=true.")
    request_stop()
  end

  if not stop_requested() then
    reaper.defer(loop)
  end
end

loop()
