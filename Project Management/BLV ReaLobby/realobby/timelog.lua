-- Time worked on each song. Pure Lua (no reaper.*).
--
-- The counter (BLV_ReaLobby_Timer.lua) runs in the background while REAPER
-- is open. Once a second it reports the active project tab's song and an
-- activity signature (mouse position, the project's change count, and the
-- time while playing or recording). Time counts while a saved project is the
-- active tab and something changed in the last IDLE seconds; it stops after
-- IDLE seconds without mouse movement, edits or playback.
--
-- The file (Data/BLV ReaLobby/time.dat) holds { version = 1, songs = { [key]
-- = seconds } }, keyed by the song key (realobby/versions.lua) passed through
-- the bridge's normalize, so every version of a song adds to one total.
-- Writers add to what is on disk (add, move) instead of replacing it, so the
-- counter and a ReaLobby window can both write.
local store = require("realobby.store")

local M = {}

M.IDLE = 300        -- seconds without activity before counting stops
M.MAX_STEP = 5      -- longest gap between ticks that still counts (sleep, stalls)
M.FLUSH_EVERY = 60  -- seconds between writes

-- load(path) -> { [key] = seconds } (empty when there is no file yet)
function M.load(path)
  local t = store.read(path)
  local songs = type(t) == "table" and type(t.songs) == "table" and t.songs or {}
  local out = {}
  for k, v in pairs(songs) do
    if type(k) == "string" and type(v) == "number" and v > 0 then out[k] = v end
  end
  return out
end

local function exists(path)
  local f = io.open(path, "rb")
  if f then f:close() end
  return f ~= nil
end

local function write(path, songs)
  return store.save(path, { version = 1, songs = songs })
end

-- The file's times for a change. A file that exists but cannot be read is
-- first set aside as time.dat.bad-<n> (nothing is lost; it can be put back
-- by hand), so the change starts a new file instead of failing for ever.
local function current(path)
  if exists(path) and store.read(path) == nil then
    local n = 1
    while exists(path .. ".bad-" .. n) do n = n + 1 end
    os.rename(path, path .. ".bad-" .. n)
  end
  return M.load(path)
end

-- add(path, deltas) adds { [key] = seconds } to the file. True or false, err.
function M.add(path, deltas)
  if next(deltas) == nil then return true end
  local songs = current(path)
  for k, v in pairs(deltas) do songs[k] = (songs[k] or 0) + v end
  return write(path, songs)
end

-- move(path, from, to): a renamed or moved song keeps its time.
function M.move(path, from, to)
  if from == to then return true end
  local songs = current(path)
  if not songs[from] then return true end
  songs[to] = (songs[to] or 0) + songs[from]
  songs[from] = nil
  return write(path, songs)
end

-- counter(opts) -> C. opts.idle, opts.max_step override the defaults.
--   C:tick(now, key, signature): key is the active song's key or nil.
--   C:take() -> { [key] = seconds } counted since the last take.
function M.counter(opts)
  opts = opts or {}
  local idle = opts.idle or M.IDLE
  local max_step = opts.max_step or M.MAX_STEP
  local C = {}
  local pending = {}
  local last_tick, last_sig, last_active, last_key

  function C:tick(now, key, sig)
    if sig ~= last_sig or key ~= last_key then
      last_sig, last_active = sig, now
    end
    if last_tick and key and key == last_key and last_active then
      local dt = now - last_tick
      if dt > 0 and dt <= max_step and now - last_active < idle then
        pending[key] = (pending[key] or 0) + dt
      end
    end
    last_tick, last_key = now, key
  end

  function C:take()
    local out = {}
    for k, v in pairs(pending) do out[k] = v end
    pending = {}
    return out
  end

  return C
end

return M
