-- The middle column: the song table (Song, Artist, Status, Opened, Saved, BPM,
-- Ver.). A header click sorts, a second click reverses. Click selects, a
-- double-click or Enter opens, Shift+Enter opens with FX offline, ⌘↵ (Mac;
-- Windows untested) opens in a new tab, Up/Down move the selection. A
-- right-click opens the song menu (dialogs.row_menu).
-- Only the visible rows are drawn.
--
-- Reads from state: view, sort, selected_key, query, scanning, no_sources,
-- data.statuses, dialog, open(song, override), use_template(row, kind),
-- online_warning.
local theme = require("realobby.ui.theme")
local draw = require("realobby.ui.draw")
local rows_mod = require("realobby.ui.rows")
local format = require("realobby.ui.format")
local dialogs = require("realobby.ui.dialogs")
local open_options = require("realobby.open_options")

local M = {}

local MENU = "##rowmenu"

local SONG_COLUMNS = {
  { id = "title", label = "Song", font = "ui_bold" },
  { id = "author", label = "Artist", font = "ui", share = 0.32 },
  { id = "status", label = "Status", width = 104 },
  { id = "opened", label = "Opened", width = 86, mono = true },
  { id = "saved", label = "Saved", width = 76, mono = true },
  { id = "bpm", label = "BPM", width = 64, mono = true },
  { id = "versions", label = "Ver.", width = 56, mono = true },
}

local TEMPLATE_COLUMNS = {
  { id = "name", label = "Template", font = "ui_bold" },
  { id = "file", label = "File", font = "ui", share = 0.45 },
}

-- Column x positions and widths for a table w wide.
local function layout(cols, w)
  local fixed = 0
  for _, c in ipairs(cols) do fixed = fixed + (c.width or 0) end
  local flex = math.max(120, w - fixed)
  local out, x = {}, 0
  for i, c in ipairs(cols) do
    local cw = c.width or (c.share and math.floor(flex * c.share)) or 0
    out[i] = { x = x, w = cw }
    x = x + cw
  end
  -- The first column takes what is left.
  local used = 0
  for i = 2, #out do used = used + out[i].w end
  out[1].w = math.max(60, w - used)
  for i = 2, #out do out[i].x = out[i - 1].x + out[i - 1].w end
  return out
end

