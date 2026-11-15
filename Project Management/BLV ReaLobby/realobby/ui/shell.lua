-- The ReaLobby window: frameless smoked glass, a top bar, three columns and a
-- footer. Columns and dialogs are drawn by the functions in shell.panes, which
-- the entry script fills in (Tasks 12-13); an empty pane draws nothing.
--
-- App state (one table, owned by the entry script):
--   query           search text
--   view            sidebar selection, { group = "recent" | "pinned" | "all" |
--                   "status" | "artist" | "templates" | "hidden", value = ... }
--   selected_key    key of the selected song, or nil
--   sort            { column = ..., descending = ... }
--   opacity         window tint alpha, 0..1 (data.opacity)
--   dialog          the open dialog's name, or nil
--   fx_offline      footer: Open with FX offline (recovery mode)
--   online_after    footer: Bring FX online after load
--   new_tab         footer: Open in new tab
--   ignore_default  footer: New project ignoring default template
--   fx_offline_supported  false on REAPER older than 7.74 (FX options disabled)
--   online_note     footer: "Bringing FX online: n of m" while that runs, or nil
local theme = require("realobby.ui.theme")
local format = require("realobby.ui.format")
local draw = require("realobby.ui.draw")
local placement = require("realobby.placement")

local shell = {}

-- Each pane is function(ctx, state, w, h) drawn inside its own child region
-- (dialogs: function(ctx, state), drawn inside the window after its Esc
-- check). Tasks 12-13 set them.
shell.panes = { sidebar = nil, table = nil, details = nil, dialogs = nil }

shell.TITLE = "BLV ReaLobby"
shell.SEARCH_HINT = "Search, or try bpm:90-100"
shell.FILTER_HELP = table.concat({
  "Narrow the list by typing filters, alone or with words:",
  "  bpm:95-100    bpm:>120    tracks:>20",
  "  saved:<7d    opened:>30d    (h, d, w, mo, y)",
  "  time:>2h    time worked on the song",
  "  status:mixing    artist:xi    uses:pro-q",
  'Quote a value with spaces: uses:"pro-q 3"',
}, "\n")

local ImGui

local function text_at(dl, font, size, x, y, color, s)
  ImGui.DrawList_AddTextEx(dl, font, size, x, y, color, s)
end

local function text_w(ctx, font_name, size, s)
  theme.push_font(ctx, font_name, size)
  local w = ImGui.CalcTextSize(ctx, s)
  theme.pop_font(ctx)
  return w
end

-- The return key arrow, drawn (fonts often lack the glyph). 9 x 9 px box.
local RETURN_W = 9
local function return_arrow(dl, x, cy, color)
  ImGui.DrawList_AddLine(dl, x + 8, cy - 4, x + 8, cy + 1, color, 1.2)
  ImGui.DrawList_AddLine(dl, x + 8, cy + 1, x + 1, cy + 1, color, 1.2)
  ImGui.DrawList_AddLine(dl, x + 1, cy + 1, x + 3.5, cy - 1.5, color, 1.2)
  ImGui.DrawList_AddLine(dl, x + 1, cy + 1, x + 3.5, cy + 3.5, color, 1.2)
end

-- A key hint box: prefix (e.g. "⇧"), a return arrow, then the label; mono
-- 11 px, 1 px border, 6 px radius, 2 x 6 padding. Returns its width.
local function kbd_width(ctx, prefix, label)
  local size = theme.sizes.kbd
  local pw = prefix ~= "" and (text_w(ctx, "mono", size, prefix) + 2) or 0
  return pw + RETURN_W + 4 + text_w(ctx, "mono", size, label) + 12
end

local function kbd(ctx, dl, x, cy, prefix, label)
  local size, color = theme.sizes.kbd, theme.colors.kbd
  local w = kbd_width(ctx, prefix, label)
  local h = size + 7
  local y = cy - h / 2
  ImGui.DrawList_AddRect(dl, x, y, x + w, y + h, theme.colors.control_border, 6, 0, 1)
  local tx, ty = x + 6, cy - size * 0.62
  if prefix ~= "" then
    text_at(dl, theme.fonts.mono, size, tx, ty, color, prefix)
    tx = tx + text_w(ctx, "mono", size, prefix) + 2
  end
  return_arrow(dl, tx, cy, color)
  text_at(dl, theme.fonts.mono, size, tx + RETURN_W + 4, ty, color, label)
  return w
