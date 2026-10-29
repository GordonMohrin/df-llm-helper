# BUG-230 title-screen loader: cannot tell same-named worlds apart and never scrolls a list
Status: fixed (offline, live-untested)
Severity: medium (a save in the second of two same-named worlds, or below the visible rows, cannot be loaded by the helper)
Found: 2026-10-29, Run 15 embark on i2 (tool finding 6); the i3 agent got further with scroll_position_game_choice
Module: `tools/embark/loadsave.lua`, `tools/embark/embark.lua` (`source().title`, `W.scroll`, `load --world-folder`),
`tools/embark/embark.py` (`load --world-folder`)

## Actual
The loader matched list rows by their text only. With two worlds of the same name (`savegame_header_world`) the topmost row was
always clicked; writing `selected` plus SELECT does not choose a world. An entry below the visible rows of a list was never
reached: the run waited on "a title screen with neither the main menu nor ..." and failed.

## Fix
`embark.lua` reads (pcall, at most 60 entries) the header lists `savegame_header_world`, `savegame_header_game` and
`savegame_header` as `{folder = filename_noext, world = world_name, fort = fort_name}` and `scroll_position_world_choice` /
`_game_choice`; `W.scroll(which, n)` writes only those two scroll fields, only on viewscreen_titlest (= the mouse wheel).
`loadsave.lua` (`L.shown`, `L.index_of`, `L.world_index`, `L.list_row`, `L.header_pick`): the save's entry is found by its
folder; its row is the n-th row with that label, n counted from the scroll position as DF's list shows entries scroll+1, ...;
a target outside the visible rows is scrolled to the top (DF may clamp, the row is found again; at most 4 scrolls). The world
entry is the one of the save's folder, else `--world-folder`, else the only world named like the save's world; with several the
first is opened, a game list without the save answers Esc (LEAVESCREEN) and the next same-named world is opened; none left
fails naming the folders. Without header lists the text-only path runs as before.

## Tests
`tests/lua/test_loadsave.lua` `BUG-230 ...` (pure functions; same-named worlds with Esc and the second world; --world-folder;
world and game lists scrolled, clamped); `tests/lua/test_loadsave_entry.lua` `BUG-230 entry ...` (header vectors as DFHack shows
them, only the game scroll field written, `--world-folder`); `tests/test_embark.py::test_bug230_...`. All fail on 5e9e719.

## Live check
At the title screen with two worlds of one name: `python tools/embark/embark.py load "<save of the second world>" --no-stock`
ends `LOAD OK`; its output lists `worlds: 1:<folder>=<name>, 2:...` and, for a save below the visible rows, `scrolled the game
list to N`. If the header folders do not match the save folder, the output's `worlds:`/`games:` lines show what DF holds:
pass `--world-folder` or `--entry` accordingly.
