-- "Bring FX online after load": the project opens with every FX offline,
-- then the FX that were online in the saved file come back online a few at a
-- time, one time budget per defer frame. Pure Lua (no reaper.*): the bridge
-- supplies the live project and does the REAPER calls.
--
-- In a portable REAPER 7.79, TrackFX_GetOffline reports every FX offline
-- right after an "fxoffline:" open, the ones saved offline included, so the
-- saved state comes from the project file (rpp.fx_chains) read before the
-- open. Each FX is found by its GUID (the file's FXID) when it is brought
-- online, never by position, so an FX moved, added or removed meanwhile can
-- never bring a saved-offline FX online. When in doubt an FX stays offline.
local M = {}

M.BUDGET = 0.008          -- seconds per defer frame while the window is open
M.BUDGET_CLOSED = 0.028   -- with the window closed (the user waits on the load anyway)
M.STALE = 2.0             -- seconds after which a progress note is not shown
M.DEAD = 10.0             -- seconds without progress after which a pass counts as stopped
M.INTERRUPTED = "interrupted"
M.INTERRUPTED_NOTE = "Some plug-ins may still be offline from the last open."

-- chains: rpp.fx_chains. Returns { kind, guid, id } for every FX the file
-- saved online and that has a GUID, in file order.
function M.refs(chains)
  local list = {}
  for _, c in ipairs(chains) do
    for _, fx in ipairs(c.fx) do
      if fx.id and not fx.offline then list[#list + 1] = { kind = c.kind, guid = c.guid, id = fx.id } end
    end
  end
  return list
end

-- Brings ref's FX online where it is now. live = {
--   object(ref) -> the track or take, or nil when it is gone or changed
--   count(ref, obj), fx_guid(ref, obj, i), set_online(ref, obj, i) }  (0-based i)
-- Returns false when the FX is not there (it is left alone).
function M.apply(ref, live)
  local obj = live.object(ref)
  if not obj then return false end
  for i = 0, live.count(ref, obj) - 1 do
    if live.fx_guid(ref, obj, i) == ref.id then
      live.set_online(ref, obj, i)
      return true
    end
  end
  return false
end

-- opts = { clock, budget?, apply(ref), alive?() -> bool, begin_step?, end_step? }
-- pass:step(budget?) brings FX online until the budget is used (at least one
-- per step) and returns true once every ref is done or the project is gone.
-- The budget includes begin_step and end_step (end_step's time is measured
-- each step and reserved in the next).
function M.new(refs, opts)
  local pass = { done = 0, total = #refs }
  local end_cost = 0
  function pass:step(budget)
    budget = budget or opts.budget or M.BUDGET
    if self.done >= self.total then return true end
    if opts.alive and not opts.alive() then
      self.total = self.done
      return true
    end
    local t0 = opts.clock()
    if opts.begin_step then opts.begin_step() end
    repeat
      self.done = self.done + 1
      opts.apply(refs[self.done])
    until self.done >= self.total or opts.clock() - t0 + end_cost >= budget
    local t1 = opts.clock()
    if opts.end_step then opts.end_step() end
    end_cost = opts.clock() - t1
    return self.done >= self.total
  end
  return pass
end

-- Progress travels through REAPER's ExtState, so a window opened while the
-- pass runs can show it: "done total time". A pass stopped by REAPER writes
-- M.INTERRUPTED instead.
local function parse(s)
  local done, total, at = tostring(s or ""):match("^(%d+) (%d+) ([%d%.]+)$")
  return tonumber(done), tonumber(total), tonumber(at)
end

function M.encode(done, total, now)
  return string.format("%d %d %.3f", done, total, now)
end

function M.decode(s, now)
  local done, total, at = parse(s)
  if not done or done >= total or now - at > M.STALE or now < at then return nil end
  return done, total
end

-- True when the last pass never finished: REAPER stopped the script, or it
-- has not moved for M.DEAD seconds.
function M.interrupted(s, now)
  if s == M.INTERRUPTED then return true end
  local done, total, at = parse(s)
  return done ~= nil and done < total and now - at > M.DEAD
end

function M.note(done, total)
  return ("Bringing FX online: %d of %d"):format(done, total)
end

return M