end

-- The teal "+ New from template" button. Returns true when clicked.
local function primary_button(ctx, label)
  theme.push_font(ctx, "ui_bold", theme.sizes.button)
  ImGui.PushStyleColor(ctx, ImGui.Col_Button, theme.colors.teal)
  ImGui.PushStyleColor(ctx, ImGui.Col_ButtonHovered, 0x6BE0D0FF)
  ImGui.PushStyleColor(ctx, ImGui.Col_ButtonActive, 0x45BFAEFF)
  ImGui.PushStyleColor(ctx, ImGui.Col_Text, theme.colors.button_text)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_FramePadding, 12, 7)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_FrameRounding, 9)
  local clicked = ImGui.Button(ctx, label)
  ImGui.PopStyleVar(ctx, 2)
  ImGui.PopStyleColor(ctx, 4)
  theme.pop_font(ctx)
  return clicked
end

-- The outlined "Settings" button. Returns true when clicked.
local function secondary_button(ctx, label)
  theme.push_font(ctx, "ui_bold", theme.sizes.button)
  ImGui.PushStyleColor(ctx, ImGui.Col_Button, 0)
  ImGui.PushStyleColor(ctx, ImGui.Col_Border, theme.colors.control_border)
  ImGui.PushStyleColor(ctx, ImGui.Col_Text, theme.colors.button2_text)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_FramePadding, 12, 7)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_FrameRounding, 9)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_FrameBorderSize, 1)
  local clicked = ImGui.Button(ctx, label)
  ImGui.PopStyleVar(ctx, 3)
  ImGui.PopStyleColor(ctx, 3)
  theme.pop_font(ctx)
  return clicked
end

local function primary_button_width(ctx, label)
  return text_w(ctx, "ui_bold", theme.sizes.button, label) + 24
end

local function magnifier(dl, x, cy, color)
  ImGui.DrawList_AddCircle(dl, x + 7, cy - 1, 6, color, 0, 1.6)
  ImGui.DrawList_AddLine(dl, x + 11.5, cy + 3.5, x + 16, cy + 8, color, 1.6)
end

-- Top bar ---------------------------------------------------------------------

