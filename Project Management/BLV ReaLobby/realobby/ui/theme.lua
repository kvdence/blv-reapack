-- The Smoked Glass Desk look: colours, sizes, fonts and the glass background.
-- Values come from Scopes/BLV ReaLobby (working name)/Design/glass-desk-smoked.html.
--
-- Loads under plain Lua (controller ruling R2): colour tables and pure helpers
-- live at the top level; ImGui is only touched inside init, push/pop, the font
-- helpers and draw_glass, after theme.init(ImGui, ctx, grain_path) has run.
-- Colours are ImGui's 0xRRGGBBAA.
local theme = {}

local function a8(alpha)
  if alpha == nil then return 0xFF end
  if alpha <= 0 then return 0 end
  if alpha >= 1 then return 0xFF end
  return math.floor(alpha * 255)
end

-- Replaces the alpha byte of colour c with alpha (0..1, clamped).
function theme.with_alpha(c, alpha)
  return (c & 0xFFFFFF00) | a8(alpha)
end

local function white(alpha) return theme.with_alpha(0xFFFFFFFF, alpha) end

theme.OPACITY = 0.94        -- window tint alpha (data.opacity, Settings 80-100 %)
theme.GRAIN_ALPHA = 0.06    -- tiled grain image
theme.SHEEN_ALPHA = 0.06    -- white at the top-left of the sheen
theme.SHEEN_DEPTH = 0.45    -- the sheen fades to 0 across the top 45 %
theme.SHEEN_ANGLE = 160     -- CSS linear-gradient angle in the mockup
theme.RADIUS = 18           -- window corner radius
theme.GRAIN_SIZE = 160      -- grain.png is 160 x 160

local teal = 0x52D6C4FF

theme.colors = {
  window_tint = theme.with_alpha(0x121418FF, theme.OPACITY),
  teal = teal,
  writing = 0x7CC4FFFF,
  mixing = 0xF2A541FF,
  done = 0x6FDC8CFF,
  warn = 0xF2C14EFF,
  ink = 0xE8E9ECFF,         -- body text
  sub = 0x9A9EA8FF,         -- secondary text, neutral status
  query = 0xF2F4F6FF,       -- search text
  group = 0x7D838DFF,       -- group labels, table headers
  nav = 0xC9CCD2FF,         -- sidebar rows
  count = 0x6F757EFF,       -- sidebar counts
  cell = 0xD6D9DEFF,        -- table cells
  mono = 0x8D939CFF,        -- numbers, dates, footer text
  kbd = 0x9AA1ABFF,         -- key hints
  button_text = 0x0B1514FF, -- text on the teal button
  button2_text = 0xDFE2E6FF,
  line = white(0.07),       -- column and bar dividers
  row_line = white(0.045),
  border = white(0.10),     -- window edge
  highlight = white(0.07),  -- 1 px top highlight
  control_border = white(0.14),
  checkbox_border = white(0.25),
  tile = white(0.045),
  selected = theme.with_alpha(teal, 0.12),
  warn_bg = theme.with_alpha(0xF2C14EFF, 0.09),
  warn_border = theme.with_alpha(0xF2C14EFF, 0.28),
  popup = 0x16181CF8,
  meta = 0x9AA1ABFF,        -- details: author, file name, summary line
  nav_on = 0xFFFFFFFF,      -- the selected sidebar row
  row_hover = white(0.03),
  nav_bg = white(0.025),    -- sidebar rows sit on a faint container
  bounce_bg = white(0.03),
  faint = 0x6F757EFF,       -- not downloaded, notes placeholder
}

theme.layout = {
  sidebar_w = 190, details_w = 290, top_h = 62, foot_h = 38,
  pad_x = 18, gap = 12, brand_w = 160,
  min_w = 980, min_h = 560, default_w = 1180, default_h = 680,
}

theme.sizes = {
  body = 13, brand = 15, query = 19, kbd = 11, button = 12.5, foot = 12,
  group = 10.5, title = 18, small = 12,
  pill = 11, mono = 12, tile_value = 15, tile_label = 11, meta = 12.5, bounce_date = 11.5,
}

-- Table and details geometry.
theme.table = { header_h = 34, row_h = 35, pad_x = 12 }

-- Statuses -------------------------------------------------------------------

local FIXED_STATUS = { Writing = theme.colors.writing, Mixing = theme.colors.mixing, Done = theme.colors.done }
theme.extra_status_colors = {
  0xB79CFFFF, -- violet
  0xFF8FB1FF, -- rose
  0x5FD3F3FF, -- sky
  0xE8D26AFF, -- straw
  0xFF9A6BFF, -- coral
  0xA8B4C8FF, -- slate
}
local DEFAULT_STATUSES = { "Writing", "Mixing", "Done" }

