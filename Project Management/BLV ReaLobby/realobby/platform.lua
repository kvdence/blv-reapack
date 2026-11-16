-- Platform helpers: the ONLY place shell commands are built.
-- platform.new(os_name, run, start) where run(cmd) -> output text, and false
-- when the command did not finish (REAPER: reaper.ExecProcess); start(cmd, ps)
-- (optional) -> a job, or nil: job.poll() -> nil while the command runs, its
-- output, or false when it never ended. On Windows ps is the PowerShell
-- script inside cmd (nil for a plain command), so a helper that is already
-- PowerShell can run it without starting PowerShell again.
-- A listing whose command did not finish is an empty list with failed = true.
-- With start, P.list_dir_start and P.list_tree_start list without waiting:
-- they return nil (list the waiting way) or a job whose poll() gives nil
-- while it runs and the entries once it is done.
local M = {}

M.TRASH_BATCH = 50
M.PARSE_LINES = 400   -- lines of a background listing read per poll

local OK = "__BLV_OK__"
local SF_DATALESS = 0x40000000
local WIN_OFFLINE = 0x1000
local WIN_RECALL = 0x400000

local function posix_quote(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

-- PowerShell single-quoted literal (' doubled).
local function ps_quote(s)
  s = tostring(s):gsub("'", "''")
  -- PowerShell also treats these typographic quotes as single quotes
  for _, q in ipairs({ "\xE2\x80\x98", "\xE2\x80\x99", "\xE2\x80\x9A", "\xE2\x80\x9B" }) do
    s = s:gsub(q, q .. q)
  end
  return "'" .. s .. "'"
end

-- Wrap a PowerShell script as a cmd-safe command. The script must not contain
-- double quotes (Windows paths cannot, and we use single-quoted literals).
local function ps_cmd(script)
  return 'powershell -NoProfile -Command "' .. script .. '"'
end

local function bit_set(value, mask)
  return value & mask ~= 0
end

function M.new(os_name, run, start)
  local P = {}
  local win = os_name == "win"
  local sep = win and "\\" or "/"

  local function norm(path)
    if win then return (path:gsub("/", "\\")) end
    return path
  end

  function P.quote(path)
    if win then return '"' .. tostring(path):gsub('"', "") .. '"' end
    return posix_quote(path)
  end

  function P.join(dir, name)
    dir = norm(dir)
    name = norm(name)
    dir = dir:gsub("[/\\]+$", "")
    if dir == "" and not win then return "/" .. name end
    return dir .. sep .. name
  end

  local function last_component(path)
    local trimmed = path:gsub("[/\\]+$", "")
    return trimmed:match("([^/\\]*)$") or trimmed
  end

  local function parent(path)
    local p = path:gsub("[/\\]+$", ""):match("^(.*)[/\\][^/\\]*$")
    if p == nil then return "." end
    if p == "" then return sep end
    return p
  end

  -- Lines "kind|size|mtime|flags|path" (the commands below) as entries.
  -- Reads up to max lines "kind|size|mtime|flags|path" of out from pos into
  -- entries; returns where to go on, or nil at the end.
  local function parse_some(out, pos, entries, max)
    local n = #out
    while pos <= n and max > 0 do
      local stop = out:find("\n", pos, true) or (n + 1)
      local line = out:sub(pos, stop - 1):gsub("\r$", "")
      pos, max = stop + 1, max - 1
      local kind, size, mtime, flags, path = line:match("^([^|]*)|([^|]*)|([^|]*)|([^|]*)|(.+)$")
      if kind and path then
        local is_dir, cloud
        if win then
          is_dir = kind == "True"
          cloud = bit_set(tonumber(flags) or 0, WIN_OFFLINE) or bit_set(tonumber(flags) or 0, WIN_RECALL)
        else
          is_dir = kind:lower():find("^directory") ~= nil
          local f = tonumber((flags:gsub("^0[xX]", "")), 16) or 0
          cloud = os_name == "mac" and bit_set(f, SF_DATALESS)
        end
        path = norm(path)
        entries[#entries + 1] = {
          name = last_component(path),
          path = path,
          is_dir = is_dir,
          size = tonumber(size) or 0,
          mtime = tonumber(mtime) or 0,
          cloud_only = cloud and true or false,
        }
      end
    end
    if pos <= n then return pos end
    return nil
  end

  local function parse(out)
    local entries = {}
    parse_some(out, 1, entries, math.huge)
    return entries
  end

  local PS_LINE = "'{0}|{1}|{2}|{3}|{4}' -f $_.PSIsContainer,$_.Length,"
    .. "[DateTimeOffset]::new($_.LastWriteTimeUtc).ToUnixTimeSeconds(),[int]$_.Attributes,$_.FullName"

  -- A listing's command and, on Windows, its PowerShell script alone.
  local function list_cmd(dir)
    local cmd, ps
    if os_name == "mac" then
      cmd = "find -H " .. posix_quote(dir) .. " -mindepth 1 -maxdepth 1 -exec stat -f '%HT|%z|%m|%Xf|%N' {} + 2>/dev/null"
    elseif os_name == "linux" then
      cmd = "find -H " .. posix_quote(dir) .. " -mindepth 1 -maxdepth 1 -exec stat -c '%F|%s|%Y|0|%n' {} + 2>/dev/null"
    else
      ps = "Get-ChildItem -LiteralPath " .. ps_quote(dir) .. " -Force | ForEach-Object { " .. PS_LINE .. " }"
      cmd = ps_cmd(ps)
    end
    return cmd, ps
  end

  -- The entries of a finished command; failed when it did not finish.
  local function listed(out, ok)
    local entries = parse(ok ~= false and out or "")
    if ok == false then entries.failed = true end
    return entries
  end

  -- A job for cmd whose poll() gives nil, or the entries (passed through
  -- done). A long listing is read M.PARSE_LINES lines per poll, so taking in
  -- a folder of thousands of files does not hold up a frame either.
  local function list_job(cmd, ps, done)
    local job = start and start(cmd, ps)
    if not job then return nil end
    local out, pos, entries, result
    return { poll = function()
      if result then return result end
      if not out then
        out = job.poll()
        if out == nil then return nil end
        if out == false then
          result = done(listed("", false))
          return result
        end
        pos, entries = 1, {}
      end
      pos = parse_some(out, pos, entries, M.PARSE_LINES)
      if pos then return nil end
      result = done(entries)
      return result
    end }
  end

  -- (On Windows the script goes along, for a runner that is PowerShell already.)
  function P.list_dir(dir)
    return listed(run(list_cmd(dir)))
  end

  function P.list_dir_start(dir)
    local cmd, ps = list_cmd(dir)
    return list_job(cmd, ps, function(entries) return entries end)
  end

  -- Every REAPER project file under root, at most max_depth folders down,
  -- in ONE command (a folder-by-folder walk costs a command per folder).
  -- Folders named in skip (lower case) and hidden folders are not entered on
  -- macOS and Linux; on Windows they are filtered out afterwards. Entries as
  -- list_dir gives them.
  local function tree_cmd(root, max_depth, skip)
    local cmd, ps
    if os_name == "mac" or os_name == "linux" then
      local prune = { "-name '.*'" }
      for _, name in ipairs(skip or {}) do prune[#prune + 1] = "-iname " .. posix_quote(name) end
      local fmt = os_name == "mac" and "stat -f '%HT|%z|%m|%Xf|%N'" or "stat -c '%F|%s|%Y|0|%n'"
      cmd = "find -H " .. posix_quote(root) .. " -mindepth 1 -maxdepth " .. (max_depth + 1)
        .. " \\( -type d \\( " .. table.concat(prune, " -o ") .. " \\) -prune \\) -o"
        .. " \\( -type f -iname '*.rpp' -exec " .. fmt .. " {} + \\) 2>/dev/null"
    else
      ps = "Get-ChildItem -LiteralPath " .. ps_quote(root) .. " -Recurse -Depth " .. max_depth
        .. " -Filter *.rpp -File -Force -ErrorAction SilentlyContinue | ForEach-Object { " .. PS_LINE .. " }"
      cmd = ps_cmd(ps)
    end
    return cmd, ps
  end

  local function tree_entries(root, skip, entries)
    local out = {}
    out.failed = entries.failed
    local base = norm(root):gsub("[/\\]+$", "")
    local blocked = {}
    for _, name in ipairs(skip or {}) do blocked[name:lower()] = true end
    for _, e in ipairs(entries) do
      if not e.is_dir and e.name:lower():match("%.rpp$") then
        local rel = e.path:sub(#base + 2)
        local ok = true
        local parts = {}
        for part in rel:gmatch("[^/\\]+") do parts[#parts + 1] = part end
        for i = 1, #parts - 1 do
          if parts[i]:sub(1, 1) == "." or blocked[parts[i]:lower()] then ok = false end
        end
        if ok then out[#out + 1] = e end
      end
    end
    return out
  end

  function P.list_tree(root, max_depth, skip)
    return tree_entries(root, skip, listed(run(tree_cmd(root, max_depth, skip))))
  end

  function P.list_tree_start(root, max_depth, skip)
    local cmd, ps = tree_cmd(root, max_depth, skip)
    return list_job(cmd, ps, function(entries)
      return tree_entries(root, skip, entries)
    end)
  end

  local ps_checked
  -- Runs cmd, appends a success marker; returns true or false, output.
  -- ps (Windows): the PowerShell script inside cmd, with the marker as its
  -- last output, for a runner that is PowerShell already.
  local function checked(cmd, ps)
    if not win then cmd = "{ " .. cmd .. "; } 2>&1" end
    local out = run(cmd .. " && echo " .. OK, ps and (ps .. "; '" .. OK .. "'")) or ""
    if out:find(OK, 1, true) then return true end
    out = out:gsub("%s+$", "")
    if out == "" then out = "command failed" end
    return false, out
  end

  -- For commands whose result nobody reads: without waiting when possible.
  local function fire(cmd)
    if not (start and start(cmd)) then run(cmd) end
  end

  -- A checked PowerShell script (Windows).
  ps_checked = function(script)
    return checked(ps_cmd(script) .. " 2>&1", script)
  end

  function P.reveal(path)
    if os_name == "mac" then
      fire("open -R " .. posix_quote(path))
    elseif win then
      fire('explorer /select,"' .. norm(path) .. '"')
    else
      fire("xdg-open " .. posix_quote(parent(path)))
    end
    return true -- explorer/open report no useful status
  end

  -- Opens the folder that holds path (a project file) in the file manager.
  function P.open_folder(path)
    local dir = parent(path)
    if os_name == "mac" then
      fire("open " .. posix_quote(dir))
    elseif win then
      fire('explorer "' .. norm(dir) .. '"')
    else
      fire("xdg-open " .. posix_quote(dir))
    end
    return true -- explorer/open report no useful status
  end

  function P.trash(path)
    if os_name == "mac" then
      local as = path:gsub("\\", "\\\\"):gsub('"', '\\"')
      return checked("osascript -e " .. posix_quote('tell application "Finder" to delete POSIX file "' .. as .. '"') .. " 2>&1")
    elseif win then
      local q = ps_quote(path)
      return ps_checked(("$ErrorActionPreference='Stop'; Add-Type -AssemblyName Microsoft.VisualBasic; "
        .. "if (Test-Path -LiteralPath " .. q .. " -PathType Container) { "
        .. "[Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory(" .. q .. ",'AllDialogs','SendToRecycleBin') } else { "
        .. "[Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile(" .. q .. ",'AllDialogs','SendToRecycleBin') }"))
    else
      return checked("gio trash " .. posix_quote(path) .. " 2>&1")
    end
  end

  -- Moves many files to the Trash / Recycle Bin, a few commands in all (one
  -- Finder call per TRASH_BATCH files on macOS). True, or false and output.
  function P.trash_many(paths)
    for i = 1, #paths, M.TRASH_BATCH do
      local part = {}
      for j = i, math.min(#paths, i + M.TRASH_BATCH - 1) do part[#part + 1] = paths[j] end
      local ok, err
      if os_name == "mac" then
        local items = {}
        for k, path in ipairs(part) do
          items[k] = 'POSIX file "' .. path:gsub("\\", "\\\\"):gsub('"', '\\"') .. '"'
        end
        ok, err = checked("osascript -e " .. posix_quote('tell application "Finder" to delete {'
          .. table.concat(items, ", ") .. '}') .. " >/dev/null 2>&1")
      elseif win then
        local items = {}
        for k, path in ipairs(part) do items[k] = ps_quote(path) end
        ok, err = ps_checked(("$ErrorActionPreference='Stop'; Add-Type -AssemblyName Microsoft.VisualBasic; "
          .. "foreach ($f in @(" .. table.concat(items, ",") .. ")) { "
          .. "[Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($f,'OnlyErrorDialogs','SendToRecycleBin') }"))
      else
        local items = {}
        for k, path in ipairs(part) do items[k] = posix_quote(path) end
        ok, err = checked("gio trash " .. table.concat(items, " ") .. " 2>&1")
      end
      if not ok then return false, err end
    end
    return true
  end

  local function transfer(src, dst, posix_verb, ps_verb)
    if win then
      local ok, err = ps_checked(("$ErrorActionPreference='Stop'; if (Test-Path -LiteralPath " .. ps_quote(dst)
        .. ") { throw 'destination exists' }; " .. ps_verb .. " -LiteralPath " .. ps_quote(src)
        .. " -Destination " .. ps_quote(dst)))
      if not ok and err:find("destination exists", 1, true) then err = "destination exists" end
      return ok, err
    end
    -- never overwrite silently
    return checked("{ test ! -e " .. posix_quote(dst) .. " || { echo 'destination exists' >&2; false; }; } && "
      .. posix_verb .. " " .. posix_quote(src) .. " " .. posix_quote(dst) .. " 2>&1")
  end

  function P.copy(src, dst)
    if win then return transfer(src, dst, nil, "Copy-Item -Recurse") end
    return transfer(src, dst, "cp -Rp")
  end

  function P.move(src, dst)
    if win then return transfer(src, dst, nil, "Move-Item") end
    return transfer(src, dst, "mv")
  end

  -- Creates dir and any missing parents; an existing folder is fine.
  -- (BSD mkdir has no "--"; the quoted absolute path cannot start with "-".)
  function P.mkdir(dir)
    if win then
      -- CreateDirectory takes the path literally (no wildcards) and makes parents.
      return ps_checked(("$ErrorActionPreference='Stop'; [System.IO.Directory]::CreateDirectory("
        .. ps_quote(dir) .. ") | Out-Null"))
    end
    return checked("mkdir -p " .. posix_quote(dir) .. " 2>&1")
  end

  return P
end

return M
