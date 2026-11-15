-- @description BLV Extend items to fill gaps
-- @author BLV
-- @version 1.0.0
-- @about
--   Extends each selected item's end to the start of the next item across the selected tracks (no time-stretching).
--   Copyright (c) 2026 BLV. All rights reserved. Free to use. You may not copy, modify, repackage or redistribute this software.

-- Stretch Items To Fill Gaps (Cross-Track Aware)
-- Extends the end of each selected item to meet the start of the NEAREST next item
-- across ALL selected tracks. No time-stretching — just moves the item edge.

function main()
  local item_count = reaper.CountSelectedMediaItems(0)
  if item_count < 2 then
    reaper.ShowMessageBox("Select at least 2 items.", "Stretch Items To Fill Gaps", 0)
    return
  end

  -- Collect all selected items with position info
  local all_items = {}
  for i = 0, item_count - 1 do
    local item = reaper.GetSelectedMediaItem(0, i)
    local pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    local len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
    table.insert(all_items, {
      item = item,
      pos = pos,
      len = len
    })
  end

  -- Sort all items globally by position
  table.sort(all_items, function(a, b) return a.pos < b.pos end)

  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  -- For each item (except the last), extend its end to the start of the next item
  for i = 1, #all_items - 1 do
    local current = all_items[i]
    local next_start = all_items[i + 1].pos
    local new_length = next_start - current.pos

    -- Only extend if the gap is real (next item starts after this one starts)
    if new_length > 0 then
      reaper.SetMediaItemInfo_Value(current.item, "D_LENGTH", new_length)
    end
  end

  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock("Stretch items to fill gaps (cross-track)", -1)
end

main()
