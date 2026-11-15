-- Platform helpers: the ONLY place shell commands are built.
-- platform.new(os_name, run) where run(cmd) -> output text (REAPER: reaper.ExecProcess).
local M = {}

M.TRASH_BATCH = 50

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

function M.new(os_name, run)
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
  local function parse(out)
    local entries = {}
    for line in (out .. "\n"):gmatch("(.-)\r?\n") do
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
    return entries
  end

  local PS_LINE = "'{0}|{1}|{2}|{3}|{4}' -f $_.PSIsContainer,$_.Length,"
    .. "[DateTimeOffset]::new($_.LastWriteTimeUtc).ToUnixTimeSeconds(),[int]$_.Attributes,$_.FullName"

  function P.list_dir(dir)
    local cmd
    if os_name == "mac" then
      cmd = "find -H " .. posix_quote(dir) .. " -mindepth 1 -maxdepth 1 -exec stat -f '%HT|%z|%m|%Xf|%N' {} + 2>/dev/null"
    elseif os_name == "linux" then
      cmd = "find -H " .. posix_quote(dir) .. " -mindepth 1 -maxdepth 1 -exec stat -c '%F|%s|%Y|0|%n' {} + 2>/dev/null"
    else
      cmd = ps_cmd("Get-ChildItem -LiteralPath " .. ps_quote(dir) .. " -Force | ForEach-Object { " .. PS_LINE .. " }")
    end
    return parse(run(cmd) or "")
  end

  -- Every REAPER project file under root, at most max_depth folders down,
  -- in ONE command (a folder-by-folder walk costs a command per folder).
  -- Folders named in skip (lower case) and hidden folders are not entered on
  -- macOS and Linux; on Windows they are filtered out afterwards. Entries as
  -- list_dir gives them.
  function P.list_tree(root, max_depth, skip)
    local cmd
    if os_name == "mac" or os_name == "linux" then
      local prune = { "-name '.*'" }
      for _, name in ipairs(skip or {}) do prune[#prune + 1] = "-iname " .. posix_quote(name) end
      local fmt = os_name == "mac" and "stat -f '%HT|%z|%m|%Xf|%N'" or "stat -c '%F|%s|%Y|0|%n'"
      cmd = "find -H " .. posix_quote(root) .. " -mindepth 1 -maxdepth " .. (max_depth + 1)
        .. " \\( -type d \\( " .. table.concat(prune, " -o ") .. " \\) -prune \\) -o"
        .. " \\( -type f -iname '*.rpp' -exec " .. fmt .. " {} + \\) 2>/dev/null"
    else
      cmd = ps_cmd("Get-ChildItem -LiteralPath " .. ps_quote(root) .. " -Recurse -Depth " .. max_depth
        .. " -Filter *.rpp -File -Force -ErrorAction SilentlyContinue | ForEach-Object { " .. PS_LINE .. " }")
    end
    local entries = parse(run(cmd) or "")
    local out = {}
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

  -- Runs cmd, appends a success marker; returns true or false, output.
  local function checked(cmd)
    if not win then cmd = "{ " .. cmd .. "; } 2>&1" end
    local out = run(cmd .. " && echo " .. OK) or ""
    if out:find(OK, 1, true) then return true end
    out = out:gsub("%s+$", "")
    if out == "" then out = "command failed" end
    return false, out
  end

  function P.reveal(path)
    if os_name == "mac" then
      run("open -R " .. posix_quote(path))
    elseif win then
      run('explorer /select,"' .. norm(path) .. '"')
    else
      run("xdg-open " .. posix_quote(parent(path)))
    end
    return true -- explorer/open report no useful status
  end

  -- Opens the folder that holds path (a project file) in the file manager.
  function P.open_folder(path)
    local dir = parent(path)
    if os_name == "mac" then
      run("open " .. posix_quote(dir))
    elseif win then
      run('explorer "' .. norm(dir) .. '"')
    else
      run("xdg-open " .. posix_quote(dir))
    end
    return true -- explorer/open report no useful status
  end

  function P.trash(path)
    if os_name == "mac" then
      local as = path:gsub("\\", "\\\\"):gsub('"', '\\"')
      return checked("osascript -e " .. posix_quote('tell application "Finder" to delete POSIX file "' .. as .. '"') .. " 2>&1")
    elseif win then
      local q = ps_quote(path)
      return checked(ps_cmd("$ErrorActionPreference='Stop'; Add-Type -AssemblyName Microsoft.VisualBasic; "
        .. "if (Test-Path -LiteralPath " .. q .. " -PathType Container) { "
        .. "[Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory(" .. q .. ",'AllDialogs','SendToRecycleBin') } else { "
        .. "[Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile(" .. q .. ",'AllDialogs','SendToRecycleBin') }") .. " 2>&1")
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
        ok, err = checked(ps_cmd("$ErrorActionPreference='Stop'; Add-Type -AssemblyName Microsoft.VisualBasic; "
          .. "foreach ($f in @(" .. table.concat(items, ",") .. ")) { "
          .. "[Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($f,'OnlyErrorDialogs','SendToRecycleBin') }") .. " 2>&1")
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
      local ok, err = checked(ps_cmd("$ErrorActionPreference='Stop'; if (Test-Path -LiteralPath " .. ps_quote(dst)
        .. ") { throw 'destination exists' }; " .. ps_verb .. " -LiteralPath " .. ps_quote(src)
        .. " -Destination " .. ps_quote(dst)) .. " 2>&1")
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
      return checked(ps_cmd("$ErrorActionPreference='Stop'; [System.IO.Directory]::CreateDirectory("
        .. ps_quote(dir) .. ") | Out-Null") .. " 2>&1")
    end
    return checked("mkdir -p " .. posix_quote(dir) .. " 2>&1")
  end

  return P
end

return M
