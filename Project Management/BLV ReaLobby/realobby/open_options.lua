-- How a project opens: the footer's checkboxes, overridden by the button,
-- key, click or menu item that asked. Pure Lua (no reaper.*).
--
-- footer   = { fx_offline, online_after, new_tab }  (the checkboxes)
-- override = { fx_offline = true/false, new_tab = true/false }; a key that is
--            nil keeps the footer's choice
-- Result   = { fx_offline, online_after, new_tab }, all booleans, the shape
--            bridge.open takes.
local M = {}

function M.resolve(footer, override, supported)
  footer, override = footer or {}, override or {}
  -- An old REAPER cannot open with FX offline: the footer's checkboxes are
  -- disabled there. An explicit FX offline (Open safely) stays, so the caller
  -- can show the 7.74 note.
  local fx_offline = footer.fx_offline == true and supported ~= false
  if override.fx_offline ~= nil then fx_offline = override.fx_offline == true end
  local online_after = footer.online_after == true and supported ~= false
  local new_tab = footer.new_tab == true
  if override.new_tab ~= nil then new_tab = override.new_tab == true end
  -- Both on: FX offline wins and the effects stay offline.
  if fx_offline then online_after = false end
  return { fx_offline = fx_offline, online_after = online_after, new_tab = new_tab }
end

-- Enter or a double-click: Shift opens with FX offline, ⌘ (Mac; Windows
-- untested) opens in a new tab.
function M.from_keys(shift, cmd)
  local o = {}
  if shift then o.fx_offline = true end
  if cmd then o.new_tab = true end
  return o
end

-- True when REAPER must load the project with FX offline ("fxoffline:").
function M.offline_open(opts)
  return opts.fx_offline == true or opts.online_after == true
end

return M
