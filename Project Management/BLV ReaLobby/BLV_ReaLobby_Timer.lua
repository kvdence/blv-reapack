-- @noindex
--
-- BLV ReaLobby's time counter: runs in the background while REAPER is open
-- and adds up the time worked on each song (realobby/timelog.lua says what
-- counts). ReaLobby starts it when its window opens, unless "Count time
-- worked on each song" is off in Settings; one copy runs per REAPER.
local source = debug.getinfo(1, "S").source:gsub("^@", "")
local here = source:match("^(.*)[/\\][^/\\]*$") or "."
package.path = here .. "/?.lua;" .. package.path

local instance = require("realobby.instance")
local timelog = require("realobby.timelog")
local versions = require("realobby.versions")
local B = require("realobby.bridge")

-- Running it again restarts it (what was counted is saved first) instead of
-- REAPER asking what to do.
if reaper.set_action_options then reaper.set_action_options(1 | 2) end

local single = instance.new({ get = reaper.GetExtState, set = reaper.SetExtState, now = reaper.time_precise,
  section = B.TIMER_SECTION, fresh = B.TIMER_FRESH })
if not single:claim() then return end
reaper.SetExtState(B.TIMER_SECTION, "stop", "", false)

local dir = reaper.GetResourcePath() .. "/Data/BLV ReaLobby"
local path = dir .. "/time.dat"
local counter = timelog.counter()
local next_tick, next_flush = 0, reaper.time_precise() + timelog.FLUSH_EVERY
local made_dir = false
local last_key = nil

local function flush()
  local deltas = counter:take()
  if next(deltas) == nil then return end
  if not made_dir then
    reaper.RecursiveCreateDirectory(dir, 0)
    made_dir = true
  end
  local ok, err = timelog.add(path, deltas)
  if not ok then
    reaper.ShowConsoleMsg("BLV ReaLobby: could not save " .. path .. ": " .. tostring(err) .. "\n")
  end
end

local function active_key()
  local proj, file = reaper.EnumProjects(-1)
  if not proj or not file or file == "" then return nil, proj end
  return B.normalize((versions.key(file))), proj
end

local function signature(proj, now)
  local x, y = reaper.GetMousePosition()
  local playing = (reaper.GetPlayStateEx(proj) & 5) ~= 0   -- playing or recording
  return string.format("%d,%d,%d,%s", x, y, reaper.GetProjectStateChangeCount(proj),
    playing and string.format("%.0f", now) or "")
end

local function loop()
  local now = reaper.time_precise()
  if reaper.GetExtState(B.TIMER_SECTION, "stop") == "1" then
    flush()
    single:release()
    return
  end
  if now >= next_tick then
    next_tick = now + 1
    single:beat()
    local key, proj = active_key()
    -- Another song (or none) is now active: save the last one's time at
    -- once, so a song closed and then renamed in ReaLobby keeps all of it.
    if key ~= last_key then
      last_key = key
      flush()
    end
    counter:tick(now, key, proj and signature(proj, now) or "")
  end
  if now >= next_flush then
    next_flush = now + timelog.FLUSH_EVERY
    flush()
  end
  reaper.defer(loop)
end

reaper.atexit(function()
  flush()
  single:release()
end)
reaper.defer(loop)
