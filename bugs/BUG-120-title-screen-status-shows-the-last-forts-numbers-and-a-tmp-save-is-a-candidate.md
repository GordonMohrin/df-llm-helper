# BUG-120 After a restart `status` reports the last fort's numbers as if they were live, and a half-written `autosave N_tmp` is a load candidate
Status: fixed in the M7 commits (offline, live-untested): status and brief print `DF at title screen: no fort loaded` and none of the
old numbers while supervise sees DF up with no live fort; `pick_save` and the backup skip a save that DF died writing; the loader
logs what the screen shows when it cannot find a label (FR-91)
Severity: high (the game session reported "day 61, pop 44" of a fort that was not loaded; a crash during an autosave leaves the
newest folder half written, and the chain would load it)
Found: 2026-10-28, Run 14 (Trussroads), game session note 99 (c) and (d)
Module: `dfpilot/brief.py` (`status_text`, `brief_text`, `title_lines`), `dfpilot/paths.py` (`save_name`), `dfpilot/supervise.py`
(`scan_saves`, `pick_save`, `_backup_step`), `dfpilot/loadsave.py` (new), `lua/dfllm.lua`, `tools/embark/loadsave.lua`

## Actual
(d) After DF was restarted and sat at the title screen, `dfllm status` printed the pop, day, stock and alarm numbers of the fort
that had run before. (c) A kill during an autosave leaves `autosave 3_tmp` (DF's name while it writes) as the newest folder; the
note asks that it is never offered.

## Cause (proven from the code at 32994bb)
1. **(d) status reads files only and every file of the last fort is still there.** `paths.save_name` (paths.py:64-69) takes
   `ACTIVE`, else `_last_save()` (paths.py:46-61: the newest runtime folder). After a crash `ACTIVE` stays (kern deletes it only on a
   clean unload, kern.lua:1622), so `status_text` (brief.py:770) builds `Ctx` from `state.a/b.json` and prints `line_head`
   (brief.py:107-122: DEFCON, clock, `hb <age>`) and all the pop/stock lines; the only hint of staleness is the small `hb 14m`. No
   code asks whether DF shows a fort at all. The one component that knows is supervise: `_pass` sets `r["why"] = "no dfllm fort loaded
   (title screen or an unmarked save)"` when DF is up and ACTIVE is missing or older than the DF process (supervise.py:1249-1266) and
   writes it to `supervise.json` `last` every minute; nothing read it back for status. In game `dfhack-run dfllm status` printed
   `kernel not running` also at the title screen, without saying why (lua/dfllm.lua:57-60).
2. **(c) `pick_save` looks at `saves[0]` and its name is never read.** `scan_saves` (supervise.py:428-451) lists every folder with a
   `world.sav`, newest first; `pick_save` (supervise.py:478-502) takes `saves[0]` and checks marker, fort, session, size and age. A
   `autosave 3_tmp` that holds a `world.sav` (written last, so a kill late in the write leaves one) with the dfllm marker passes all of
   them and is loaded by name (`load-save autosave 3_tmp`); the same entry is the backup source (`_backup_step`, supervise.py:1330-1331:
   `marked[0]`). A folder without `world.sav` is invisible and so never named in a refusal.
3. **The title-screen loader says what it saw only as `rows` (240 characters) and the `title` fields**
   (loadsave.lua `r.rows`, `r.title`): the viewscreen stack, the cells' tiles and the full list were not recorded, so a run that found
   no label left too little to decide the labels of the 53.16-r3 menu.

## Fix
1. `dfpilot/brief.py` `title_lines`: when `supervise.json` `last` (<= 240 s old) says `df up`, `active` None and `live` false, and the
   fort's own heartbeat is not fresh (<= 120 s with ACTIVE naming this fort), status prints `DF at title screen: no fort loaded`, that
   no dfllm fort runs, that the saved state is N old and NOT live (numbers withheld), `dfllm supervise --load`, and the `needs_click`
   alarm when there is one; brief prints the same under `# brief`. `df down` prints `DF is not running: no fort loaded`. No
   supervise.json, an old pass, a fort seen by supervise or a fresh heartbeat: unchanged output. `lua/dfllm.lua` `status` says
   `DF at title screen: no fort loaded (kernel not running)` when `dfhack.isMapLoaded()` is false.
2. `dfpilot/loadsave.py` (pure): `mark` sets `bad` on every scanned folder (a `*_tmp` name, no or empty `world.sav`, a file all siblings
   have: `world.dat` when at least two others all have it), `writing` for a `_tmp` folder whose files are younger than 300 s.
   `scan_saves` returns those flags (and lists folders without world.sav with `partial=True`); `pick_save` takes the newest COMPLETE
   save (never an older one than that), waits when a `_tmp` folder is being written, names the skipped ones; `_backup_step` and
   `wait_for_save` ignore `bad` entries.
3. `tools/embark/loadsave.lua` `L.dump`: once per run, when the main menu has no Continue/Load, an unknown screen is seen, or the third
   click did not change the screen: the viewscreen stack, kind, size, `viewscreen_titlest` fields, <= 40 numbered rows, <= 60 cells with
   their tile. `title_run` returns it, `_load_once` logs it once per chain in supervise.log and keeps a small record in
   `supervise.json` `title_dump`; `dfllm doctor` prints it.

## Not decided offline
Whether `world.dat` (the companion rule) is a file DF 53 writes: the rule stays silent with fewer than two siblings and only fires when
every sibling has the file. Whether DF names an interrupted autosave `<name>_tmp` as note 99 says and whether it keeps a `world.sav`
inside. Whether a running unmarked fort (supervise's `df up, no ACTIVE`) is worth a line of its own: it prints the title line plus
"no dfllm fort is running". Read-only live data: `dir` of the save folder after an interrupted autosave (names, sizes, mtimes), and
`python -m dfpilot supervise --saves` at the title screen.

## Tests
`tests/test_m7_load.py` (all 21 fail on 32994bb): the crash chain never loads the `_tmp` save, `pick_save` skips a dead `_tmp` and
waits for a live one, the backup, `world.sav`/`world.dat` completeness, `--saves`, the status/brief title line and every case that
keeps the old output, doctor, `--reset`, the dump log. `tests/lua/test_loadsave_dump.lua`, `tests/lua/test_m7_title.lua`.

Related: BUG-098, BUG-099, FR-81, FR-91
