-- The REAPER bridge: the ONLY module that calls reaper.*.
-- Everything else gets REAPER's state through these functions.
local platform = require("realobby.platform")
local online = require("realobby.online")

local B = {}

-- Confirmed in a portable REAPER 7.79 (Task 10 spike; see the task report):
-- Main_openProject loads with all FX offline when the name starts with
-- "fxoffline:" (REAPER 7.74+, the same as "Open with FX offline (recovery mode)").
B.FX_OFFLINE_PREFIX = "fxoffline:"
B.FX_OFFLINE_MIN_VERSION = { 7, 74 }
B.TEMPLATE_PREFIX = "template:"
-- Main section actions. REAPER has no same-tab "ignore default template"
-- action, so both kinds of new project open in a new tab.
B.ACTION_NEW_TAB = 40859                 -- New project tab
B.ACTION_NEW_TAB_IGNORE_DEFAULT = 41929  -- New project tab, ignore default template
B.ACTION_CLOSE_TAB = 40860               -- Close current project tab
-- reaper.ini loadlastproj (REAPER 7.60+): 16 marks the current format and the
-- low four bits are "Open project(s) on startup": 0 last active project,
-- 1 last project tabs, 2 new project ignoring default template, 3 new project,
-- 4 Prompt (the Choose Project window). Owner's value 20 = 16 + 4.
B.LOADLASTPROJ_FORMAT = 16
B.LOADLASTPROJ_PROMPT = 4

B.START_MARK = "-- BLV ReaLobby: start"
B.END_MARK = "-- BLV ReaLobby: end"
local NOTE_BREAK = "-- (ReaLobby added the line break before this block)"
local NOTE_CREATED = "-- (ReaLobby created this file)"
local EXEC_TIMEOUT_MS = 10000

local function res_path()
  return reaper.GetResourcePath()
end

