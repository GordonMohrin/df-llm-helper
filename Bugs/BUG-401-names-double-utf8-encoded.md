# BUG-401: unit names with non-ASCII characters are UTF-8 encoded twice (mojibake) in mil/gefahr/migranten output

- **Status:** open
- **Severity:** S2
- **Area:** `lua/claude/mil.lua:56` (`nm()`), `lua/claude/gefahr.lua:134`, `lua/claude/migranten.lua:18` in combination with `lua/claude/util.lua:14-24` (`emit`)
- **Reported:** 2026-10-02, commit `6dedd96`
- **Environment:** Windows 11 Pro, Python 3.14.3, game running (DF 53.16 + DFHack, **paused**, fort "Windrings", date `27. Granite, Jahr 118`)

## Command / steps
```
cd "E:/Program Files (x86)/Steam/steamapps/common/Dwarf Fortress/hack"
./dfhack-run.exe claude/mil status          # also: claude/mil enemies, claude/mil equip, claude/mil add 32 3750 (dry), claude/mil remove 32 3750 (dry)
./dfhack-run.exe claude/migranten plan 315
./dfhack-run.exe claude/units               # reference: correct
```

## Expected
Names are identical in all scripts, e.g. `Stinthäd ònulfeb "Mirroredarrows", Miner` (this is what `claude/units` returns).

## Actual
`claude/mil status` / `enemies` / `equip` (raw bytes are valid UTF-8, but the characters are wrong):
```
"name": "Monom Rig├▓thrith \"Craftedbell\", militia"      (should be: Rigòthrith)
"name": "Sibrek Udibitt├ís ..."                              (Udibittás)
"name": "Smunstu Ezr├╗amxu ..."                              (Ezrûamxu)
```
`claude/migranten plan 315`:
```
"unit": "Stinth├ñd ├▓nulfeb \"Mirroredarrows\", Min"
```
(The box-drawing characters are the UTF-8 bytes `C3 B2` etc. re-interpreted as CP437 and converted again.)
In the 271 raw answers I recorded, the pattern appears in exactly these scripts: 15x in `mil status`, `mil equip`, `mil enemies`, `mil add/remove` (dry run), 1x in `migranten plan`.

## Evidence
`Bugs/evidence/BUG-401/mil_status.out.txt`, `mil_enemies.out.txt`, `migranten_plan_315.out.txt`, `units_reference_correct.out.txt` (correct reference for the same unit 315).

## Analysis (reporter's hypothesis)
- `util.emit` runs `dfhack.df2utf` on **every** string of the table (util.lua:14-24, "to_utf8"), i.e. it expects CP437 input.
- `mil.lua:56` `nm()`, `gefahr.lua:134` and `migranten.lua:18` already call `dfhack.df2utf(dfhack.units.getReadableName(u))` themselves -> emit converts a second time. `claude/units` and `claude/pilot_*` pass the raw `getReadableName` and are correct.
- Second defect in the same lines: `:sub(1, 40)` is applied **after** `df2utf`, so a multi-byte character straddling byte 40 is cut in half (-> invalid UTF-8 in the JSON). Cut before converting, or by characters.
- Impact: any Python-side matching by name, the agent prompts and `fixtures/*` that contain names from `mil`/`migranten` are unreadable for German/accented names; with `claude/gefahr` the `ereignis` text of `sim/fire/selftest` contains `e.name` (all-ASCII beast names in my test, so not visible, but same path).
- Other `df2utf` users are fine because they write to files/`print` (killorder.lua:135/213/230, gesund.lua:62/319, mood.lua:68/380, watchdog.lua:339 goes into a flag file; `ueberwacher.lua:14` goes into a flag file). `auslastung.lua:64-71` converts and later calls `utf2df` before emit (round trip OK, checked on live `claude/auslastung report`).

## Suggested fix (optional)
Remove the `df2utf` in `mil.lua:56`, `gefahr.lua:134`, `migranten.lua:18` (keep `:sub` on the CP437 string, which is 1 byte per character, then let `emit` convert). For the places that write to files directly (`killorder.lua`, `watchdog.lua:339` slow_list -> flag) keep `df2utf`.

## Info needed
- Cloud session: please check `df_llm_helper` code that matches or prints names from `mil`/`migranten` output (fixtures `fixtures/run5/mil_*.txt` are ASCII-only, so tests cannot see this).