local function top_bar(ctx, state, x, y, w, appearing)
  local L, c = theme.layout, theme.colors
  local h = L.top_h
  local dl = ImGui.GetWindowDrawList(ctx)
  local cy = y + h / 2

  -- Dragging any empty part of the bar moves the window; the controls drawn
  -- on top of it take the clicks that land on them.
  ImGui.SetCursorScreenPos(ctx, x, y)
  ImGui.SetNextItemAllowOverlap(ctx)
  ImGui.InvisibleButton(ctx, "##move", w, h)
  if ImGui.IsItemActive(ctx) and ImGui.IsMouseDragging(ctx, ImGui.MouseButton_Left, 0) then
    local dx, dy = ImGui.GetMouseDelta(ctx)
    if dx ~= 0 or dy ~= 0 then
      local wx, wy = ImGui.GetWindowPos(ctx)
      ImGui.SetWindowPos(ctx, wx + dx, wy + dy)
    end
  end

  -- Brand: "BLV Rea" + teal "Lobby".
  local bx = x + L.pad_x
  local bsize = theme.sizes.brand
  local lead = "BLV Rea"
  theme.push_font(ctx, "brand", bsize)
  local lead_w, bh = ImGui.CalcTextSize(ctx, lead)
  theme.pop_font(ctx)
  text_at(dl, theme.fonts.brand, bsize, bx, cy - bh / 2, c.ink, lead)
  text_at(dl, theme.fonts.brand, bsize, bx + lead_w, cy - bh / 2, c.teal, "Lobby")

  -- Right side, laid out from the right edge.
  local label = "+ New from template"
  local btn_w = primary_button_width(ctx, label)
  local right = x + w - L.pad_x
  local btn_x = right - btn_w
  local set_label = "Settings"
  local set_w = text_w(ctx, "ui_bold", theme.sizes.button, set_label) + 24
  local set_x = btn_x - L.gap / 2 - set_w
  local safe_w, open_w = kbd_width(ctx, "⇧", "safe"), kbd_width(ctx, "", "open")
  local safe_x = set_x - L.gap - safe_w
  local open_x = safe_x - L.gap / 2 - open_w
  kbd(ctx, dl, open_x, cy, "", "open")
  kbd(ctx, dl, safe_x, cy, "⇧", "safe")

  -- Search field between the brand and the hints.
  local mx = bx + L.brand_w
  magnifier(dl, mx, cy, c.group)
  local qx = mx + 16 + L.gap
  local qw = math.max(80, open_x - L.gap - qx)
  theme.push_font(ctx, "ui", theme.sizes.query)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_FramePadding, 2, 4)
  local fh = ImGui.GetFrameHeight(ctx)
  ImGui.SetCursorScreenPos(ctx, qx, cy - fh / 2)
  ImGui.SetNextItemWidth(ctx, qw)
  if appearing then ImGui.SetKeyboardFocusHere(ctx) end
  -- Typing always searches: while the field is not being edited (after a
  -- click on a row, or Enter), typed characters and Backspace go into the
  -- query. The field is not refocused, so its text is never selected and
  -- replaced.
  if not appearing and not state.search_active and not state.dialog
      and not ImGui.IsKeyDown(ctx, ImGui.Mod_Ctrl) and not ImGui.IsKeyDown(ctx, ImGui.Mod_Super)
      and ImGui.IsWindowFocused(ctx, ImGui.FocusedFlags_RootAndChildWindows) then
    local chars = {}
    for i = 0, 63 do
      local ok, cp = ImGui.GetInputQueueCharacter(ctx, i)
      if not ok then break end
      chars[#chars + 1] = cp
    end
    local back = ImGui.IsKeyPressed(ctx, ImGui.Key_Backspace) and 1 or 0
    if #chars > 0 or back > 0 then state.query = format.type_into(state.query, chars, back) end
  end
  ImGui.PushStyleColor(ctx, ImGui.Col_Text, c.query)
  ImGui.PushStyleColor(ctx, ImGui.Col_FrameBg, 0)
  ImGui.PushStyleColor(ctx, ImGui.Col_FrameBgHovered, 0)
  ImGui.PushStyleColor(ctx, ImGui.Col_FrameBgActive, 0)
  local changed, q = ImGui.InputTextWithHint(ctx, "##query", shell.SEARCH_HINT, state.query or "")
  ImGui.PopStyleVar(ctx)
  ImGui.PopStyleColor(ctx, 4)
  theme.pop_font(ctx)
  if changed then state.query = q end
  state.search_active = ImGui.IsItemActive(ctx)
  if ImGui.IsItemHovered(ctx, ImGui.HoveredFlags_DelayNormal or 0) then ImGui.SetTooltip(ctx, shell.FILTER_HELP) end

  -- Button.
  theme.push_font(ctx, "ui_bold", theme.sizes.button)
  local bh = ImGui.GetTextLineHeight(ctx) + 14
  theme.pop_font(ctx)
  ImGui.SetCursorScreenPos(ctx, btn_x, cy - bh / 2)
  if primary_button(ctx, label) then state.dialog = "new_from_template" end
  ImGui.SetCursorScreenPos(ctx, set_x, cy - bh / 2)
  if secondary_button(ctx, set_label) then state.dialog = "settings" end

  ImGui.DrawList_AddLine(dl, x, y + h - 0.5, x + w, y + h - 0.5, c.line, 1)
end

-- Columns ---------------------------------------------------------------------

local function pane(ctx, id, fn, state, x, y, w, h, pad_x, pad_y)
  ImGui.SetCursorScreenPos(ctx, x, y)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_WindowPadding, pad_x, pad_y)
  local flags = ImGui.ChildFlags_AlwaysUseWindowPadding
  local visible = ImGui.BeginChild(ctx, id, w, h, flags, ImGui.WindowFlags_NoBackground)
  ImGui.PopStyleVar(ctx)
  if visible then
    if fn then fn(ctx, state, w - 2 * pad_x, h - 2 * pad_y) end
    ImGui.EndChild(ctx)
  end
end

local function body(ctx, state, x, y, w, h)
  local L, c = theme.layout, theme.colors
  local dl = ImGui.GetWindowDrawList(ctx)
  local sx = x + L.sidebar_w
  local dx = x + w - L.details_w
  pane(ctx, "##sidebar", shell.panes.sidebar, state, x, y, L.sidebar_w, h, 10, 12)
  pane(ctx, "##table", shell.panes.table, state, sx, y, dx - sx, h, 0, 0)
  pane(ctx, "##details", shell.panes.details, state, dx, y, L.details_w, h, 16, 16)
  ImGui.DrawList_AddLine(dl, sx - 0.5, y, sx - 0.5, y + h, c.line, 1)
  ImGui.DrawList_AddLine(dl, dx + 0.5, y, dx + 0.5, y + h, c.line, 1)