local function cell_text(s, col_id, now)
  if col_id == "title" then return s.display_title or "" end
  if col_id == "author" then return s.display_author or "" end
  if col_id == "opened" then return format.ago(s.opened, now) end
  if col_id == "saved" then return format.ago(s.mtime, now) end
  if col_id == "bpm" then return format.bpm(s.info and s.info.tempo) end
  if col_id == "versions" then return tostring(#(s.versions or {})) end
  return ""
end

local function header(ctx, dl, state, cols, pos, x, y, w, sortable)
  local ImGui, c, T = theme.ImGui, theme.colors, theme.table
  local size = theme.sizes.group
  for i, col in ipairs(cols) do
    local cx, cw = x + pos[i].x, pos[i].w
    local sorted = sortable and state.sort.column == col.id
    if sortable then
      ImGui.SetCursorScreenPos(ctx, cx, y)
      if ImGui.InvisibleButton(ctx, "##h_" .. col.id, math.max(1, cw), T.header_h) then
        state.sort = rows_mod.click_sort(state.sort, col.id)
      end
      if ImGui.IsItemHovered(ctx) then ImGui.SetMouseCursor(ctx, ImGui.MouseCursor_Hand) end
    end
    local label = col.label:upper()
    local lw, lh = draw.measure(ctx, "ui_bold", size, label)
    local ty = y + (T.header_h - lh) / 2
    local color = sorted and c.teal or c.group
    draw.text_fit(ctx, dl, "ui_bold", size, cx + T.pad_x, ty, color, label, cw - 2 * T.pad_x)
    if sorted then
      draw.sort_arrow(dl, cx + T.pad_x + lw + 5, y + T.header_h / 2, color, state.sort.descending)
    end
  end
  ImGui.DrawList_AddLine(dl, x, y + T.header_h - 0.5, x + w, y + T.header_h - 0.5, c.line, 1)
end

local function draw_row(ctx, dl, state, cols, pos, r, x, y, w, selected, hovered, templates, now)
  local ImGui, c, T = theme.ImGui, theme.colors, theme.table
  local h = T.row_h
  if selected then
    ImGui.DrawList_AddRectFilled(dl, x, y, x + w, y + h, c.selected)
    ImGui.DrawList_AddRectFilled(dl, x, y, x + 3, y + h, c.teal)
  elseif hovered then
    ImGui.DrawList_AddRectFilled(dl, x, y, x + w, y + h, c.row_hover)
  end
  ImGui.DrawList_AddLine(dl, x, y + h - 0.5, x + w, y + h - 0.5, c.row_line, 1)
  local cy = y + h / 2
  for i, col in ipairs(cols) do
    local cx, cw = x + pos[i].x + T.pad_x, pos[i].w - 2 * T.pad_x
    if col.id == "status" then
      if r.status then
        draw.pill(ctx, dl, cx, cy, draw.fit(ctx, "ui_bold", theme.sizes.pill, r.status, cw - 14),
          theme.status_color(r.status, state.data and state.data.statuses, state.data and state.data.status_builtin))
      end
    else
      local s
      if templates then
        s = col.id == "name" and r.name or format.file_name(r.path)
      else
        s = cell_text(r, col.id, now)
      end
      local font = col.mono and "mono" or col.font
      local size = col.mono and theme.sizes.mono or theme.sizes.body
      local color = col.mono and c.mono or c.cell
      local _, th = draw.measure(ctx, font, size, s ~= "" and s or "A")
      local tw = cw
      if col.id == "title" and r.cloud_only and not templates then
        -- A cloud placeholder: never read, so only its file name is known.
        local label = "not downloaded"
        local lw = draw.measure(ctx, "ui_bold", theme.sizes.pill, label) + 14
        if lw + 40 < cw then
          draw.pill(ctx, dl, cx + cw - lw, cy, label, c.faint)
          tw = cw - lw - 8
        end
      end
      draw.text_fit(ctx, dl, font, size, cx, cy - th / 2, color, s, tw)
    end
  end
end

-- A one-line message in a small container.
local function message(ctx, dl, x, y, s, color)
  local ImGui, c = theme.ImGui, theme.colors
  local size = theme.sizes.small
  local mw, mh = draw.measure(ctx, "ui", size, s)
  draw.tile(dl, x, y, mw + 20, mh + 12, 8)
  draw.text(dl, "ui", size, x + 10, y + 6, color or c.sub, s)
end

-- Shift: with FX offline; ⌘ (ImGui's Mod_Ctrl is Cmd on macOS; Windows
-- untested): in a new tab.
local function activate(ctx, state, r, templates)
  if not r then return end
  local ImGui = theme.ImGui
  if templates then
    if state.use_template then state.use_template(r, state.view.value) end
  elseif state.open then
    state.open(r, open_options.from_keys(ImGui.IsKeyDown(ctx, ImGui.Mod_Shift), ImGui.IsKeyDown(ctx, ImGui.Mod_Ctrl)))
  end
end

local function keys(ctx, state, list, templates)
  local ImGui = theme.ImGui
  if state.dialog then return end
  if not ImGui.IsWindowFocused(ctx, ImGui.FocusedFlags_RootAndChildWindows) then return end
  if ImGui.IsKeyPressed(ctx, ImGui.Key_DownArrow) then
    state.selected_key = rows_mod.move(list, state.selected_key, 1)
    state.scroll_to_selected = true
  elseif ImGui.IsKeyPressed(ctx, ImGui.Key_UpArrow) then
    state.selected_key = rows_mod.move(list, state.selected_key, -1)
    state.scroll_to_selected = true
  end
  if ImGui.IsKeyPressed(ctx, ImGui.Key_Enter, false) or ImGui.IsKeyPressed(ctx, ImGui.Key_KeypadEnter, false) then
    local i = rows_mod.index_of(list, state.selected_key)
    -- IsKeyPressed sees Enter even while the search field is active (it
    -- asks for any key owner), so typing then Enter opens the top match.
    activate(ctx, state, i and list[i], templates)
  end
end

function M.draw(ctx, state, list, w, h)
  local ImGui, c, T = theme.ImGui, theme.colors, theme.table
  local dl = ImGui.GetWindowDrawList(ctx)
  local x, y = ImGui.GetCursorScreenPos(ctx)
  if not w or not h then w, h = ImGui.GetContentRegionAvail(ctx) end
  local templates = state.view and state.view.group == "templates"
  local cols = templates and TEMPLATE_COLUMNS or SONG_COLUMNS
  -- Leave room for the rows' scrollbar so the header lines up with the cells.
  local scrolls = #list * T.row_h > h - T.header_h
  local pos = layout(cols, scrolls and (w - ImGui.GetStyleVar(ctx, ImGui.StyleVar_ScrollbarSize)) or w)
  local now = os.time()

  keys(ctx, state, list, templates)
  header(ctx, dl, state, cols, pos, x, y, w, not templates)

  if #list == 0 then
    message(ctx, dl, x + T.pad_x, y + T.header_h + 14, format.empty_message({
      scanning = state.scanning and not templates, query = state.query, view = state.view,
      no_sources = state.no_sources and not templates,
    }))
    return
  end

  -- Rows scroll in their own child under the fixed header.
  local body_h = h - T.header_h
  ImGui.SetCursorScreenPos(ctx, x, y + T.header_h)
  if ImGui.BeginChild(ctx, "##rows", w, body_h, ImGui.ChildFlags_None, ImGui.WindowFlags_NoBackground) then
    local rdl = ImGui.GetWindowDrawList(ctx)
    local rx, ry = ImGui.GetCursorScreenPos(ctx)
    local rw = select(1, ImGui.GetContentRegionAvail(ctx))
    local total = #list * T.row_h
    ImGui.Dummy(ctx, rw, total)

    local scroll = ImGui.GetScrollY(ctx)
    local sel = rows_mod.index_of(list, state.selected_key)
    if state.scroll_to_selected and sel then
      local top = (sel - 1) * T.row_h
      if top < scroll then
        ImGui.SetScrollY(ctx, top); scroll = top
      elseif top + T.row_h > scroll + body_h then
        scroll = top + T.row_h - body_h
        ImGui.SetScrollY(ctx, scroll)
      end
    end
    state.scroll_to_selected = false

    local first = math.max(1, math.floor(scroll / T.row_h) + 1)
    local last = math.min(#list, math.ceil((scroll + body_h) / T.row_h) + 1)
    for i = first, last do
      local r = list[i]
      local top = ry + (i - 1) * T.row_h
      ImGui.SetCursorScreenPos(ctx, rx, top)
      if ImGui.InvisibleButton(ctx, "##row" .. i, rw, T.row_h) then
        state.selected_key = r.key
      end
      local hovered = ImGui.IsItemHovered(ctx)
      -- Right-click selects the song and opens its menu.
      if not templates and ImGui.IsItemClicked(ctx, ImGui.MouseButton_Right) then
        state.selected_key = r.key
        state.menu_song = r
        ImGui.OpenPopup(ctx, MENU)
      end
      if hovered and ImGui.IsMouseDoubleClicked(ctx, ImGui.MouseButton_Left) then
        state.selected_key = r.key
        activate(ctx, state, r, templates)
      end
      draw_row(ctx, rdl, state, cols, pos, r, rx, top, rw, r.key == state.selected_key, hovered, templates, now)
    end
    -- The song menu, drawn every frame while it is open (its row may have
    -- scrolled out of view).
    ImGui.PushStyleVar(ctx, ImGui.StyleVar_WindowPadding, 8, 8)
    ImGui.PushStyleVar(ctx, ImGui.StyleVar_ItemSpacing, 8, 6)
    local menu_open = ImGui.BeginPopup(ctx, MENU)
    ImGui.PopStyleVar(ctx, 2)
    if menu_open then
      if state.menu_song then dialogs.row_menu(ctx, state, state.menu_song) end
      ImGui.EndPopup(ctx)
    end
    -- While the library is still being read, say so over the rows' bottom right.
    if state.scanning and not templates then
      local s = "Scanning…"
      local mw, mh = draw.measure(ctx, "ui", theme.sizes.small, s)
      local _, wy = ImGui.GetWindowPos(ctx)
      local bx, by = x + rw - mw - 20 - T.pad_x, wy + body_h - mh - 12 - 10
      ImGui.DrawList_AddRectFilled(rdl, bx, by, bx + mw + 20, by + mh + 12, c.popup, 8)
      message(ctx, rdl, bx, by, s)
    end
    -- The last "Bring FX online after load" never finished: over the rows'
    -- bottom left, in amber, for as long as the window is open.
    if state.online_warning then
      local s = state.online_warning
      local mw, mh = draw.measure(ctx, "ui", theme.sizes.small, s)
      local _, wy = ImGui.GetWindowPos(ctx)
      local bx, by = x + T.pad_x, wy + body_h - mh - 12 - 10
      ImGui.DrawList_AddRectFilled(rdl, bx, by, bx + mw + 20, by + mh + 12, c.popup, 8)
      message(ctx, rdl, bx, by, s, c.warn)
    end
    ImGui.EndChild(ctx)
  end
end

return M
