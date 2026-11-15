-- Lists a project's bounces from directory listings only (never opens a file).
local M = {}

local AUDIO = { wav = true, aif = true, aiff = true, flac = true, mp3 = true, m4a = true, ogg = true, opus = true }

local function split_path(p)
  local dir, file = p:match("^(.*)[/\\]([^/\\]*)$")
  if not dir then return ".", p end
  if dir == "" then dir = "/" end
  return dir, file
end

local function is_absolute(p)
  return p:match("^[/\\]") ~= nil or p:match("^%a:[/\\]") ~= nil
end

local function strip_ext(name)
  return (name:gsub("%.[^%.]*$", ""))
end

local function trim_purpose(s)
  return (s:gsub("^[_%- %[%]]+", ""):gsub("[_%- %[%]]+$", ""))
end

-- Tokenise a render pattern into segments:
--   {kind="lit", text=, fixed=bool} | {kind="wild"}
local function tokenise(pattern, values)
  local segs, buf = {}, {}
  local function flush()
    if #buf > 0 then segs[#segs + 1] = { kind = "lit", text = table.concat(buf), fixed = false }; buf = {} end
  end
  local i, n = 1, #pattern
  while i <= n do
    local c = pattern:sub(i, i)
    if c == "$" then
      local name
      for _, known in ipairs({ "author", "title", "project" }) do
        if pattern:sub(i + 1, i + #known) == known then name = known; break end
      end
      name = name or pattern:match("^%$(%w+)", i)
      if name then
        i = i + 1 + #name
        if values[name] ~= nil then
          flush()
          segs[#segs + 1] = { kind = "lit", text = values[name], fixed = true }
        else
          flush()
          segs[#segs + 1] = { kind = "wild" }
          local arg = pattern:match("^(%b[])", i)
          if arg and not arg:find("%$") then i = i + #arg end
        end
      else
        buf[#buf + 1] = c; i = i + 1
      end
    else
      buf[#buf + 1] = c; i = i + 1
    end
  end
  flush()
  return segs
end

local function match_segs(segs, idx, s, pos, parts)
  local seg = segs[idx]
  if not seg then
    if pos == #s + 1 then return parts end
    return nil
  end
  if seg.kind == "lit" then
    if s:sub(pos, pos + #seg.text - 1) ~= seg.text then return nil end
    local np = parts
    if not seg.fixed then
      np = { table.unpack(parts) }
      local p = trim_purpose(seg.text)
      if p:find("%w") then np[#np + 1] = p end
    end
    return match_segs(segs, idx + 1, s, pos + #seg.text, np)
  end
  -- wildcard: shortest first
  for e = pos, #s + 1 do
    local r = match_segs(segs, idx + 1, s, e, parts)
    if r then return r end
  end
  return nil
end

-- bounces.matcher(pattern, info, project_name) -> function(filename) -> purpose|nil
function M.matcher(pattern, info, project_name)
  local _, pat = split_path(pattern or "$project")
  local segs = tokenise(pat, { author = info.author or "", title = info.title or "", project = project_name })
  return function(filename)
    local parts = match_segs(segs, 1, strip_ext(filename), 1, {})
    if not parts then return nil end
    return table.concat(parts, "_")
  end
end

local function project_name_of(file)
  local name = file:gsub("%.[Rr][Pp][Pp]$", "")
  return (name:gsub("_%d+$", ""))
end

-- bounces.list(info, project_path, P, extra_dirs) -> { {name, path, purpose, mtime, size, cloud_only} } newest first
function M.list(info, project_path, P, extra_dirs)
  local folder, file = split_path(project_path)
  local pname = project_name_of(file)
  local match = M.matcher(info.render_pattern or "$project", info, pname)

  local dirs = {}
  if info.render_dir and info.render_dir ~= "" then
    dirs[1] = is_absolute(info.render_dir) and info.render_dir or P.join(folder, info.render_dir)
  else
    dirs[1] = folder
  end
  for _, d in ipairs(extra_dirs or {}) do dirs[#dirs + 1] = d end

  local prefix = (info.author and info.title) and (info.author .. "_" .. info.title .. "_") or nil
  local out, seen_dir, seen = {}, {}, {}
  for _, dir in ipairs(dirs) do
    if not seen_dir[dir] then
      seen_dir[dir] = true
      for _, e in ipairs(P.list_dir(dir)) do
        local ext = e.name:match("%.([^%.]+)$")
        if not e.is_dir and ext and AUDIO[ext:lower()] and not seen[e.path] then
          local purpose = match(e.name)
          if purpose == nil and prefix then
            local base = strip_ext(e.name)
            if base:sub(1, #prefix) == prefix then
              local rest = base:sub(#prefix + 1)
              local cut = rest:find("_%d")
              if cut then rest = rest:sub(1, cut - 1) end
              purpose = trim_purpose(rest)
            end
          end
          if purpose ~= nil then
            seen[e.path] = true
            out[#out + 1] = { name = e.name, path = e.path, purpose = purpose, mtime = e.mtime,
              size = e.size, cloud_only = e.cloud_only }
          end
        end
      end
    end
  end
  table.sort(out, function(a, b)
    if a.mtime ~= b.mtime then return a.mtime > b.mtime end
    return a.name < b.name
  end)
  return out
end

return M