end

-- Footer ----------------------------------------------------------------------

local CHECKBOX_PAD = 1
local ONLINE_TIP = "Opens the project with every plug-in offline, then brings them online a few at a time.\n"
  .. "Plug-ins saved offline stay offline.\n"
  .. "When Open with FX offline is also on, plug-ins stay offline."
local NEW_TAB_TIP = "Opens the project in a new project tab. The current tab stays open.\n"
  .. "⌘↵ (Mac) does this for one open. A song already open in a tab is brought to the front instead."

local function checkbox(ctx, label, value)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_FramePadding, CHECKBOX_PAD, CHECKBOX_PAD)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_FrameRounding, 3)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_FrameBorderSize, 1)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_ItemInnerSpacing, 6, 4)
  ImGui.PushStyleColor(ctx, ImGui.Col_Border, theme.colors.checkbox_border)
  local changed, v = ImGui.Checkbox(ctx, label, value and true or false)
  ImGui.PopStyleColor(ctx)
  ImGui.PopStyleVar(ctx, 4)
  return changed, v
end

local function footer(ctx, state, x, y, w)
  local L, c = theme.layout, theme.colors
  local h = L.foot_h
  local dl = ImGui.GetWindowDrawList(ctx)
  ImGui.DrawList_AddLine(dl, x, y + 0.5, x + w, y + 0.5, c.line, 1)
  theme.push_font(ctx, "ui", theme.sizes.foot)
  ImGui.PushStyleColor(ctx, ImGui.Col_Text, c.mono)
  local fh = ImGui.GetTextLineHeight(ctx) + 2 * CHECKBOX_PAD   -- the checkbox row
  local cy = y + h / 2
  ImGui.SetCursorScreenPos(ctx, x + L.pad_x, cy - fh / 2)
  -- REAPER older than 7.74 cannot open with FX offline: both FX options are
  -- shown disabled with a short note.
  local supported = state.fx_offline_supported ~= false
  if not supported then ImGui.BeginDisabled(ctx) end
  local ch, v = checkbox(ctx, "Open with FX offline (recovery mode)", supported and state.fx_offline)
  if ch then state.fx_offline = v end
  ImGui.SameLine(ctx, 0, 18)
  ch, v = checkbox(ctx, "Bring FX online after load", supported and state.online_after)
  if ch then state.online_after = v end
  if ImGui.IsItemHovered(ctx, ImGui.HoveredFlags_AllowWhenDisabled) then
    ImGui.SetTooltip(ctx, ONLINE_TIP)
  end
  if not supported then
    ImGui.EndDisabled(ctx)
    -- The note sits in a small container, like the other notes.
    ImGui.SameLine(ctx, 0, 8)
    local note = "Needs REAPER 7.74 or newer."
    local nx = ImGui.GetCursorScreenPos(ctx)
    local nw, nh = draw.measure(ctx, "ui", theme.sizes.small, note)
    local ny = cy - nh / 2 - 4
    ImGui.DrawList_AddRectFilled(dl, nx, ny, nx + nw + 16, ny + nh + 8, theme.colors.bounce_bg, 7)
    draw.text(dl, "ui", theme.sizes.small, nx + 8, ny + 4, theme.colors.faint, note)
    ImGui.Dummy(ctx, nw + 16, fh)
  end
  ImGui.SameLine(ctx, 0, 18)
  ch, v = checkbox(ctx, "Open in new tab", state.new_tab)
  if ch then state.new_tab = v end
  if ImGui.IsItemHovered(ctx) then ImGui.SetTooltip(ctx, NEW_TAB_TIP) end
  ImGui.SameLine(ctx, 0, 18)
  ch, v = checkbox(ctx, "New project ignoring default template", state.ignore_default)
  if ch then state.ignore_default = v end
  -- A narrow window has no room for the right-hand line beside the checkboxes.
  local used = ImGui.GetItemRectMax(ctx)
  local note = state.online_note
  if note then
    -- A pass running now, in a small container in place of the glass line.
    local nw, nh = draw.measure(ctx, "ui", theme.sizes.small, note)
    local nx, ny = x + w - L.pad_x - nw - 16, cy - nh / 2 - 4
    if nx >= used + 18 then
      ImGui.DrawList_AddRectFilled(dl, nx, ny, nx + nw + 16, ny + nh + 8, c.bounce_bg, 7)
      draw.text(dl, "ui", theme.sizes.small, nx + 8, ny + 4, c.sub, note)
    end
  else
    local glass = string.format("Glass %d%% · grain %s",
      math.floor((state.opacity or theme.OPACITY) * 100 + 0.5), theme.grain and "on" or "off")
    local gw, gh = ImGui.CalcTextSize(ctx, glass)
    if x + w - L.pad_x - gw >= used + 18 then
      text_at(dl, theme.fonts.ui, theme.sizes.foot, x + w - L.pad_x - gw, cy - gh / 2, c.mono, glass)
    end
  end
  ImGui.PopStyleColor(ctx)
  theme.pop_font(ctx)
