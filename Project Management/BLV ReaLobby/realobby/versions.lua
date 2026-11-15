-- Folds REAPER's saved versions (Name_005.RPP) into one song per original.
local M = {}

-- key(path) -> base_key, number|nil. The key is the path minus a "_NNN.RPP"
-- suffix (or minus ".RPP" when unnumbered); folders keep songs apart.
function M.key(path)
  local base, num = path:match("^(.*)_(%d%d%d+)%.[Rr][Pp][Pp]$")
  if base then return base, tonumber(num) end
  return (path:gsub("%.[Rr][Pp][Pp]$", "")), nil
end

local function newer(a, b)
  local an, bn = a.number or -1, b.number or -1
  if an ~= bn then return an > bn end
  return (a.mtime or 0) > (b.mtime or 0)
end

-- group({ {path, mtime} }) -> { {key, newest, versions={ {path, number, mtime} }} }
function M.group(files)
  local by_key, order = {}, {}
  for _, f in ipairs(files) do
    local key, number = M.key(f.path)
    local song = by_key[key]
    if not song then
      song = { key = key, versions = {} }
      by_key[key] = song
      order[#order + 1] = song
    end
    song.versions[#song.versions + 1] = { path = f.path, number = number, mtime = f.mtime }
  end
  for _, song in ipairs(order) do
    table.sort(song.versions, newer)
    song.newest = song.versions[1].path
  end
  return order
end

return M
