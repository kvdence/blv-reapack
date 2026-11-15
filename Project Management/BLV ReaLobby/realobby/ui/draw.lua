-- Small drawing helpers shared by the panes: measured text, clipped text,
-- pills and tiles. ImGui is only touched inside the functions (theme.ImGui,
-- set by theme.init).
local theme = require("realobby.ui.theme")

local D = {}

local widths, count = {}, 0
local MAX_CACHED = 4000

-- Width and height of s in a theme font at size (cached; ImGui measures each
-- string once).
function D.measure(ctx, font_name, size, s)
  local key = font_name .. "\0" .. size .. "\0" .. s
  local m = widths[key]
  if m then return m[1], m[2] end
  local ImGui = theme.ImGui
  theme.push_font(ctx, font_name, size)
  local w, h = ImGui.CalcTextSize(ctx, s)
  theme.pop_font(ctx)
  if count >= MAX_CACHED then widths, count = {}, 0 end
  widths[key], count = { w, h }, count + 1
  return w, h
end

function D.text(dl, font_name, size, x, y, color, s)
  theme.ImGui.DrawList_AddTextEx(dl, theme.fonts[font_name], size, x, y, color, s)
end

-- The first n bytes of s, backed off so no UTF-8 sequence is cut.
local function head(s, n)
  local cut = s:sub(1, n)
  while #cut > 0 and cut:byte(#cut) >= 0x80 and cut:byte(#cut) < 0xC0 do cut = cut:sub(1, -2) end
  if #cut > 0 and cut:byte(#cut) >= 0xC0 then cut = cut:sub(1, -2) end
  return cut
end

-- s shortened with "…" to fit max_w.
function D.fit(ctx, font_name, size, s, max_w)
  if max_w <= 0 then return "" end
  if D.measure(ctx, font_name, size, s) <= max_w then return s end
  local lo, hi = 0, #s
  while lo < hi do
    local mid = (lo + hi + 1) // 2
    if D.measure(ctx, font_name, size, head(s, mid) .. "…") <= max_w then lo = mid else hi = mid - 1 end
  end
  return head(s, lo) .. "…"
end

-- text split into lines no wider than max_w (at spaces; a word wider than
-- the line is shortened), at most max_lines (the last one ends in "…" when
-- text was left over).
function D.wrap(ctx, font_name, size, text, max_w, max_lines)
  local lines = {}
  local function full() return max_lines and #lines >= max_lines end
  local cut = false
  for para in (text .. "\n"):gmatch("(.-)\r?\n") do
    if full() then cut = true; break end
    local line = ""
    for word in para:gmatch("%S+") do
      local try = line == "" and word or (line .. " " .. word)
      if D.measure(ctx, font_name, size, try) <= max_w then
        line = try
      else
        if line ~= "" then
          lines[#lines + 1] = line
          if full() then cut = true; line = nil; break end
        end
        line = D.fit(ctx, font_name, size, word, max_w)
      end
    end
    if line == nil then break end
    lines[#lines + 1] = line
  end
  while #lines > 0 and lines[#lines] == "" do lines[#lines] = nil end
  if cut and #lines > 0 then
    lines[#lines] = D.fit(ctx, font_name, size, lines[#lines] .. " …", max_w)
  end
  return lines
end

-- Text drawn at (x, y) and shortened to max_w.
function D.text_fit(ctx, dl, font_name, size, x, y, color, s, max_w)
  D.text(dl, font_name, size, x, y, color, D.fit(ctx, font_name, size, s, max_w))
end

-- A status pill: text in colour c on c at 13 %, 6 px radius, 2 x 7 padding,
-- vertically centred on cy. Returns its width.
function D.pill(ctx, dl, x, cy, s, c)
  local size = theme.sizes.pill
  local w, h = D.measure(ctx, "ui_bold", size, s)
  local pw, ph = w + 14, h + 4
  local y = cy - ph / 2
  theme.ImGui.DrawList_AddRectFilled(dl, x, y, x + pw, y + ph, theme.with_alpha(c, 0.13), 6)
  D.text(dl, "ui_bold", size, x + 7, y + 2, c, s)
  return pw
end

-- A tile background: white 4.5 % with a 1 px white 7 % border.
function D.tile(dl, x, y, w, h, radius)
  local ImGui = theme.ImGui
  ImGui.DrawList_AddRectFilled(dl, x, y, x + w, y + h, theme.colors.tile, radius or 10)
  ImGui.DrawList_AddRect(dl, x + 0.5, y + 0.5, x + w - 0.5, y + h - 0.5, theme.colors.line, radius or 10, 0, 1)
end

-- A small arrow for the sorted column header, pointing down when descending.
function D.sort_arrow(dl, x, cy, color, descending)
  local ImGui = theme.ImGui
  if descending then
    ImGui.DrawList_AddTriangleFilled(dl, x, cy - 2, x + 7, cy - 2, x + 3.5, cy + 2.5, color)
  else
    ImGui.DrawList_AddTriangleFilled(dl, x, cy + 2, x + 7, cy + 2, x + 3.5, cy - 2.5, color)
  end
end

return D
