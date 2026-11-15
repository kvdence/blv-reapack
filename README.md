# BLV scripts for REAPER

BLV's REAPER scripts, installed with [ReaPack](https://reapack.com).

## Install

1. In REAPER, install ReaPack if you don't have it, and ReaImGui (Extensions → ReaPack → Browse packages → ReaImGui).
2. Extensions → ReaPack → Import repositories…, paste this link and press OK:

   ```
   https://github.com/kvdence/blv-reapack/raw/main/index.xml
   ```

3. Extensions → ReaPack → Browse packages, search "BLV", install, then restart REAPER if asked.

## Scripts

| Script | What it does | Platforms |
|---|---|---|
| BLV ReaLobby | A project launcher: find, inspect, organise and open your projects, and start new ones from templates. Run "BLV_ReaLobby" from the action list. | macOS and Windows (REAPER 7.74+, ReaImGui) |
| Alphabetize selected tracks (Tracks) | Sorts the selected tracks A to Z by name. Selected folders move as whole blocks and the folder structure is kept. | macOS and Windows |
| Prefix selected tracks with parent name (skip BUS) (Tracks) | Puts each selected track's parent folder name in front of its name; "BUS" is left out of the parent name and BUS tracks are skipped. | macOS and Windows |
| Prefix tracks with parent name (Tracks) | Puts each track's parent folder name in front of its name, with exceptions for pass-through folders. | macOS and Windows |
| Standardize track names and sort (Tracks) | Tidies track names to one standard and sorts them. | macOS and Windows |
| Rename and sort tracks by folder (Tracks) | Renames tracks after their folder and sorts them by the folder hierarchy. | macOS and Windows |
| Rename and sort drum tracks (Tracks) | Renames drum tracks to standard names (kick, snare, hats, and so on) and sorts them. | macOS and Windows |
| Collapse folders by depth (Folders and Selection) | A small window to expand, collapse or limit folder tracks by how deep they are nested; remembers the last choice per project. Needs ReaImGui. | macOS and Windows |
| Select children of selected folders (Folders and Selection) | Selects every track inside the selected folder tracks. | macOS and Windows |
| Copy selected track numbers (Folders and Selection) | Copies the numbers of the selected tracks to the clipboard, separated by commas. Needs SWS. | macOS and Windows |
| Exclusive solo click mode (Mixing) | A toggle: while it is on, clicking a track's solo button solos only that track. Needs js_ReaScriptAPI. | macOS and Windows |
| Reset all track volumes to 0 dB (Mixing) | Sets every track's volume fader to 0 dB. | macOS and Windows |
| Pan selected tracks 50 left (Mixing) | Pans the selected tracks 50% left. | macOS and Windows |
| Pan selected tracks 50 right (Mixing) | Pans the selected tracks 50% right. | macOS and Windows |
| Pan selected tracks 70 left (Mixing) | Pans the selected tracks 70% left. | macOS and Windows |
| Pan selected tracks 70 right (Mixing) | Pans the selected tracks 70% right. | macOS and Windows |
| Pan selected tracks 100 left (Mixing) | Pans the selected tracks hard left. | macOS and Windows |
| Pan selected tracks 100 right (Mixing) | Pans the selected tracks hard right. | macOS and Windows |
| Create doubles from takes (Editing) | Makes a staggered left and right pair from a lead track's takes, named "1 L" and "2 R" and panned hard left and right. | macOS and Windows |
| Extend items to fill gaps (Editing) | Extends each selected item's end to the start of the next item across the selected tracks (no time-stretching). | macOS and Windows |
| Smart zoom (Editing) | Cycles the arrange view through set bar lengths, then fits the loop, the selected items, the region or the whole project. | macOS and Windows |
| Set project end and render range to cursor (Editing) | After asking, ends the project at the edit cursor and sets the render range from the start to the cursor. Needs SWS. | macOS and Windows |
| Rename plug-in everywhere (Editing) | Renames every instance of the selected plug-in across the project in one go. | macOS and Windows |

## Licence

Copyright (c) 2026 BLV. All rights reserved. Free to use. You may not copy, modify, repackage or redistribute this software. See `LICENSE.txt`.
