-- When ReaLobby's data is saved. Pure Lua: the entry script passes the save,
-- clock and log functions.
--
-- saver.new({ save() -> ok, err; now() -> seconds; log(s); every = 1.0 })
--   S:mark()   something changed
--   S:tick()   once per frame: saves when dirty and `every` seconds have
--              passed since the last attempt
--   S:flush()  on close: saves now when dirty
--   S:dirty()  true while a change is unsaved
-- Dirty is cleared only by a successful save, so a failed save is retried.
-- A failure is logged once per run of failures, not on every retry.
local M = {}

function M.new(opts)
  local every = opts.every or 1.0
  local S = {}
  local dirty, failing = false, false
  local tried_at = -math.huge

  local function attempt()
    tried_at = opts.now()
    local ok, err = opts.save()
    if ok then
      dirty, failing = false, false
    else
      if not failing and opts.log then opts.log(tostring(err)) end
      failing = true
    end
    return ok
  end

  function S:mark() dirty = true end
  function S:dirty() return dirty end

  function S:tick()
    if dirty and opts.now() - tried_at >= every then attempt() end
  end

  function S:flush()
    if dirty then attempt() end
  end

  return S
end

return M