local function read_file(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local s = f:read("a")
  f:close()
  return s
end

local function write_file(path, s)
  local f, err = io.open(path, "wb")
  if not f then return false, err end
  local ok, werr = f:write(s)
  local cok, cerr = f:close()
  if not ok then return false, werr end
  if not cok then return false, cerr end
  return true
end

function B.os()
  local o = reaper.GetOS()
  if o:find("^Win") then return "win" end
  if o:find("^OSX") or o:find("^macOS") then return "mac" end
  return "linux"
end

-- ExecProcess returns "<exit code>\n<output>", or nil / a negative code alone
-- (-1 no wait, -3 timed out, -999 could not start) when the command did not
-- finish. Those come back as a plain message without platform's success
-- marker, so platform's checked commands report a failure.
-- ExecProcess starts the program directly, without a shell, while platform.lua
-- builds shell command lines. On Windows the line goes to cmd.exe as it is
-- (CreateProcess passes it unchanged). On mac and linux ExecProcess splits the
-- line itself and mangles quotes, so the line is written to a temporary file
-- (Lua's /tmp/lua_XXXXXX name has no spaces) and run with /bin/sh.
function B.run(cmd)
  local r
  if B.os() == "win" then
    r = reaper.ExecProcess('cmd.exe /S /C "' .. cmd .. '"', EXEC_TIMEOUT_MS)
  else
    local tmp = os.tmpname()
    local f = io.open(tmp, "wb")
    if not f then os.remove(tmp); return "could not write a temporary command file" end
    f:write(cmd, "\n")
    f:close()
    r = reaper.ExecProcess("/bin/sh " .. tmp, EXEC_TIMEOUT_MS)
    os.remove(tmp)
  end
  if r == nil then return "command could not be started" end
  local code, output = r:match("^(%-?%d+)\r?\n(.*)$")
  if not code then code, output = r:match("^(%-?%d+)$"), "" end
  code = tonumber(code)
  if code == nil then return r end
  if code < 0 then
    return code == -3 and "command timed out" or ("command did not finish (" .. code .. ")")
  end
  return output
end

local P_cache
function B.platform()
  P_cache = P_cache or platform.new(B.os(), B.run)
  return P_cache
end

-- Paths compare in this form: forward slashes, lower case on mac and win.
function B.normalize(path)
  local p = tostring(path):gsub("\\", "/")
  if B.os() ~= "linux" then p = p:lower() end
  return p
end

-- REAPER's recent projects, most recent first ([Recent] recentNN in reaper.ini).
function B.recent()
  local text = read_file(reaper.get_ini_file()) or ""
  local list, in_recent = {}, false
  for line in (text .. "\n"):gmatch("(.-)\r?\n") do
    local section = line:match("^%[(.*)%]%s*$")
    if section then
      in_recent = section:lower() == "recent"
    elseif in_recent then
      local n, path = line:match("^[Rr]ecent(%d+)=(.*)$")
      if n and path ~= "" then list[#list + 1] = { n = tonumber(n), path = path } end
    end
  end
  table.sort(list, function(a, b) return a.n < b.n end)
  local out = {}
  for i, e in ipairs(list) do out[i] = e.path end
  return out
end

-- Installed FX keyed the way a project file names them (rpp.lua fx.file):
-- the plug-in file name for VST/VST3 (ident is a full path, maybe with
-- "<id" after it), the "Maker: Name" ident for AU, the id for CLAP.
function B.installed_fx()
  local set, i = {}, 0
  while true do
    local ok, _, ident = reaper.EnumInstalledFX(i)
    if not ok then break end
    if ident and ident ~= "" then
      set[ident] = true
      local file, id = ident:match("^(.-)<(.*)$")
      file = file or ident
      local base = file:match("([^/\\]+)$")
      if base and base ~= "" then set[base] = true end
      if id and id ~= "" then set[id] = true end
    end
    i = i + 1
  end
  return set
end

-- Every project open in a REAPER tab, keyed by B.normalize(path).
function B.open_projects()
  local set, i = {}, 0
  while true do
    local proj, fn = reaper.EnumProjects(i)
    if not proj then break end
    if fn and fn ~= "" then set[B.normalize(fn)] = true end
    i = i + 1
  end
  return set
end

-- The tab whose project file is path (compared with B.normalize), or nil.
function B.find_open_tab(path)
  local want, i = B.normalize(path), 0
  while true do
    local proj, fn = reaper.EnumProjects(i)
    if not proj then return nil end
    if fn and fn ~= "" and B.normalize(fn) == want then return proj end
    i = i + 1
  end
end

local function current_file()
  local _, fn = reaper.EnumProjects(-1)
  return fn or ""
end

local function version_at_least(want)
  local major, minor = reaper.GetAppVersion():match("^(%d+)%.(%d+)")
  major, minor = tonumber(major) or 0, tonumber(minor) or 0
  return major > want[1] or (major == want[1] and minor >= want[2])
end

-- True when this REAPER can open a project with FX offline (7.74+); the UI
-- disables "Open safely" otherwise.
function B.fx_offline_supported()
  return version_at_least(B.FX_OFFLINE_MIN_VERSION)
end

-- REAPER's folder for timestamped backups (Preferences > Project > Backups),
-- absolute or relative to the project; nil when not set.
function B.backup_dir()
  local ok, v = reaper.get_config_var_string("autosavedir")
  if ok and v and v ~= "" then return v end
  return nil
end

-- Closes the tab B.open made when nothing loaded into it: still untitled,
-- unchanged and empty. Then the tab that was current before comes back.
local function close_empty_tab(created, before)
  if not reaper.ValidatePtr(created, "ReaProject*") then return end
  reaper.SelectProjectInstance(created)
  local _, fn = reaper.EnumProjects(-1)
  if (fn or "") == "" and reaper.IsProjectDirty(created) == 0 and reaper.CountTracks(created) == 0
      and reaper.CountMediaItems(created) == 0 then
    reaper.Main_OnCommand(B.ACTION_CLOSE_TAB, 0)
  end
  if before and reaper.ValidatePtr(before, "ReaProject*") then reaper.SelectProjectInstance(before) end
end

-- opts = { fx_offline, online_after, new_tab } (realobby/open_options.lua).
-- Either FX choice loads the project with every FX offline; online_after's
-- online pass is the caller's (B.fx_online_pass). new_tab first makes a new
-- tab without the default template. In a portable REAPER 7.79 both new-tab
-- actions leave an unchanged tab that the open replaces without a save
-- prompt, but 40859 first loads the default template, whose plug-ins would
-- load online even for a recovery open; 41929 loads nothing. The current tab
-- keeps its project.
-- A song already open in another tab (or in any tab, for new_tab) is not
-- loaded a second time: REAPER switches to that tab and this returns
-- true, that project, "switched".
-- Returns true and the project opened, or false and why. In the current tab
-- REAPER asks to save unsaved changes first; a cancel returns "not opened".
-- A new tab that did not get the project is closed again.
function B.open(path, opts)
  if opts ~= nil and type(opts) ~= "table" then return false, "bad options" end
  opts = opts or {}
  local offline = opts.fx_offline == true or opts.online_after == true
  if offline and not version_at_least(B.FX_OFFLINE_MIN_VERSION) then
    return false, "needs REAPER 7.74 or later"
  end
  if not reaper.file_exists(path) then return false, "missing" end
  local before = reaper.EnumProjects(-1)
  local open_tab = B.find_open_tab(path)
  if open_tab and (opts.new_tab or open_tab ~= before) then
    reaper.SelectProjectInstance(open_tab)
    return true, open_tab, "switched"
  end
  local created
  if opts.new_tab then
    reaper.Main_OnCommand(B.ACTION_NEW_TAB_IGNORE_DEFAULT, 0)
    created = reaper.EnumProjects(-1)
    if created == before then return false, "no new tab" end
  end
  local target = reaper.EnumProjects(-1)
  local changes = reaper.GetProjectStateChangeCount(target)
  reaper.Main_openProject((offline and B.FX_OFFLINE_PREFIX or "") .. path)
  local proj = reaper.EnumProjects(-1)
  local now = B.normalize(current_file())
  local ok
  if path:lower():match("%.rpp%-bak$") then
    -- REAPER opens a backup (.rpp-bak) as an untitled project (smoke-tested),
    -- so a save cannot overwrite the backup. In a new tab, which is untitled
    -- too, the load shows as a change of the tab's state count.
    ok = now == "" and (not created or (proj == created and reaper.GetProjectStateChangeCount(created) ~= changes))
  else
    ok = now == B.normalize(path) and (not created or proj == created)
  end
  if not ok then
    if created then close_empty_tab(created, before) end
    return false, created and "not opened in new tab" or "not opened"
  end
  return true, proj
end

-- The file name of an open project ("" when untitled), nil when it is closed.
local function project_file(proj)
  local i = 0
  while true do
    local p, fn = reaper.EnumProjects(i)
    if not p then return nil end
    if p == proj then return fn or "" end
    i = i + 1
  end
end

local function take_guid(take)
  local _, g = reaper.GetSetMediaItemTakeInfo_String(take, "GUID", "", false)
  return g
end

-- Tracks and takes of proj by GUID, looked up once when the pass starts.
local function guid_maps(proj)
  local tracks, takes = {}, {}
  for i = 0, reaper.CountTracks(proj) - 1 do
    local tr = reaper.GetTrack(proj, i)
    tracks[reaper.GetTrackGUID(tr)] = tr
    for j = 0, reaper.CountTrackMediaItems(tr) - 1 do
      local item = reaper.GetTrackMediaItem(tr, j)
      for k = 0, reaper.CountTakes(item) - 1 do
        local take = reaper.GetTake(item, k)
        if take then
          local g = take_guid(take)
          if g and g ~= "" then takes[g] = take end
        end
      end
    end
  end
  return tracks, takes
end

local REC_FX = 0x1000000   -- TrackFX index offset of a track's input FX
B.UNDO_STATE_FX = 2
B.UNDO_STATE_ITEMS = 4

-- The online pass for "Bring FX online after load" (realobby/online.lua):
-- every FX of proj that the file (chains: rpp.fx_chains, read before the
-- open) saved online, found by its FX GUID when it is brought online. Before
-- each FX the project must still hold the same file, and the track or take
-- must still be there with the same GUID; otherwise that FX stays offline.
function B.fx_online_pass(proj, chains)
  local tracks, takes = guid_maps(proj)
  local file = project_file(proj)
  local touched_take = false
  local live = {
    object = function(ref)
      if ref.kind == "master" then return reaper.GetMasterTrack(proj) end
      if ref.kind == "take" then
        local take = takes[ref.guid]
        if take and reaper.ValidatePtr2(proj, take, "MediaItem_Take*") and take_guid(take) == ref.guid then return take end
        return nil
      end
      local tr = tracks[ref.guid]
      if tr and reaper.ValidatePtr2(proj, tr, "MediaTrack*") and reaper.GetTrackGUID(tr) == ref.guid then return tr end
      return nil
    end,
    count = function(ref, obj)
      if ref.kind == "take" then return reaper.TakeFX_GetCount(obj) end
      if ref.kind == "rec" then return reaper.TrackFX_GetRecCount(obj) end
      return reaper.TrackFX_GetCount(obj)
    end,
    fx_guid = function(ref, obj, i)
      if ref.kind == "take" then return reaper.TakeFX_GetFXGUID(obj, i) end
      return reaper.TrackFX_GetFXGUID(obj, ref.kind == "rec" and REC_FX + i or i)
    end,
    set_online = function(ref, obj, i)
      if ref.kind == "take" then
        touched_take = true
        reaper.TakeFX_SetOffline(obj, i, false)
      else
        reaper.TrackFX_SetOffline(obj, ref.kind == "rec" and REC_FX + i or i, false)
      end
    end,
  }
  return online.new(online.refs(chains), {
    clock = reaper.time_precise,
    alive = function()
      return reaper.ValidatePtr(proj, "ReaProject*") and project_file(proj) == file
    end,
    -- One undo point per step instead of one per FX.
    begin_step = function()
      touched_take = false
      reaper.PreventUIRefresh(1)
      reaper.Undo_BeginBlock2(proj)
    end,
    end_step = function()
      reaper.Undo_EndBlock2(proj, "BLV ReaLobby: bring FX online",
        B.UNDO_STATE_FX | (touched_take and B.UNDO_STATE_ITEMS or 0))
      reaper.PreventUIRefresh(-1)
    end,
    apply = function(ref) online.apply(ref, live) end,
  })
end

-- Progress of an online pass, shared through REAPER's ExtState (not saved).
function B.online_progress_set(s) reaper.SetExtState("BLV_ReaLobby", "online", s or "", false) end
function B.online_progress_get() return reaper.GetExtState("BLV_ReaLobby", "online") end

function B.new_empty(ignore_default)
  reaper.Main_OnCommand(ignore_default and B.ACTION_NEW_TAB_IGNORE_DEFAULT or B.ACTION_NEW_TAB, 0)
  return true
end

-- Makes folder/name/name.RPP from a project template and opens it.
-- Never overwrites: returns false, "exists" when that file is already there.
function B.new_from_template(template_path, name, folder)
  if type(name) ~= "string" or name == "" or name == "." or name == ".."
      or name:find('[/\\:*?"<>|%c]') or name:find("^%s") or name:find("[%s.]$") then
    return false, "bad name"
  end
  if not reaper.file_exists(template_path) then return false, "missing template" end
  local P = B.platform()
  local dir = P.join(folder, name)
  local file = P.join(dir, name .. ".RPP")
  if reaper.file_exists(file) then return false, "exists" end
  local ok, err = P.mkdir(dir)
  if not ok then return false, err end
  reaper.Main_openProject(B.TEMPLATE_PREFIX .. template_path)
  -- A template opens as a new, unsaved and unchanged project. Anything else
  -- means the user cancelled REAPER's save prompt and the old project is still here.
  if current_file() ~= "" or reaper.IsProjectDirty(0) ~= 0 then return false, "not opened" end
  if reaper.file_exists(file) then return false, "exists" end
  reaper.Main_SaveProjectEx(0, file, 8) -- 8: becomes this project's file name
  if not reaper.file_exists(file) then return false, "not saved" end
  return true, file
end

local function walk(dir, want, out)
  local join = B.platform().join
  local i = 0
  reaper.EnumerateFiles(dir, -1)
  while true do
    local f = reaper.EnumerateFiles(dir, i)
    if not f then break end
    if f:lower():sub(-#want) == want then out[#out + 1] = join(dir, f) end
    i = i + 1
  end
  i = 0
  reaper.EnumerateSubdirectories(dir, -1)
  while true do
    local d = reaper.EnumerateSubdirectories(dir, i)
    if not d then break end
    walk(join(dir, d), want, out)
    i = i + 1
  end
  return out
end

function B.templates()
  local res = res_path()
  local join = B.platform().join
  local project = walk(join(res, "ProjectTemplates"), ".rpp", {})
  local track = walk(join(res, "TrackTemplates"), ".rtracktemplate", {})
  table.sort(project)
  table.sort(track)
  return { project = project, track = track }
end

-- The folder browser (realobby/ui/folders.lua) reads REAPER's default
-- project folder, the home folder and, on Windows, the drive letters here.
function B.home()
  return os.getenv("HOME") or os.getenv("USERPROFILE") or "/"
end

function B.ini_text()
  return read_file(reaper.get_ini_file())
end

-- Windows drive letters ("C:", ...); not checked on Windows yet.
function B.drives()
  if B.os() ~= "win" then return {} end
  local out = {}
  local text = B.run('powershell -NoProfile -Command "[System.IO.DriveInfo]::GetDrives() | ForEach-Object { $_.Name }"') or ""
  for d in text:gmatch("(%a:)\\") do out[#out + 1] = d end
  return out
end

-- Action list ---------------------------------------------------------------

-- true when reaper-kb.ini text already lists a Main-section script whose path
-- ends in file_name (lines read: SCR <flags> <section> <id> "name" "path").
function B.action_listed(kb_text, file_name)
  for line in ((kb_text or "") .. "\n"):gmatch("([^\r\n]*)\r?\n") do
    if line:match("^SCR %d+ 0 ") then
      -- REAPER quotes the path only when it has spaces.
      local path = line:match('"([^"]*)"%s*$') or line:match("(%S+)%s*$") or ""
      if path == file_name or path:sub(-#file_name - 1) == "/" .. file_name
        or path:sub(-#file_name - 1) == "\\" .. file_name then
        return true
      end
    end
  end
  return false
end

-- Adds ReaLobby to REAPER's action list (Main section) once, so it can be run
-- from the Actions window, given a shortcut or put on a toolbar at any time.
-- ReaPack lists it itself; this covers a copy installed by hand.
function B.ensure_action(entry_path)
  if not reaper.AddRemoveReaScript then return false end
  local name = entry_path:match("[^/\\]+$") or entry_path
  if B.action_listed(read_file(res_path() .. "/reaper-kb.ini"), name) then return true end
  return reaper.AddRemoveReaScript(true, 0, entry_path, true) ~= 0
end

-- The time counter (BLV_ReaLobby_Timer.lua) ----------------------------------

B.TIMER_SECTION = "BLV_ReaLobby_Timer"
B.TIMER_FRESH = 10.0   -- seconds; it beats once a second

-- true when the counter's heartbeat is younger than B.TIMER_FRESH seconds.
function B.timer_running()
  local beat = tonumber(reaper.GetExtState(B.TIMER_SECTION, "heartbeat") or "")
  local now = reaper.time_precise()
  return beat ~= nil and now >= beat and now - beat < B.TIMER_FRESH
end

-- Starts the counter unless it is running. It is listed in the action list
-- (Script: BLV_ReaLobby_Timer.lua) so REAPER can run it.
function B.start_timer(timer_path)
  if B.timer_running() then return true end
  if not (reaper.AddRemoveReaScript and reaper.file_exists(timer_path)) then return false end
  reaper.SetExtState(B.TIMER_SECTION, "stop", "", false)
  local id = reaper.AddRemoveReaScript(true, 0, timer_path, true)
  if not id or id == 0 then return false end
  reaper.Main_OnCommand(id, 0)
  return true
end

-- Asks a running counter to save and stop.
function B.stop_timer()
  reaper.SetExtState(B.TIMER_SECTION, "stop", "1", false)
end

-- true when REAPER ran this file as an action (not through the startup hook).
function B.run_as_action(entry_path)
  if not reaper.get_action_context then return false end
  local _, file = reaper.get_action_context()
  return file ~= nil and B.normalize(file) == B.normalize(entry_path)
end

-- Startup hook --------------------------------------------------------------

local function startup_path()
  return res_path() .. "/Scripts/__startup.lua"
end

-- Finds the first ReaLobby block: start, finish (inclusive) and whether
-- ReaLobby added the line break before it / created the file.
local function find_block(text)
  local pos = 1
  while true do
    local a = text:find(B.START_MARK, pos, true)
    if not a then return nil end
    if a == 1 or text:sub(a - 1, a - 1) == "\n" then
      local e1, e2 = text:find("\n" .. B.END_MARK, a, true)
      if not e1 then return nil, "unfinished" end
      local finish = e1 + #B.END_MARK
      local nl = text:match("^\r?\n", finish + 1)
      if nl then finish = finish + #nl end
      local body = text:sub(a, finish)
      local start = a
      if body:find(NOTE_BREAK, 1, true) then
        local brk = text:sub(1, a - 1):match("\r?\n$")
        if brk then start = a - #brk end
      end
      return start, finish, body:find(NOTE_CREATED, 1, true) ~= nil
    end
    pos = a + 1
  end
end

local function block_text(rel, eol, note)
  local lines = { B.START_MARK }
  if note then lines[#lines + 1] = note end
  lines[#lines + 1] = "-- Opens BLV ReaLobby when REAPER starts. Remove it from ReaLobby's settings."
  lines[#lines + 1] = "do"
  lines[#lines + 1] = ("  local path = reaper.GetResourcePath() .. \"/\" .. %q"):format(rel)
  lines[#lines + 1] = "  if reaper.file_exists(path) then"
  lines[#lines + 1] = "    local ok, err = pcall(dofile, path)"
  lines[#lines + 1] = "    if not ok then reaper.ShowConsoleMsg(\"BLV ReaLobby did not start: \" .. tostring(err) .. \"\\n\") end"
  lines[#lines + 1] = "  end"
  lines[#lines + 1] = "end"
  lines[#lines + 1] = B.END_MARK
  return table.concat(lines, eol) .. eol
end

local function default_entry()
  local src = debug.getinfo(1, "S").source:gsub("^@", "")
  local root = src:match("^(.*)[/\\]realobby[/\\]bridge%.lua$") or "."
  return root .. "/BLV_ReaLobby.lua"
end

-- Writes text to path through a temporary file, so a failed write leaves the
-- old file as it was.
local function replace_file(path, text)
  local tmp = path .. ".realobby-tmp"
  local ok, err = write_file(tmp, text)
  if not ok or read_file(tmp) ~= text then
    os.remove(tmp)
    return false, err or "could not write " .. tmp
  end
  if B.os() == "win" and reaper.file_exists(path) then
    local ok2, err2 = os.remove(path)
    if not ok2 then os.remove(tmp); return false, err2 end
  end
  local ok3, err3 = os.rename(tmp, path)
  if not ok3 then return false, err3 end
  return true
end

function B.startup_installed()
  local text = read_file(startup_path())
  return text ~= nil and find_block(text) ~= nil
end

-- Adds (or refreshes) the one ReaLobby block in Scripts/__startup.lua. The
-- block finds entry_path (default: BLV_ReaLobby.lua next to this module)
-- relative to REAPER's resource folder when REAPER starts.
function B.install_startup(entry_path)
  local res = res_path()
  local entry = entry_path or default_entry()
  local rp, ep = B.normalize(res):gsub("/+$", "") .. "/", B.normalize(entry)
  if ep:sub(1, #rp) ~= rp then return false, "ReaLobby is not inside REAPER's resource folder" end
  local rel = entry:gsub("\\", "/"):sub(#rp + 1)
  local path = startup_path()
  local old = read_file(path)
  local eol = old and old:find("\r\n", 1, true) and "\r\n" or "\n"
  local new
  if old then
    local a, b, created = find_block(old)
    if a then
      local note = created and NOTE_CREATED or (old:sub(a, b):find(NOTE_BREAK, 1, true) and NOTE_BREAK) or nil
      local lead = note == NOTE_BREAK and old:sub(a, b):match("^\r?\n") or ""
      new = old:sub(1, a - 1) .. lead .. block_text(rel, eol, note) .. old:sub(b + 1)
      if new == old then return true end
    elseif b == "unfinished" then
      return false, "__startup.lua has an unfinished ReaLobby block"
    else
      -- The user's own file: back it up first (replacing only ReaLobby's own older backup).
      local ok, err = replace_file(path .. ".bak-realobby", old)
      if not ok then return false, "backup failed: " .. tostring(err) end
      if old == "" or old:sub(-1) == "\n" then
        new = old .. block_text(rel, eol, nil)
      else
        new = old .. eol .. block_text(rel, eol, NOTE_BREAK)
      end
    end
  else
    new = block_text(rel, eol, NOTE_CREATED)
  end
  return replace_file(path, new)
end

-- Removes exactly the ReaLobby block(s); a file ReaLobby created is deleted
-- again when nothing else is left in it.
function B.remove_startup()
  local path = startup_path()
  local text = read_file(path)
  if not text then return true end
  local created = false
  while true do
    local a, b, c = find_block(text)
    if b == "unfinished" then return false, "__startup.lua has an unfinished ReaLobby block" end
    if not a then break end
    created = created or c
    text = text:sub(1, a - 1) .. text:sub(b + 1)
  end
  if created and text == "" then
    local ok, err = os.remove(path)
    if not ok then return false, err end
    return true
  end
  return replace_file(path, text)
end

-- REAPER's Choose Project prompt at startup ------------------------------------

function B.prompt_flag(value)
  local v = math.tointeger(tonumber(value))
  if not v then return false end
  -- Higher bits did not show the prompt at startup in the spike (52, 84).
  return v & B.LOADLASTPROJ_FORMAT ~= 0 and v & 15 == B.LOADLASTPROJ_PROMPT and v >> 5 == 0
end

-- Reads loadlastproj (REAPER's live value, else reaper.ini). Never writes it.
function B.reaper_prompt_on()
  local ok, v = reaper.get_config_var_string("loadlastproj")
  if not ok then
    local text = read_file(reaper.get_ini_file()) or ""
    v = text:match("\n[Ll]oadlastproj=(%-?%d+)") or text:match("^[Ll]oadlastproj=(%-?%d+)")
  end
  return B.prompt_flag(v)
end

return B