-- Colour for a status name. Writing, Mixing and Done are fixed; every other
-- status takes the next of the six extra colours by its order among the
-- user-added statuses in `statuses` (data.statuses), wrapping after six.
-- builtin (data.status_builtin) maps a renamed built-in to its first name
-- ({ Drafting = "Writing" }), so it keeps the built-in colour.
function theme.status_color(name, statuses, builtin)
  if name == nil then return theme.colors.sub end
  builtin = builtin or {}
  local function fixed(s) return FIXED_STATUS[builtin[s]] or FIXED_STATUS[s] end
  if fixed(name) then return fixed(name) end
  local k = 0
  for _, s in ipairs(statuses or DEFAULT_STATUSES) do
    if not fixed(s) then
      k = k + 1
      if s == name then
        local extra = theme.extra_status_colors
        return extra[(k - 1) % #extra + 1]
      end
    end
  end
  return theme.colors.sub
end

-- Window tint for an opacity setting (0..1); nil means the default 94 %.
function theme.tint(opacity)
  return theme.with_alpha(theme.colors.window_tint, opacity or theme.OPACITY)
end

-- Sheen corner alphas: the mockup's 160 degree gradient, white SHEEN_ALPHA at
-- the top-left fading to 0 at SHEEN_DEPTH of the gradient line. Returns the
-- top-left and top-right alpha for a w x h window (bottom of the band is 0).
function theme.sheen_alphas(w, h)
  local rad = math.rad(theme.SHEEN_ANGLE)
  local dx, dy = math.abs(math.sin(rad)), math.abs(math.cos(rad))
  local len = w * dx + h * dy
  local right = len > 0 and (w * dx / len) or 0
  local tr = theme.SHEEN_ALPHA * math.max(0, 1 - right / theme.SHEEN_DEPTH)
  return theme.SHEEN_ALPHA, tr
end

-- ImGui parts ----------------------------------------------------------------

local ImGui
theme.fonts = {}

local FONT_FAMILIES = {
  -- name = { family, fallback, bold }
  ui = { "Inter", "sans-serif", false },
  ui_bold = { "Inter", "sans-serif", true },
  brand = { "Space Grotesk", "sans-serif", true },
  mono = { "JetBrains Mono", "monospace", false },
}

local function make_font(family, fallback, bold)
  local flags = bold and ImGui.FontFlags_Bold or ImGui.FontFlags_None
  local ok, font = pcall(ImGui.CreateFont, family, flags)
  if ok and font then return font end
  ok, font = pcall(ImGui.CreateFont, fallback, flags)
  if ok and font then return font end
  return nil   -- PushFont(nil, size) keeps ImGui's default font
end

-- Call once after CreateContext and before the first frame.
function theme.init(imgui, ctx, grain_path)
  ImGui = imgui
  theme.ImGui = imgui
  for name, f in pairs(FONT_FAMILIES) do
    local font = make_font(f[1], f[2], f[3])
    if font then ImGui.Attach(ctx, font) end
    theme.fonts[name] = font
  end
  theme.grain = nil
  if grain_path then
    local ok, img = pcall(ImGui.CreateImage, grain_path)
    if ok and img then
      ImGui.Attach(ctx, img)
      theme.grain = img
    end
  end
end

function theme.push_font(ctx, name, size)
  ImGui.PushFont(ctx, theme.fonts[name], size or theme.sizes.body)
end

function theme.pop_font(ctx)
  ImGui.PopFont(ctx)
end

local pushed_colors, pushed_vars = 0, 0

local function col(ctx, name, c)
  local idx = rawget(ImGui, name)   -- skip colours this ReaImGui does not have
  if idx then
    ImGui.PushStyleColor(ctx, idx, c)
    pushed_colors = pushed_colors + 1
  end
end

local function var(ctx, name, x, y)
  local idx = rawget(ImGui, name)
  if idx then
    if y then ImGui.PushStyleVar(ctx, idx, x, y) else ImGui.PushStyleVar(ctx, idx, x) end
    pushed_vars = pushed_vars + 1
  end
end

-- Pushes the theme's style for one frame; pair with theme.pop(ctx).
function theme.push(ctx)
  local c = theme.colors
  pushed_colors, pushed_vars = 0, 0
  col(ctx, "Col_Text", c.ink)
  col(ctx, "Col_TextDisabled", c.sub)
  col(ctx, "Col_WindowBg", 0)
  col(ctx, "Col_ChildBg", 0)
  col(ctx, "Col_PopupBg", c.popup)
  col(ctx, "Col_Border", c.line)
  col(ctx, "Col_FrameBg", 0)
  col(ctx, "Col_FrameBgHovered", white(0.045))
  col(ctx, "Col_FrameBgActive", white(0.06))
  col(ctx, "Col_Button", white(0.06))
  col(ctx, "Col_ButtonHovered", white(0.10))
  col(ctx, "Col_ButtonActive", white(0.14))
  col(ctx, "Col_Header", c.selected)
  col(ctx, "Col_HeaderHovered", theme.with_alpha(teal, 0.08))
  col(ctx, "Col_HeaderActive", theme.with_alpha(teal, 0.18))
  col(ctx, "Col_CheckMark", teal)
  col(ctx, "Col_SliderGrab", teal)
  col(ctx, "Col_SliderGrabActive", teal)
  col(ctx, "Col_InputTextCursor", teal)
  col(ctx, "Col_TextSelectedBg", theme.with_alpha(teal, 0.30))
  col(ctx, "Col_NavCursor", theme.with_alpha(teal, 0.6))
  col(ctx, "Col_Separator", c.line)
  col(ctx, "Col_ScrollbarBg", 0)
  col(ctx, "Col_ScrollbarGrab", white(0.10))
  col(ctx, "Col_ScrollbarGrabHovered", white(0.16))
  col(ctx, "Col_ScrollbarGrabActive", white(0.22))
  col(ctx, "Col_ResizeGrip", 0)
  col(ctx, "Col_ResizeGripHovered", theme.with_alpha(teal, 0.35))
  col(ctx, "Col_ResizeGripActive", theme.with_alpha(teal, 0.6))
  col(ctx, "Col_TableHeaderBg", 0)
  col(ctx, "Col_TableBorderLight", c.row_line)
  col(ctx, "Col_TableBorderStrong", c.line)
  col(ctx, "Col_TableRowBg", 0)
  col(ctx, "Col_TableRowBgAlt", 0)
  col(ctx, "Col_ModalWindowDimBg", 0x00000080)
  var(ctx, "StyleVar_WindowPadding", 0, 0)
  var(ctx, "StyleVar_WindowRounding", theme.RADIUS)
  var(ctx, "StyleVar_WindowBorderSize", 0)
  var(ctx, "StyleVar_ChildBorderSize", 0)
  var(ctx, "StyleVar_PopupRounding", 12)
  var(ctx, "StyleVar_FrameRounding", 9)
  var(ctx, "StyleVar_FramePadding", 12, 7)
  var(ctx, "StyleVar_ItemSpacing", 12, 8)
  var(ctx, "StyleVar_ScrollbarSize", 10)
  var(ctx, "StyleVar_ScrollbarRounding", 6)
  var(ctx, "StyleVar_GrabRounding", 6)
end

function theme.pop(ctx)
  ImGui.PopStyleVar(ctx, pushed_vars)
  ImGui.PopStyleColor(ctx, pushed_colors)
  pushed_colors, pushed_vars = 0, 0
end

-- Fills one top corner of the sheen band as a quarter disc of colour c.
local function corner(dl, cx, cy, r, a_min, a_max, c)
  ImGui.DrawList_PathLineTo(dl, cx, cy)
  ImGui.DrawList_PathArcTo(dl, cx, cy, r, a_min, a_max, 8)
  ImGui.DrawList_PathFillConvex(dl, c)
end

-- The smoked glass: rounded tint, tiled grain, sheen and edges, drawn into
-- draw_list at (x, y, w, h). opacity is the tint alpha (data.opacity).
function theme.draw_glass(ctx, dl, x, y, w, h, opacity)
  local c, r = theme.colors, theme.RADIUS
  local x2, y2 = x + w, y + h
  ImGui.DrawList_AddRectFilled(dl, x, y, x2, y2, theme.tint(opacity), r)
  if theme.grain then
    local n = theme.GRAIN_SIZE
    ImGui.DrawList_AddImageRounded(dl, theme.grain, x, y, x2, y2, 0, 0, w / n, h / n,
      white(theme.GRAIN_ALPHA), r)
  end
  -- Sheen: a multi-colour rect below the corner radius, the strip between the
  -- corners above it, and a quarter disc in each top corner.
  local tl, tr = theme.sheen_alphas(w, h)
  local band = h * theme.SHEEN_DEPTH
  local at_r = 1 - r / band   -- sheen left at the bottom of the corner strip
  local tl_r, tr_r = white(tl * at_r), white(tr * at_r)
  ImGui.DrawList_AddRectFilledMultiColor(dl, x, y + r, x2, y + band, tl_r, tr_r, 0xFFFFFF00, 0xFFFFFF00)
  ImGui.DrawList_AddRectFilledMultiColor(dl, x + r, y, x2 - r, y + r, white(tl), white(tr), tr_r, tl_r)
  corner(dl, x + r, y + r, r, math.pi, 1.5 * math.pi, white(tl))
  corner(dl, x2 - r, y + r, r, 1.5 * math.pi, 2 * math.pi, white(tr))
  -- Edges: 1 px top highlight inside the window, then the window border.
  ImGui.DrawList_AddLine(dl, x + r, y + 1.5, x2 - r, y + 1.5, c.highlight, 1)
  ImGui.DrawList_AddRect(dl, x + 0.5, y + 0.5, x2 - 0.5, y2 - 0.5, c.border, r, 0, 1)
end

return theme
