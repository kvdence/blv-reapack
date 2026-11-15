-- ReaLobby's own data: pins, statuses, tags, hidden flags, scan folders,
-- excludes, bounce folders, known files (songs renamed, moved or archived outside every scan
-- folder), settings and last-opened times. Pure Lua (no reaper.*); the caller
-- passes the full path and creates the folder before the first save.
local M = {}

local INSTRUCTION_LIMIT = 1000000

local function defaults()
  return {
    version = 1,
    songs = {},
    statuses = { "Writing", "Mixing", "Done" },
    scan_folders = {},
    excludes = {},
    known_files = {},
    bounce_folders = {},
    opacity = 0.94,
    first_run_done = false,
    sort = { column = "opened", descending = true },
  }
end

-- Serializer -----------------------------------------------------------------

local function key_less(a, b)
  local ta, tb = type(a), type(b)
  if ta ~= tb then return ta == "number" end
  return a < b
end

local function ser_number(n)
  if math.type(n) == "integer" then return string.format("%d", n) end
  if n ~= n or n == math.huge or n == -math.huge then error("cannot serialize non-finite number", 0) end
  local s = string.format("%.17g", n)
  if not s:find("[%.eE]") then s = s .. ".0" end
  return s
end

local function ser(v, out, seen)
  local tv = type(v)
  if tv == "string" then
    out[#out + 1] = (string.format("%q", v):gsub("\\\n", "\\n"))
  elseif tv == "number" then
    out[#out + 1] = ser_number(v)
  elseif tv == "boolean" then
    out[#out + 1] = tostring(v)
  elseif tv == "table" then
    if seen[v] then error("cannot serialize a cyclic table", 0) end
    seen[v] = true
    out[#out + 1] = "{"
    local n = #v
    for i = 1, n do
      ser(v[i], out, seen)
      out[#out + 1] = ","
    end
    local keys = {}
    for k in pairs(v) do
      if not (math.type(k) == "integer" and k >= 1 and k <= n) then keys[#keys + 1] = k end
    end
    table.sort(keys, function(a, b)
      local ta, tb = type(a), type(b)
      if ta ~= "string" and ta ~= "number" then error("cannot serialize a " .. ta .. " key", 0) end
      if tb ~= "string" and tb ~= "number" then error("cannot serialize a " .. tb .. " key", 0) end
      return key_less(a, b)
    end)
    for _, k in ipairs(keys) do
      out[#out + 1] = "["
      ser(k, out, seen)
      out[#out + 1] = "]="
      ser(v[k], out, seen)
      out[#out + 1] = ","
    end
    out[#out + 1] = "}"
    seen[v] = nil
  else
    error("cannot serialize a " .. tv, 0)
  end
end

local function serialize(data)
  local out = { "return " }
  ser(data, out, {})
  out[#out + 1] = "\n"
  return table.concat(out)
end

-- Load -----------------------------------------------------------------------

local function read_all(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local s = f:read("a")
  f:close()
  return s
end

local function write_all(path, text)
  local f, err = io.open(path, "wb")
  if not f then return false, err end
  local ok, werr = f:write(text)
  if ok then ok, werr = f:flush() end
  local cok, cerr = f:close()
  if not ok then return false, werr end
  if not cok then return false, cerr or "close failed" end
  return true
end

-- Evaluate the text as a sandboxed chunk with an instruction budget.
local function evaluate(text)
  local fn = load(text, "realobby.dat", "t", {})
  if not fn then return nil end
  local old_hook, old_mask, old_count = debug.gethook()
  debug.sethook(function() error("realobby.dat: instruction limit", 0) end, "", INSTRUCTION_LIMIT)
  local ok, result = pcall(fn)
  debug.sethook(old_hook, old_mask or "", old_count or 0)
  if not ok or type(result) ~= "table" then return nil end
  return result
end

local function merge(defs, loaded)
  local out = {}
  for k, v in pairs(loaded) do out[k] = v end
  for k, dv in pairs(defs) do
    local lv = loaded[k]
    if lv == nil or type(lv) ~= type(dv) then
      out[k] = dv
    elseif type(dv) == "table" and k == "sort" then
      local s = {}
      for sk, sv in pairs(lv) do s[sk] = sv end
      for sk, sv in pairs(dv) do if s[sk] == nil then s[sk] = sv end end
      out[k] = s
    end
  end
  return out
end

function M.load(path)
  local text = read_all(path)
  if text == nil then
    -- A save interrupted mid-replace can leave the data in .bak or .tmp.
    for _, alt in ipairs({ path .. ".bak", path .. ".tmp" }) do
      local atext = read_all(alt)
      local result = atext and evaluate(atext)
      if result then return merge(defaults(), result) end
    end
    return defaults()
  end
  local result = evaluate(text)
  if result == nil then
    write_all(path .. ".bad", text)
    return defaults()
  end
  return merge(defaults(), result)
end

-- read(path) -> the saved table as written, or nil (missing or unreadable);
-- for ReaLobby's other data files (realobby/timelog.lua). Falls back to the
-- .bak and .tmp copies a save interrupted mid-replace can leave.
function M.read(path)
  for _, p in ipairs({ path, path .. ".bak", path .. ".tmp" }) do
    local text = read_all(p)
    local result = text and evaluate(text)
    if result then return result end
  end
  return nil
end

function M.save(path, data)
  local ok, text = pcall(serialize, data)
  if not ok then return false, text end
  local tmp, bak = path .. ".tmp", path .. ".bak"
  local wok, werr = write_all(tmp, text)
  if not wok then
    os.remove(tmp)
    return false, werr
  end
  local rok, rerr = os.rename(tmp, path)
  if rok then return true end
  -- Windows refuses to rename over an existing file: move the old one aside
  -- so it can be put back if the final rename fails.
  os.remove(bak)
  local mok = os.rename(path, bak)
  rok, rerr = os.rename(tmp, path)
  if not rok then
    if mok then os.rename(bak, path) end
    return false, rerr
  end
  os.remove(bak)
  return true
end

return M
