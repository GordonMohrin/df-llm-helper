# BUG-098 DFHack 53.16-r3 renamed the title screen field `load-save` writes: every automatic restart ends at the title screen
Status: fixed in the K2 commit (offline, live-untested): when the stock `load-save` fails, supervise loads the same save from the
title screen by clicks (tools/embark/loadsave.lua, run through tools/embark/embark.lua); the click path is calibrated by its first
live use (it logs the rows it saw and the pixel it clicked)
Severity: critical (a crash of DF is no longer healed: the fort stays down until a human clicks Continue)
Found: 2026-10-23, Run 14 Trussroads y586, note 71 of bugs/RUN11-offene-bugs-und-FR.md (the game session; DFHack went from
53.16-r2 to 53.16-r3 in the middle of the session, probably the Steam auto-update, then DF crashed (the known region2 embark leak))
Module: `dfpilot/supervise.py` (`_start_and_load`, base lines 832-872), `tools/embark/` (new `loadsave.lua`)

## Actual
`dfhack-run load-save region2` stops at `...load-save.lua:17: Cannot write field viewscreen_titlest.sel_menu_line: not found.` The
field is `selected` (int32, with `selected_r`) in r3. Writing `selected` and `gui.simulateInput(title, 'SELECT')` (also
`MENU_CONFIRM`, `STANDARDSCROLL_DOWN`) changes nothing, neither `mode`/`selected` nor the screen stack: the title menu of this DF
follows the mouse (note 71's own reading; the embark helper found the same for every menu of 53.16, README "Live L0 findings").
`gui/load-screen` is tagged unavailable. The supervisor's whole crash chain (Steam start, window to desktop 1, load) therefore
ran into the stock script and failed for every fort and every crash, whatever the save.

## Cause
`dfpilot/supervise.py:850-856` (base): the load loop knows one way to load, `o.dfhack("load-save", name)`; a failure other than
"can't find save" only sleeps 5 s and calls it again, until `LOAD_MAX_S` (843-844) ends the chain with "load-save did not start
within 15 min". The script itself is DFHack's (`hack/scripts/load-save.lua:17` writes `scr.sel_menu_line`); the field exists in
DFHack before r3 only. Nothing in the repo clicked a menu to load a save: the proven click engine (`tools/embark/input.lua:49-62`
hover, press, hold; `steps.lua:88` `S.newgame` clicks the title menu "title.new", live in L0) served new games only.
The repo read no DFHack version either (`grep -ri dfhack_version`: nothing), so the change was invisible until the restart failed.

## Fix
1. `tools/embark/loadsave.lua` (new): the click path as the `load` mode of the embark runner. Pure text functions (`norm`, `token`
   `find_all`, `target`, `is_main`, `main_button`, `confirm_button`, `danger`, `loading`, `screen`, `brief`) decide from the rows of
   the screen; two steps: `load.stock` (DFHack's `load-save`, only where `viewscreen_titlest.sel_menu_line` exists) and
   `load.drive` (per screen: main menu -> click "Continue ..." else "Load ..."; the list -> click the entry that shows the folder
   name as a whole token; a popup -> Okay/Yes/Load/...; loading -> wait; click again when the screen did not change). It clicks
   only on the title family of screens and never when a popup talks of deleting. Both field names are read (`embark.lua:97`
   `source().title`, pcall per field: `old_field`, `sel_menu_line`, `selected`, `selected_r`, `mode`), nothing is written to the title
   screen. `embark.lua` gets `W.stock_load` and the command `load <save> [--entry T] [--no-stock]`; `steps.lua` the mode;
   `ui.json` the `load` limits; `embark.py load SAVE [--entry T] [--no-stock]` runs it by hand and prints the clicks and rows.
2. `dfpilot/supervise.py:1057` `_start_and_load` / `:962` `_load_once`: the stock script first; on "can't find save" no clicks (a
   different problem), while dfhack-run cannot connect (`load_kind`, `UNREACHABLE_RE`) or "can't find title" for less than
   `TITLE_GRACE_S` (90 s) the old waiting; on the field error and on any other failure `title_run` (`:907`): the spec file, ONE
   `dfhack-run lua -f embark.lua run <spec>`, then `<runtime>/embark/status.json` is read; a run over `TITLE_RUN_MAX_S` (150 s) is
   stopped (nothing keeps clicking unseen). Runs are 20 s, 40 s, 80 s ... (at most 300 s) apart; the retry loops and the 15-minute
   limits are unchanged; the second load after `LOAD_RETRY_S` takes the same path; a fort that a human brought up meanwhile ends the
   loop (`_fort_live`). The failure text names the DFHack version and the reasons: `load did not start within 15 min on DFHack
   53.16-r3: title screen: load.drive: "autosave 1" is not on the screen (nothing clicked here); stock load-save: Cannot write field
   viewscreen_titlest.sel_menu_line: not found.`
3. Shell policy: the embark helper is driven from Python (RULES 1.2 "the embark helper"), so `dfpilot/lint.py:1343` names the form
   instead of "inline lua" when someone calls `dfhack-run lua -f .../embark.lua` (a new head or allowlist entry is not needed: the
   hook sees `python tools/embark/embark.py load ...`, which is no dfhack-run call).

## Safety (what the click path can touch)
- It runs only in the restart chain (DF was down or killed in PEACE after an autosave) or by hand at the title screen: no fort is
  loaded, so a SIEGE, BREACH or lockdown, a fort of 7 or of 80, a reclaimed fort and the kernel state of an older reload are
  untouched by it; the kernel boots from the save as it does after the stock `load-save`. A kill in a DEGRADED restart keeps all
  its old guards (PEACE, unpaused, right after an autosave, `norestart.flag`, `live.lock`).
- Every click run is bounded: 150 s (`TITLE_RUN_MAX_S`, then `stop`), 14 clicks, 4 identical screens; runs 20 s ... 300 s apart; the
  whole chain 15 minutes as before. A `norestart.flag` or a held `live.lock` (a player at the menu) stops new runs (`_hands_off`);
  a fort that comes up meanwhile ends the loop (`_fort_live`).
- It clicks text it found on a title screen (Continue/Load, the named entry, Okay/Yes/Load on a popup) and nothing else: a fort,
  a map, an embark screen or a screen it does not know is never clicked; a popup that talks of delete, erase, overwrite, abandon or
  retire stops the run. The entry must show the folder name as a whole token, so no other (older) save is chosen from a list; only
  "Continue" without a list loads what DF calls the latest, which is the newest save supervise wants (`pick_save` takes the newest).
- It reads `viewscreen_titlest` fields (both names) and the text buffer, writes the mouse position and simulated clicks like the
  embark steps do (README section 1), no title screen field, no save file, no unit or item. The stock `load-save` runs only where
  its field exists.
- Old state: `supervise.json` of an older run lacks `dfhack`, `needs_click` and `last_loaded.ver`; every reader takes `.get`, so
  nothing is warned about until a version is known (the first successful load records it). An older supervise reading the new file
  ignores the new keys.

## Not decided offline
The live labels of the 53.16-r3 title menu and list (is it "Continue playing" or "Continue active game", does a list follow, does
it show the folder name or only the world and fort name, then `--entry`); whether one click is enough (the run clicks again when
the screen did not change) or the title needs the hover phase only; whether an entry loads at once or needs a Load button (both
handled); whether `selected` follows the hover (every look is in `status.json` `results.title`); the pixel DF accepts. Read-only data
that decides them: `python tools/embark/embark.py screen title53` at the title screen and again after Continue by hand
(`<runtime>/embark/capture/*.txt`), and the first `python tools/embark/embark.py load "<newest save>"` (prints every click with tile and
pixel, the last rows, the fields; supervise.log has the same for each run of the chain). Whether "Continue" without a list loads the
newest save (supervise wants the newest; a list entry is matched by name).

## Tests
`tests/lua/test_loadsave.lua` (fail on b2b9435: no module): token boundaries, pixel formula (10x15 and 12x18 px tiles), main
menu/list/popup classification, flows list / direct / confirm / select_load, a second click when the first is ignored, bounded clicks
when every click is ignored, save not on the list (only Continue is clicked), no Continue entry, a fort already loaded and screens
that are not the title family are never clicked, a popup that talks of deleting, stock first only where `sel_menu_line` exists.
`tests/lua/test_loadsave_entry.lua`: `embark.lua load` against fake `dfhack`/`df`/`gui`: both field names, the stock call,
`--entry`, `--no-stock`, nothing written to the title screen. `tests/test_supervise_k2.py` (fake OS and DFHack): stock still first,
field error -> title run with the spec and the logged pixels, any failure -> title run, no clicks on "can't find save", waiting
while DFHack starts, bounded and backed-off runs, hung and unstartable runs, a click-through that brings up no fort, the second load,
a human who clicks meanwhile. `tests/test_k2_surfaces.py`: the shell policy, `embark.py load`.

Related: BUG-099 (the failure was silent), FR-81 (the version watch), BUG-020 and README "Live L0 findings" (the click engine)
