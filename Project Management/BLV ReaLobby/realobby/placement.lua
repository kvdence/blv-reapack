-- Where the window opens: dead centre of the screen REAPER is on, sized to
-- fit inside that screen's work area. Pure Lua; the shell passes the two
-- corners of the work area (in ImGui coordinates, either way up).
local M = {}

M.MARGIN = 24   -- space kept free at each screen edge

-- Returns the centre x, y and the largest window width, height that fit.
-- Nil when the area is missing or empty.
function M.fit(x1, y1, x2, y2)
  if not (x1 and y1 and x2 and y2) then return nil end
  local l, r = math.min(x1, x2), math.max(x1, x2)
  local t, b = math.min(y1, y2), math.max(y1, y2)
  if r - l < 1 or b - t < 1 then return nil end
  return (l + r) / 2, (t + b) / 2,
    math.max(1, r - l - 2 * M.MARGIN), math.max(1, b - t - 2 * M.MARGIN)
end

return M
