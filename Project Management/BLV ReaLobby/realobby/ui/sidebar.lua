-- The left column: Library (Recent, Pinned, All projects), Status (one row
-- per status), Artists (one row per author), Templates (Project, Track) and
-- Hidden at the bottom, each with its count. Clicking a row sets state.view.
local theme = require("realobby.ui.theme")
local draw = require("realobby.ui.draw")
local rows = require("realobby.ui.rows")

local M = {}

local ROW_H = 29
local ROW_GAP = 2

local memo = {}

-- Counts are recomputed only when the songs table or the status list changes.
local function counts(songs, statuses)
  local sig = table.concat(statuses or {}, "\0")
  if memo.songs ~= songs or memo.sig ~= sig then
    memo.songs, memo.sig = songs, sig
    memo.counts = rows.counts(songs, statuses)
  end
  return memo.counts
end

local function group_label(ctx, dl, label, w, first)
  local ImGui = theme.ImGui
  local x, y = ImGui.GetCursorScreenPos(ctx)
  local top = first and 4 or 12
  local size = theme.sizes.group
  local _, h = draw.measure(ctx, "ui_bold", size, label)
  draw.text(dl, "ui_bold", size, x + 8, y + top, theme.colors.group, label:upper())
  ImGui.Dummy(ctx, w, top + h + 6)
end

-- One row; dot is a status colour or nil.
local function nav_row(ctx, dl, state, id, label, n, view, w, dot)
  local ImGui, c = theme.ImGui, theme.colors
  local x, y = ImGui.GetCursorScreenPos(ctx)
  if ImGui.InvisibleButton(ctx, id, w, ROW_H) then
    state.view = { group = view.group, value = view.value }
  end
  local hovered = ImGui.IsItemHovered(ctx)
  local on = rows.same_view(state.view, view)
  local bg = on and c.selected or (hovered and c.row_hover) or c.nav_bg
  ImGui.DrawList_AddRectFilled(dl, x, y, x + w, y + ROW_H, bg, 8)

  local size = theme.sizes.body
  local cy = y + ROW_H / 2
  local tx = x + 8
  if dot then
    ImGui.DrawList_AddCircleFilled(dl, tx + 4, cy, 4, dot)
    tx = tx + 16
  end
  local ns = tostring(n)
  local nw, nh = draw.measure(ctx, "ui", theme.sizes.small, ns)
  draw.text(dl, "ui", theme.sizes.small, x + w - 8 - nw, cy - nh / 2, c.count, ns)
  local _, lh = draw.measure(ctx, "ui", size, label)
  draw.text_fit(ctx, dl, "ui", size, tx, cy - lh / 2, on and c.nav_on or c.nav, label, x + w - 16 - nw - tx)
  ImGui.Dummy(ctx, 0, ROW_GAP)
end

-- songs: every song, hidden ones included (L:songs({ include_hidden = true })).
function M.draw(ctx, state, songs, data, w, h)
  local ImGui = theme.ImGui
  local dl = ImGui.GetWindowDrawList(ctx)
  w = w or select(1, ImGui.GetContentRegionAvail(ctx))
  local cnt = counts(songs, data.statuses)
  local templates = state.templates or { project = {}, track = {} }
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_ItemSpacing, 0, 0)

  group_label(ctx, dl, "Library", w, true)
  nav_row(ctx, dl, state, "##recent", "Recent", cnt.recent, { group = "recent" }, w)
  nav_row(ctx, dl, state, "##pinned", "Pinned", cnt.pinned, { group = "pinned" }, w)
  nav_row(ctx, dl, state, "##all", "All projects", cnt.all, { group = "all" }, w)

  if #(data.statuses or {}) > 0 then
    group_label(ctx, dl, "Status", w)
    for i, name in ipairs(data.statuses) do
      nav_row(ctx, dl, state, "##status" .. i, name, cnt.status[name] or 0, { group = "status", value = name }, w,
        theme.status_color(name, data.statuses, data.status_builtin))
    end
  end

  if #cnt.artists > 0 then
    group_label(ctx, dl, "Artists", w)
    for i, a in ipairs(cnt.artists) do
      nav_row(ctx, dl, state, "##artist" .. i, a.name, a.count, { group = "artist", value = a.name }, w)
    end
  end

  group_label(ctx, dl, "Templates", w)
  nav_row(ctx, dl, state, "##tproject", "Project", #templates.project, { group = "templates", value = "project" }, w)
  nav_row(ctx, dl, state, "##ttrack", "Track", #templates.track, { group = "templates", value = "track" }, w)

  -- Hidden sits at the bottom of the column when there is room.
  local _, avail = ImGui.GetContentRegionAvail(ctx)
  local room = avail - ROW_H - ROW_GAP
  ImGui.Dummy(ctx, w, math.max(12, room))
  nav_row(ctx, dl, state, "##hidden", "Hidden", cnt.hidden, { group = "hidden" }, w)

  ImGui.PopStyleVar(ctx)
end

return M
