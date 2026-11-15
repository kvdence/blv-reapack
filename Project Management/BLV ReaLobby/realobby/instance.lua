-- One ReaLobby window per REAPER. Pure Lua: the entry script passes
-- reaper.GetExtState / SetExtState (not persisted) and reaper.time_precise.
--
-- The running window writes a heartbeat time each frame. A second start that
-- finds a heartbeat younger than FRESH seconds asks the running one to come
-- forward and quits; an older or missing heartbeat (a stopped or crashed
-- script) does not block.
local M = {}

M.SECTION = "BLV_ReaLobby"
M.FRESH = 3.0

-- opts.section and opts.fresh override M.SECTION and M.FRESH (the time
-- counter, BLV_ReaLobby_Timer.lua, keeps its own heartbeat).
function M.new(opts)
  local get, set, now = opts.get, opts.set, opts.now
  local SECTION, FRESH = opts.section or M.SECTION, opts.fresh or M.FRESH
  local I = {}
  local last   -- the heartbeat this window wrote last

  local function number(key)
    return tonumber(get(SECTION, key) or "")
  end

  -- true: this one runs; false: another is running (asked to come forward).
  function I:claim()
    local beat, t = number("heartbeat"), now()
    if beat and t >= beat and t - beat < FRESH then
      set(SECTION, "focus", tostring(t), false)
      return false
    end
    set(SECTION, "focus", "", false)
    self:beat()
    return true
  end

  function I:beat()
    last = tostring(now())
    set(SECTION, "heartbeat", last, false)
  end

  -- true once after another start asked this window to come forward.
  function I:focus_requested()
    if (get(SECTION, "focus") or "") == "" then return false end
    set(SECTION, "focus", "", false)
    return true
  end

  -- Clears only this window's own heartbeat: the script can keep running
  -- after its window closed (bringing FX online), and a window started
  -- meanwhile owns the heartbeat.
  function I:release()
    if last and get(SECTION, "heartbeat") == last then set(SECTION, "heartbeat", "", false) end
    last = nil
  end

  return I
end

return M
