-- The folder browser's navigation, without ImGui: where it starts, the
-- shortcuts, the breadcrumb, going into and up, and how many REAPER projects
-- each folder holds. Pure Lua 5.4; it reads folders only through P.list_dir
-- and never opens a file.
--
-- folders.project_folder(ini_text, home) -> REAPER's default project folder
--   (defsavepath in reaper.ini's [REAPER] section), else home/Documents; and
--   whether defsavepath was read. folders.suggestion_label names it.
-- folders.shortcuts({ P, os, home, drives }) -> { {label, path} }: Home,
--   Documents, Desktop, then the volumes under /Volumes (mac) or the drive
--   letters (win; drives = { "C:", ... }).
-- folders.usable(path) -> false for a root, a drive root, a bare \\server or
--   a relative path; network shares (\\server\share) are fine (ruling R30).
-- folders.new({ P, start }) -> nav:
--   nav:path(), nav:go(path), nav:into(name), nav:up(), nav:crumbs()
--   nav:entries() -> { {name, path, rpp} } folders only, no hidden ones
--     (leading "."), sorted by name; rpp is nil until counted.
--   nav:step(n) counts with at most n listings, or nav:step({ clock,
--     deadline, min }) until clock() reaches deadline, after at least min
--     listings; true when every count is in.
--     A count is the .RPP files inside the folder or one level down.
local M = {}

local function is_win_path(p)
  return p:match("^%a:") ~= nil or p:match("^[/\\][/\\]") ~= nil
end

local function is_rpp(name) return name:lower():match("%.rpp$") ~= nil end
local function hidden(name) return name:sub(1, 1) == "." end

-- The top of a path: "/" ; "C:\" ; "\\server\share" (nil for a bare \\server).
local function top_of(p)
  local unc = p:match("^([/\\][/\\][^/\\]+[/\\][^/\\]+)")
  if unc then return (unc:gsub("/", "\\")) end
  if p:match("^[/\\][/\\]") then return nil end
  local drive = p:match("^(%a:)")
  if drive then return drive .. "\\" end
  if p:sub(1, 1) == "/" then return "/" end
  return nil
end

local function trim_end(p)
  local t = top_of(p)
  local s = p:gsub("[/\\]+$", "")
  if t and #s < #t then return t end
  return s
end

function M.project_folder(ini_text, home)
  local fallback = home:gsub("[/\\]+$", "") .. (is_win_path(home) and "\\Documents" or "/Documents")
  if not ini_text then return fallback, false end
  local section
  for line in (ini_text .. "\n"):gmatch("([^\r\n]*)\r?\n") do
    local name = line:match("^%[(.-)%]%s*$")
    if name then
      section = name
    elseif section == "REAPER" then
      local v = line:match("^defsavepath=(.*)$")
      if v then
        v = v:gsub("%s+$", "")
        if top_of(v) then return v, true end
        return fallback, false
      end
    end
  end
  return fallback, false
end

-- The suggestion's text: REAPER's project folder only when defsavepath was
-- read; otherwise the plain folder, with the home folder shown as "~".
function M.suggestion_label(path, from_ini, home)
  if from_ini then return "Use " .. path .. " (REAPER's project folder)" end
  local h = home:gsub("[/\\]+$", "")
  if h ~= "" and path:sub(1, #h) == h then path = "~" .. path:sub(#h + 1) end
  return "Use " .. path
end

function M.usable(path)
  local p = tostring(path or "")
  local t = top_of(p)
  if not t then return false end
  if p:match("^[/\\][/\\]") then return true end  -- \\server\share and below
  return trim_end(p) ~= t
end

function M.shortcuts(o)
  local win = o.os == "win"
  local function join(a, b) return a:gsub("[/\\]+$", "") .. (win and "\\" or "/") .. b end
  local out = {
    { label = "Home", path = o.home },
    { label = "Documents", path = join(o.home, "Documents") },
    { label = "Desktop", path = join(o.home, "Desktop") },
  }
  if win then
    for _, d in ipairs(o.drives or {}) do out[#out + 1] = { label = d, path = d .. "\\" } end
  elseif o.os == "mac" then
    local vols = {}
    for _, e in ipairs(o.P.list_dir("/Volumes") or {}) do
      if e.is_dir and not hidden(e.name) then vols[#vols + 1] = e end
    end
    table.sort(vols, function(a, b) return a.name:lower() < b.name:lower() end)
    for _, e in ipairs(vols) do out[#out + 1] = { label = e.name, path = e.path } end
  end
  return out
end

function M.new(o)
  local P = o.P
  local nav = {}
  local cur, list, work

  local function subfolders(entries)
    local out = {}
    for _, e in ipairs(entries) do
      if e.is_dir and not hidden(e.name) then out[#out + 1] = e end
    end
    return out
  end

  local function count_rpp(entries)
    local n = 0
    for _, e in ipairs(entries) do
      if not e.is_dir and is_rpp(e.name) then n = n + 1 end
    end
    return n
  end

  function nav:go(path)
    cur = trim_end(path)
    list = subfolders(P.list_dir(cur) or {})
    table.sort(list, function(a, b)
      local la, lb = a.name:lower(), b.name:lower()
      if la ~= lb then return la < lb end
      return a.name < b.name
    end)
    local entries = {}
    work = {}
    for i, e in ipairs(list) do
      entries[i] = { name = e.name, path = e.path }
      work[#work + 1] = { entry = entries[i], dir = e.path, first = true }
    end
    list = entries
  end

  function nav:path() return cur end
  function nav:entries() return list end

  function nav:into(name)
    for _, e in ipairs(list) do
      if e.name == name then return nav:go(e.path) end
    end
  end

  function nav:up()
    local t = top_of(cur)
    if not t or cur == t then return end
    local parent = cur:match("^(.*)[/\\][^/\\]*$") or t
    if #parent < #t then parent = t end
    nav:go(parent)
  end

  function nav:crumbs()
    local t = top_of(cur)
    if not t then return { { label = cur, path = cur } } end
    local out = { { label = t, path = t } }
    local rest = cur:sub(#t + 1)
    local sep = is_win_path(cur) and "\\" or "/"
    local path = t
    for part in rest:gmatch("[^/\\]+") do
      path = (path:sub(-1) == "\\" or path:sub(-1) == "/") and (path .. part) or (path .. sep .. part)
      out[#out + 1] = { label = part, path = path }
    end
    return out
  end

  -- Each entry gathers its own count and its subfolders' into acc; rpp is
  -- set once nothing for it is left to list.
  function nav:step(n)
    local limit, clock, deadline, min = n, nil, nil, 0
    if type(n) == "table" then
      limit, clock, deadline, min = math.huge, n.clock, n.deadline, n.min or 0
    end
    local done = 0
    while #work > 0 and done < limit do
      if clock and done >= min and clock() >= deadline then break end
      local job = table.remove(work, 1)
      local e = job.entry
      local entries = P.list_dir(job.dir) or {}
      done = done + 1
      e.acc = (e.acc or 0) + count_rpp(entries)
      e.pending = (e.pending or 1) - 1
      if job.first then
        for _, sub in ipairs(subfolders(entries)) do
          e.pending = e.pending + 1
          table.insert(work, 1, { entry = e, dir = sub.path })
        end
      end
      if e.pending == 0 then e.rpp, e.acc, e.pending = e.acc, nil, nil end
    end
    return #work == 0
  end

  nav:go(o.start)
  return nav
end

return M
