-- Reads the facts ReaLobby shows from a REAPER project (.RPP) text.
-- Pure Lua: no REAPER or ReaImGui calls, runs under plain Lua 5.4.
local rpp = {}

-- Splits a line into tokens using REAPER's quoting: double quotes, single
-- quotes or backticks wrap a token; otherwise tokens end at whitespace.
local function tokenize(line)
  local tokens, i, n = {}, 1, #line
  while true do
    i = line:find("%S", i)
    if not i then break end
    local c = line:sub(i, i)
    if c == '"' or c == "'" or c == "`" then
      local j = line:find(c, i + 1, true)
      if j then
        tokens[#tokens + 1] = line:sub(i + 1, j - 1)
        i = j + 1
      else
        tokens[#tokens + 1] = line:sub(i + 1)
        break
      end
    else
      local j = line:find("%s", i) or (n + 1)
      tokens[#tokens + 1] = line:sub(i, j - 1)
      i = j
    end
  end
  return tokens
end

rpp.tokenize = tokenize

local FX_PARENTS = { FXCHAIN = true, FXCHAIN_REC = true, MASTERFXLIST = true,
  TAKEFX = true, CONTAINER = true }
local FX_BLOCKS = { VST = true, AU = true, CLAP = true, JS = true }

local function is_absolute(p)
  return p:match("^[/\\]") ~= nil or p:match("^%a:[/\\]") ~= nil
end

local function nonempty(s)
  if s == nil or s == "" then return nil end
  return s
end

-- Kind comes from the prefix before the colon ("VST3i" and "VSTi" are the
-- instrument forms of VST3 and VST).
local function fx_from(block, tokens)
  if block == "JS" then
    return { kind = "JS", name = tokens[2] or "", file = nil }
  end
  local label = tokens[2] or ""
  local prefix, name = label:match("^([^:]*):%s*(.*)$")
  local kind = block
  if prefix then
    kind = prefix:gsub("i$", "")
    if kind == "" then kind = block end
  else
    name = label
  end
  return { kind = kind, name = name, file = nonempty(tokens[3]) }
end

function rpp.parse(text, project_path)
  local dir = (project_path or ""):match("^(.*)[/\\][^/\\]*$") or ""
  local info = {
    length = 0, track_count = 0, fx = {}, media = {}, notes = "",
  }
  local stack = {}      -- block names, innermost last
  local item = nil      -- { pos, len } while inside an ITEM
  local notes = nil     -- collected lines while inside the project NOTES block
  local seen_media = {}

  for raw in (text .. "\n"):gmatch("(.-)\r?\n") do
    local line = raw:match("^%s*(.-)%s*$")
    local depth = #stack
    local top = stack[depth]

    if top == "NOTES" and notes and depth == 2 and line:sub(1, 1) == "|" then
      notes[#notes + 1] = line:sub(2)
    elseif line == ">" then
      if top == "ITEM" and item then
        local finish = item.pos + item.len
        if finish > info.length then info.length = finish end
        item = nil
      elseif top == "NOTES" and notes then
        info.notes = table.concat(notes, "\n")
        notes = nil
      end
      stack[depth] = nil
    elseif line:sub(1, 1) == "<" then
      local tokens = tokenize(line:sub(2))
      local name = tokens[1] or ""
      if depth == 1 and name == "TRACK" then
        info.track_count = info.track_count + 1
      elseif depth == 1 and name == "NOTES" then
        notes = {}
      elseif name == "ITEM" then
        item = { pos = 0, len = 0 }
      elseif FX_BLOCKS[name] and FX_PARENTS[top] then
        info.fx[#info.fx + 1] = fx_from(name, tokens)
      end
      stack[depth + 1] = name
    elseif line ~= "" then
      local tokens = tokenize(line)
      local key = tokens[1]
      if depth == 1 then
        if key == "TITLE" then info.title = nonempty(tokens[2])
        elseif key == "AUTHOR" then info.author = nonempty(tokens[2])
        elseif key == "TEMPO" then
          info.tempo = tonumber(tokens[2])
          if tokens[3] and tokens[4] then
            info.timesig = tokens[3] .. "/" .. tokens[4]
          end
        elseif key == "RENDER_FILE" then info.render_dir = nonempty(tokens[2])
        elseif key == "RENDER_PATTERN" then info.render_pattern = nonempty(tokens[2])
        end
      elseif top == "ITEM" and item then
        if key == "POSITION" then item.pos = tonumber(tokens[2]) or 0
        elseif key == "LENGTH" then item.len = tonumber(tokens[2]) or 0
        end
      elseif top == "SOURCE" and key == "FILE" and tokens[2] and tokens[2] ~= "" then
        local p = tokens[2]
        if not is_absolute(p) and dir ~= "" then p = dir .. "/" .. p end
        if not seen_media[p] then
          seen_media[p] = true
          info.media[#info.media + 1] = p
        end
      end
    end
  end
  return info
end

-- Which FX the file saved offline, for "Bring FX online after load"
-- (realobby/online.lua). One chain per FX list, in file order:
--   { kind = "master" | "track" | "rec" | "take", guid = track or take GUID,
--     fx = { { id = the FX's GUID (FXID), offline = leave it offline }, ... } }
-- Each FX in a list follows its own "BYPASS <bypassed> <offline> ..." line
-- and is followed by its "FXID {GUID}" line. A container counts as offline
-- when it or anything inside it was saved offline, so a container is never
-- brought online around a saved-offline plug-in. "rec" is the track's input
-- FX. A frozen track's saved chain (FREEZE) is not a live chain.
local CHAIN_KINDS = {
  MASTERFXLIST = { parent = "REAPER_PROJECT", kind = "master" },
  FXCHAIN = { parent = "TRACK", kind = "track" },
  FXCHAIN_REC = { parent = "TRACK", kind = "rec" },
  TAKEFX = { parent = "ITEM", kind = "take" },
}

function rpp.fx_chains(text)
  local chains, stack = {}, {}
  local track_guid, take_guid, chain
  for raw in (text .. "\n"):gmatch("(.-)\r?\n") do
    local line = raw:match("^%s*(.-)%s*$")
    local depth = #stack
    local top = stack[depth]
    if line == ">" then
      if chain and chain.depth == depth then
        if #chain.fx > 0 then chains[#chains + 1] = { kind = chain.kind, guid = chain.guid, fx = chain.fx } end
        chain = nil
      end
      stack[depth] = nil
    elseif line:sub(1, 1) == "<" then
      local tokens = tokenize(line:sub(2))
      local name = tokens[1] or ""
      if name == "TRACK" and depth == 1 then track_guid = tokens[2] end
      if name == "ITEM" then take_guid = nil end
      local ck = CHAIN_KINDS[name]
      if ck and top == ck.parent and not chain then
        local guid = (ck.kind == "track" or ck.kind == "rec") and track_guid
          or ck.kind == "take" and take_guid or nil
        chain = { kind = ck.kind, guid = guid, fx = {}, depth = depth + 1 }
      end
      stack[depth + 1] = name
    elseif chain and depth >= chain.depth then
      local key, a, b = line:match("^(%S+)%s*(%S*)%s*(%S*)")
      local fx = chain.fx[#chain.fx]
      if depth == chain.depth then
        if key == "BYPASS" then
          chain.fx[#chain.fx + 1] = { offline = b == "1" }
        elseif key == "FXID" and fx and fx.id == nil then
          fx.id = a ~= "" and a or nil
        end
      elseif key == "BYPASS" and b == "1" and fx then
        fx.offline = true   -- inside a container
      end
    elseif top == "ITEM" then
      local key, value = line:match("^(%S+)%s*(.*)$")
      if key == "GUID" then take_guid = value
      elseif key == "TAKE" then take_guid = nil
      end
    end
  end
  return chains
end

-- rpp.fx_chains of a file; nil when it cannot be read.
function rpp.read_fx_chains(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local text = f:read("a")
  f:close()
  if not text then return nil end
  return rpp.fx_chains(text)
end

function rpp.read(path)
  local f, err = io.open(path, "rb")
  if not f then return nil, err end
  local text = f:read("a")
  f:close()
  if not text then return nil, "could not read " .. path end
  return rpp.parse(text, path)
end

return rpp