end

-- Window ----------------------------------------------------------------------

local function window_flags()
  return ImGui.WindowFlags_NoTitleBar | ImGui.WindowFlags_NoCollapse | ImGui.WindowFlags_NoScrollbar
    | ImGui.WindowFlags_NoBackground | ImGui.WindowFlags_NoScrollWithMouse | ImGui.WindowFlags_NoMove
    | ImGui.WindowFlags_NoDocking
end

-- Draws one frame. Returns false once the window should close (Esc, or the
-- window was closed), true otherwise.
function shell.frame(ctx, state)
  ImGui = theme.ImGui
  local L = theme.layout
  -- Dead centre of the screen REAPER is on, every time the window opens or
  -- is asked to come forward, never larger than that screen.
  local recenter = state.recenter or not state.placement
  state.recenter = false
  if recenter then
    local cx, cy, mw, mh
    if state.screen_area then cx, cy, mw, mh = placement.fit(state.screen_area(ctx)) end
    if not cx then
      -- No work area: the main viewport is REAPER's main window.
      cx, cy = ImGui.Viewport_GetCenter(ImGui.GetMainViewport(ctx))
      mw, mh = 1e6, 1e6
    end
    state.placement = { x = cx, y = cy, w = mw, h = mh }
  end
  local pl = state.placement
  ImGui.SetNextWindowSize(ctx, math.min(L.default_w, pl.w), math.min(L.default_h, pl.h), ImGui.Cond_FirstUseEver)
  if recenter then ImGui.SetNextWindowPos(ctx, pl.x, pl.y, ImGui.Cond_Always, 0.5, 0.5) end
  ImGui.SetNextWindowSizeConstraints(ctx, math.min(L.min_w, pl.w), math.min(L.min_h, pl.h), pl.w, pl.h)

  theme.push(ctx)
  theme.push_font(ctx, "ui", theme.sizes.body)
  local visible, open = ImGui.Begin(ctx, shell.TITLE, true, window_flags())
  if visible then
    local appearing = ImGui.IsWindowAppearing(ctx)
    local x, y = ImGui.GetWindowPos(ctx)
    local w, h = ImGui.GetWindowSize(ctx)
    theme.draw_glass(ctx, ImGui.GetWindowDrawList(ctx), x, y, w, h, state.opacity)
    top_bar(ctx, state, x, y, w, appearing)
    body(ctx, state, x, y + L.top_h, w, h - L.top_h - L.foot_h)
    footer(ctx, state, x, y + h - L.foot_h, w)

    -- Esc closes the window unless a dialog or a menu is open (the Esc
    -- closes that instead). ImGui may already have closed a menu this frame,
    -- so "open" means open at the end of the previous frame.
    if not state.dialog and not state.popup_was_open and ImGui.IsKeyPressed(ctx, ImGui.Key_Escape, false)
      and ImGui.IsWindowFocused(ctx, ImGui.FocusedFlags_RootAndChildWindows) then
      open = false
    end
    -- Dialogs are popups of this window (its ID stack), drawn after the Esc
    -- check so the Esc that closes a dialog does not also close the window.
    if shell.panes.dialogs then shell.panes.dialogs(ctx, state) end
    state.popup_was_open = ImGui.IsPopupOpen(ctx, "", ImGui.PopupFlags_AnyPopupId | ImGui.PopupFlags_AnyPopupLevel)
    ImGui.End(ctx)
  end
  theme.pop_font(ctx)
  theme.pop(ctx)
  return open ~= false
end

return shell
