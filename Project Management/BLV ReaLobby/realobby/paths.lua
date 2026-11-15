-- Path helpers shared by the library and the clean-up. Pure Lua.
local M = {}

-- clean(path): forward slashes, no trailing slash, "." and ".." segments
-- collapsed ("/a/b/../c/./d" -> "/a/c/d"), case kept. A ".." above the root
-- is dropped. Drive letters ("C:") stay as the first segment.
function M.clean(path)
  local p = tostring(path or ""):gsub("\\", "/")
  local absolute = p:sub(1, 1) == "/"
  local parts = {}
  for seg in p:gmatch("[^/]+") do
    if seg == ".." then
      if #parts > 0 and not (#parts == 1 and parts[1]:match("^%a:$")) then parts[#parts] = nil end
    elseif seg ~= "." then
      parts[#parts + 1] = seg
    end
  end
  local out = table.concat(parts, "/")
  if absolute then out = "/" .. out end
  if out == "" then out = absolute and "/" or "." end
  return out
end

-- key(path): clean(path) in lower case, for comparing paths.
function M.key(path)
  return M.clean(path):lower()
end

return M
