-- The debug timer: off unless the entry script starts it (a file named
-- "debug-timer.txt" in ReaLobby's data folder switches it on). It writes one
-- line for every frame that took M.threshold seconds or longer, with what ran
-- in it. Pure Lua 5.4.
--
-- perf.start({ clock, write, threshold })  clock() -> seconds; write(line)
-- perf.span(label, fn, ...)   runs fn and records how long it took; label is
--                             text, or a function of fn's results -> text
-- perf.wrap(tbl, name, label) replaces tbl[name] with a timed version; label
--                             is text or function(args, results) -> text
-- perf.note(label, seconds)   records a time measured elsewhere
-- perf.frame_begin() / perf.frame_end(tag)
local M = { enabled = false, threshold = 0.05, MAX_SPANS = 60, MIN_SPAN = 0.001 }

local clock, write
local spans, frame_started, last_end, depth, frame_no = {}, nil, nil, 0, 0

function M.start(o)
  clock, write = o.clock, o.write
  M.threshold = o.threshold or M.threshold
  M.enabled = true
  spans, frame_started, last_end, depth, frame_no = {}, nil, nil, 0, 0
end

function M.stop() M.enabled = false end

local function ms(s) return ("%.1f"):format(s * 1000) end

function M.note(label, seconds)
  if not M.enabled then return end
  spans[#spans + 1] = { label = label, t = seconds, depth = depth }
end

local function finish(label, started, frame, d, ...)
  depth = d
  local t = clock() - started
  if type(label) == "function" then
    local ok, s = pcall(label, ...)
    label = ok and tostring(s) or "?"
  end
  -- A span that began in an earlier frame (work spread over frames by a
  -- coroutine) is not this frame's time.
  if frame ~= frame_no then label = label .. " (over " .. (frame_no - frame + 1) .. " frames)" end
  spans[#spans + 1] = { label = label, t = t, depth = d, spread = frame ~= frame_no }
  return ...
end

function M.span(label, fn, ...)
  if not M.enabled then return fn(...) end
  local d = depth
  depth = d + 1
  return finish(label, clock(), frame_no, d, fn(...))
end

function M.wrap(tbl, name, label)
  local fn = tbl[name]
  if type(fn) ~= "function" then return end
  tbl[name] = function(...)
    if not M.enabled then return fn(...) end
    local args = { ... }
    local lab = label
    if type(label) == "function" then
      lab = function(...) return label(args, { ... }) end
    end
    return M.span(lab or name, fn, ...)
  end
end

function M.frame_begin()
  if not M.enabled then return end
  frame_no = frame_no + 1
  frame_started = clock()
  spans, depth = {}, 0
  -- Time since the last frame ended: REAPER (or ImGui's drawing) was busy.
  if last_end and frame_started - last_end >= M.threshold then
    write(("gap %s ms before frame %d"):format(ms(frame_started - last_end), frame_no))
  end
end

function M.frame_end(tag)
  if not M.enabled or not frame_started then return end
  local now = clock()
  local total = now - frame_started
  last_end = now
  if total < M.threshold then return end
  local parts, shown = {}, 0
  for _, s in ipairs(spans) do
    if s.t >= M.MIN_SPAN and shown < M.MAX_SPANS then
      shown = shown + 1
      parts[#parts + 1] = ("%s%s %s"):format(("  "):rep(s.depth), s.label, ms(s.t))
    end
  end
  write(("frame %d %s ms%s\n    %s"):format(frame_no, ms(total), tag and (" [" .. tag .. "]") or "",
    table.concat(parts, "\n    ")))
end

return M
