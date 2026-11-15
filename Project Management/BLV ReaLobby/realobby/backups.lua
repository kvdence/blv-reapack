-- Lists a project's REAPER backups from directory listings only.
local M = {}

local function split_path(p)
  local dir, file = p:match("^(.*)[/\\]([^/\\]*)$")
  if not dir then return ".", p end
  if dir == "" then dir = "/" end
  return dir, file
end

local function is_absolute(p)
  return p:match("^[/\\]") ~= nil or p:match("^%a:[/\\]") ~= nil
end

local function plain_find(s, sub) return s:sub(1, #sub) == sub end

local STAMP = "%d%d%d%d%-%d%d%-%d%d_%d%d%d%d%d%d"

-- backups.list(project_path, P, backup_dir) -> { {path, mtime, kind="bak"|"timestamped", realobby} } newest first
-- ReaLobby's own backups before an edit (<name>-<stamp>-realobby[-N].rpp-bak)
-- are timestamped ones with realobby = true.
function M.list(project_path, P, backup_dir)
  local folder, file = split_path(project_path)
  local name = file:gsub("%.[Rr][Pp][Pp]$", "")
  local dirs = { { folder, true }, { P.join(folder, "Backups"), false } }
  if backup_dir and backup_dir ~= "" then
    dirs[#dirs + 1] = { is_absolute(backup_dir) and backup_dir or P.join(folder, backup_dir), false }
  end

  local out, seen = {}, {}
  for _, d in ipairs(dirs) do
    local dir, beside = d[1], d[2]
    for _, e in ipairs(P.list_dir(dir)) do
      if not e.is_dir and not seen[e.path] then
        local base = e.name:match("^(.*)%.[Rr][Pp][Pp]%-[Bb][Aa][Kk]$")
        if base then
          local kind, ours
          if base == name then
            if beside then kind = "bak" end
          elseif plain_find(base, name .. "-") then
            local rest = base:sub(#name + 2)
            if rest:match("^" .. STAMP .. "$") then
              kind = "timestamped"
            elseif rest:match("^" .. STAMP .. "%-realobby$") or rest:match("^" .. STAMP .. "%-realobby%-%d+$") then
              kind, ours = "timestamped", true
            end
          end
          if kind then
            seen[e.path] = true
            out[#out + 1] = { path = e.path, mtime = e.mtime, kind = kind, realobby = ours }
          end
        end
      end
    end
  end
  table.sort(out, function(a, b)
    if a.mtime ~= b.mtime then return a.mtime > b.mtime end
    return a.path < b.path
  end)
  return out
end

return M
