# BLV ReaLobby changelog

## 0.1.2 (2026-11-15)

Now for Windows too (checked on Windows 11 with REAPER 7.82 and ReaImGui 0.10.0.5), as well as macOS.

- Pressing Esc to close a song's right-click menu no longer closes the whole ReaLobby window.
- The clean-up list shows each file relative to the song's folder on Windows too ("Audio/take.wav"), not its full path.
- The unused-audio check lists each folder once, so it finishes sooner (most noticeable on Windows, where each folder listing takes about a quarter of a second).

## 0.1.1 (2026-11-15)

First public release, on ReaPack. macOS only; Windows not yet checked. Needs REAPER 7.74 or newer and ReaImGui.

- Search filters. Type them in the search box, alone or with words: `bpm:95-100`, `bpm:>120`, `tracks:>20`, `saved:<7d`, `opened:>30d`, `time:>2h`, `status:mixing`, `artist:xi`, `uses:pro-q` (songs that use a plug-in). Quote a value with spaces: `uses:"pro-q 3"`. Hover the search box to see them all.
- Time worked: ReaLobby counts how long you work on each song in REAPER and shows it under the song's details. It counts while the song is the open tab and pauses after 5 minutes without mouse movement, edits or playback. Every version of a song adds to one total, and a renamed or moved song keeps its time. It runs quietly in the background once ReaLobby has opened; switch it off in Settings → Time worked. The times stay on your computer.
- Unused audio: the song's details show how much audio in its media folders no project uses. Click it (or "Clean up unused audio…" in the song's right-click menu) to see the files and move them to the Trash. A file is kept when any version or backup of a project in the song's folder, or any other song in the list, uses it, even inside a plug-in's saved settings, and bounces are never offered. Nothing is cleaned while the song is open in REAPER.
- New footer option "Bring FX online after load". The song opens with every plug-in switched off, then ReaLobby switches them back on a few at a time, so a heavy session opens without freezing REAPER. It keeps going after the ReaLobby window closes; if you open ReaLobby again while it runs, the footer shows how far it is. If "Open with FX offline" is also ticked, that one wins and the plug-ins stay off.
- Plug-ins you saved switched off always stay off. ReaLobby recognises each plug-in by its own ID, not by its place in the chain, so moving or adding plug-ins while it works cannot switch on the wrong one. A container that holds a plug-in you saved switched off stays off as a whole. When ReaLobby is not sure, it leaves a plug-in off.
- If ReaLobby was stopped before it finished (for example by running it again and choosing to stop the running copy), the next time it opens it says "Some plug-ins may still be offline from the last open."
- Switching plug-ins back on marks the project as changed, and a few "BLV ReaLobby: bring FX online" steps may appear in Undo History.
- New footer option "Open in new tab": the song opens in a new project tab and the song you have open stays open in its own tab. ⌘↵ (Mac) does the same for one song, and so does "Open in new tab" in a song's right-click menu and in the right-click menu of a backup or an older version. Windows is untested.
- A song that is already open in a tab is not opened a second time: ReaLobby brings its tab to the front.
- If a song cannot be opened in a new tab, the empty tab ReaLobby made is closed again.
- The footer's choices are remembered the next time ReaLobby opens.
- New "Open folder" button under a song's details, and in its right-click menu: opens the song's project folder in Finder or Explorer.
- The glass grain is about half as strong.
- ReaLobby now always opens dead centre of the screen REAPER is on, and is never larger than that screen.
- ReaLobby is now in REAPER's action list (Actions > Show action list, search "BLV_ReaLobby"), so you can open it at any time, give it a shortcut or put it on a toolbar. Running it while ReaLobby is already open brings the window back to the centre.

## 0.1.0 (2026-11-14)

First test build. macOS; Windows not yet checked. Needs REAPER 7.74 or newer and ReaImGui.

- Shows all your songs in one window: the ones in REAPER's recent list plus any folders you choose. Choose… opens a folder browser that shows how many projects each folder holds.
- Recent lists the songs you opened here first, newest first, then the rest in REAPER's own recent order.
- Saved versions of a song (Name_005.RPP) are folded into one row that opens the newest.
- Type to search. Arrow keys move, Enter opens.
- Shows each song's title and author from Project Settings, and its tempo, length, tracks and plug-ins.
- Lists a song's latest bounces (also from bounce folders you add in Settings), its last 8 backups and its older versions. Click a backup or an older version to open it; shift-click opens it with FX offline.
- Never downloads a project that is only in the cloud: it is listed by file name as "not downloaded" until you open it.
- Pin favourites and mark songs Writing, Mixing or Done.
- Start a new project from a template and name it in one step.
- Open a song normally, with FX offline, or as a new project ignoring the default template.
- Edit a song's notes, title and author, rename it, move it or archive it. You see every file that will change first, and nothing is changed while the project is open in REAPER. Editing notes, title or author makes a backup first.
- A renamed, moved or archived song stays listed even when it is outside your folders.
- Delete sends the song to the Trash.
- Hides songs whose files are gone.
- Can run at startup. The first-run screen offers it. Only one ReaLobby window opens at a time.
