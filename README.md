# BLV scripts for REAPER

BLV's REAPER scripts, installed with [ReaPack](https://reapack.com). Free to use.

## Install

1. In REAPER, install ReaPack if you don't have it. Some scripts also need ReaImGui, SWS or js_ReaScriptAPI (each says so below); get them from ReaPack (Extensions → ReaPack → Browse packages).
2. Extensions → ReaPack → Import repositories…, paste this link and press OK:

   ```
   https://github.com/kvdence/blv-reapack/raw/main/index.xml
   ```

3. Extensions → ReaPack → Browse packages, search "BLV", install what you want. Each script then appears in the Actions list.

## Tools

Complete apps with their own window.

| Tool | What it does | Needs |
|---|---|---|
| **BLV ReaLobby** | A project launcher that replaces REAPER's "Choose project" window: search and filter all your projects, see each song's details, bounces, backups, time worked and unused audio, and open, rename, move or archive songs. Opens when REAPER starts. | REAPER 7.74+, ReaImGui |

## Quick scripts

One action each: run from the Actions list, a toolbar button or a shortcut. All run on macOS and Windows.

### Tracks

| Script | What it does | Needs |
|---|---|---|
| Alphabetize selected tracks | Sorts the selected tracks A to Z by name. Selected folders move as whole blocks and the folder structure is kept. | — |
| Prefix selected tracks with parent name (skip BUS) | Puts each selected track's parent folder name in front of its name; "BUS" is left out of the parent name and BUS tracks are skipped. | — |
| Prefix tracks with parent name | Puts each track's parent folder name in front of its name, with exceptions for pass-through folders. | — |
| Standardize track names and sort | Tidies track names to one standard and sorts them. | — |
| Rename and sort tracks by folder | Renames tracks after their folder and sorts them by the folder hierarchy. | — |
| Rename and sort drum tracks | Renames drum tracks to standard names (kick, snare, hats, and so on) and sorts them. | — |

### Folders and Selection

| Script | What it does | Needs |
|---|---|---|
| Collapse folders by depth | A small window to expand, collapse or limit folder tracks by how deep they are nested; remembers the last choice per project. | ReaImGui |
| Select children of selected folders | Selects every track inside the selected folder tracks. | — |
| Copy selected track numbers | Copies the numbers of the selected tracks to the clipboard, separated by commas. | SWS |

### Mixing

| Script | What it does | Needs |
|---|---|---|
| Exclusive solo click mode | A toggle: while it is on, clicking a track's solo button solos only that track. | js_ReaScriptAPI |
| Reset all track volumes to 0 dB | Sets every track's volume fader to 0 dB. | — |
| Pan presets | Pan the selected tracks 50, 70 or 100 percent left or right, one action each (six actions). | — |

### Editing

| Script | What it does | Needs |
|---|---|---|
| Create doubles from takes | Makes a staggered left and right pair from a lead track's takes, named "1 L" and "2 R" and panned hard left and right. | — |
| Extend items to fill gaps | Extends each selected item's end to the start of the next item across the selected tracks (no time-stretching). | — |
| Smart zoom | Cycles the arrange view through set bar lengths, then fits the loop, the selected items, the region or the whole project. | — |
| Set project end and render range to cursor | After asking, ends the project at the edit cursor and sets the render range from the start to the cursor. | SWS |
| Rename plug-in everywhere | Renames every instance of the selected plug-in across the project in one go. | — |
| Clean up FX names in focused chain | Tidies the plug-in names in the FX chain you are looking at: drops prefixes such as "VST3:" and "AU:", maker names in brackets and UADx tags. Names you renamed yourself are left alone. | — |

## Licence

Copyright (c) 2026 BLV. All rights reserved. Free to use. You may not copy, modify, repackage or redistribute this software. See `LICENSE.txt`.
