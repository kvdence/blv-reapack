-- Text for the table and details panel. Pure Lua (no ImGui, no reaper.*).
local M = {}

local DASH = "—"
local MIN, HOUR, DAY = 60, 3600, 86400
local MONTHS = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }

-- Age of timestamp t at now: "now", "5m", "3h", "2d", "1w", "1mo", "1y".
function M.ago(t, now)
  if t == nil then return DASH end
  local d = (now or os.time()) - t
  if d < MIN then return "now" end
  if d < HOUR then return math.floor(d / MIN) .. "m" end
  if d < DAY then return math.floor(d / HOUR) .. "h" end
  if d < 7 * DAY then return math.floor(d / DAY) .. "d" end
  if d < 30 * DAY then return math.floor(d / (7 * DAY)) .. "w" end
  if d < 365 * DAY then return math.floor(d / (30 * DAY)) .. "mo" end
  return math.floor(d / (365 * DAY)) .. "y"
end

-- "14 Oct 23:15" in local time; month names are English whatever the locale.
function M.date(t)
  if t == nil then return DASH end
  local d = os.date("*t", t)
  return string.format("%02d %s %02d:%02d", d.day, MONTHS[d.month], d.hour, d.min)
end

-- Seconds as "3:41", or "1:02:03" from an hour.
function M.length(sec)
  local s = math.floor(tonumber(sec) or 0)
  if s < 0 then s = 0 end
  local h, m = s // 3600, (s % 3600) // 60
  if h > 0 then return string.format("%d:%02d:%02d", h, m, s % 60) end
  return string.format("%d:%02d", m, s % 60)
end

-- Bytes as "512 B", "1.5 KB", "84 KB", "1.8 GB" (1000-based, as Finder shows).
function M.size(bytes)
  if bytes == nil then return DASH end
  if bytes < 1000 then return string.format("%d B", bytes) end
  local units = { "KB", "MB", "GB", "TB" }
  local v, i = bytes / 1000, 1
  while v >= 1000 and i < #units do v, i = v / 1000, i + 1 end
  if v < 10 then
    local s = string.format("%.1f", v):gsub("%.0$", "")
    return s .. " " .. units[i]
  end
  return string.format("%d %s", math.floor(v + 0.5), units[i])
end

-- Time worked: "—" (none), "<1 min", "45 min", "3 h 20 min", "12 h".
function M.worked(sec)
  local s = math.floor(tonumber(sec) or 0)
  if s <= 0 then return DASH end
  if s < MIN then return "<1 min" end
  if s < HOUR then return math.floor(s / MIN) .. " min" end
  local h, m = s // HOUR, (s % HOUR) // MIN
  if h >= 10 or m == 0 then return h .. " h" end
  return h .. " h " .. m .. " min"
end

-- Tempo without a trailing ".0"; at most two decimals.
function M.bpm(tempo)
  if tempo == nil then return DASH end
  local s = string.format("%.2f", tempo):gsub("0+$", ""):gsub("%.$", "")
  return s
end

function M.file_name(path)
  return tostring(path or ""):match("([^/\\]*)$")
end

-- "MASTER wav": the bounce's purpose and its extension in lower case. With
-- no purpose (the file is named like the project) the file name stands in.
function M.bounce_label(b)
  local base, ext = M.file_name(b.name):match("^(.*)%.([^%.]+)$")
  base, ext = base or b.name, (ext or ""):lower()
  local purpose = b.purpose
  if purpose == nil or purpose == "" then purpose = base end
  return ext ~= "" and (purpose .. " " .. ext) or purpose
end

function M.open_error(err)
  if err == "missing" then return "That project file is no longer there." end
  if err == "not opened" then return "REAPER did not open it (the save prompt was cancelled)." end
  if err == "not opened in new tab" then return "REAPER did not open it in a new tab." end
  if err == "no new tab" then return "REAPER did not make a new project tab." end
  if tostring(err):find("7%.74") then return "Needs REAPER 7.74 or newer." end
  return "Could not open: " .. tostring(err)
end

-- query with typed characters (Unicode code points) added and `backspaces`
-- characters (not bytes) removed from its end. Control characters are skipped.
function M.type_into(query, codepoints, backspaces)
  local q = query or ""
  for _ = 1, backspaces or 0 do
    if q == "" then break end
    q = q:sub(1, (utf8.offset(q, -1) or 1) - 1)
  end
  for _, c in ipairs(codepoints or {}) do
    if c >= 32 and c ~= 127 then q = q .. utf8.char(c) end
  end
  return q
end

function M.count(n, word)
  return n .. " " .. word .. (n == 1 and "" or "s")
end

-- The line the table shows when it has no rows. c = { scanning, query, view,
-- no_sources } (no_sources: no scan folders and no recent projects).
function M.empty_message(c)
  if c.scanning then return "Scanning…" end
  local q = c.query or ""
  local v = c.view or {}
  if q:find("%S") then
    return 'No ' .. (v.group == "templates" and "templates" or "songs") .. ' match "' .. q .. '".'
  end
  if c.no_sources then return "No projects yet. Add a scan folder in Settings." end
  if v.group == "pinned" then return "No pinned songs." end
  if v.group == "hidden" then return "No hidden songs." end
  if v.group == "status" then return "No songs marked " .. tostring(v.value) .. "." end
  if v.group == "artist" then return "No songs by " .. tostring(v.value) .. "." end
  if v.group == "templates" then
    if v.value == "track" then return "No track templates in REAPER's TrackTemplates folder." end
    return "No project templates in REAPER's ProjectTemplates folder."
  end
  return "No songs yet."
end

return M
