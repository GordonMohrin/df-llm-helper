# BUG-410: scripts that do not print one JSON object (`felder`, `area`, `mil report`, `mil tabelle`) or print nothing at all (`felder foo`, `muell foo`)

- **Status:** fixed in 04eda95
- **Severity:** S3 (doc mismatch; `muell`/`felder` silent branches are S3 too)
- **Area:** `lua/claude/felder.lua:15-35`, `lua/claude/muell.lua:20-70` (no `else`), `lua/claude/area.lua`, `lua/claude/mil.lua` (`report`, `tabelle`), COMPANION.md ("All scripts print one JSON object (`util.emit`)")
- **Reported:** 2026-10-02, commit `6dedd96`
- **Environment:** Windows 11 Pro, game running (DF 53.16 + DFHack, **paused**, fort "Windrings", date `27. Granite, Jahr 118`)

## Command / steps
```
cd "E:/Program Files (x86)/Steam/steamapps/common/Dwarf Fortress/hack"
./dfhack-run.exe claude/felder list
./dfhack-run.exe claude/felder foo
./dfhack-run.exe claude/muell foo
./dfhack-run.exe claude/area 130 80 90 10 5
./dfhack-run.exe claude/mil report
```

## Expected
Either JSON, or (for the documented text reports) an explicit statement in COMPANION.md; unknown subcommands should print a usage JSON (`{"error":...}`) so a caller can tell "no answer" from "wrong command".

## Actual
- `claude/felder list` -> tab separated lines `1368\t132\t103\t93\t107\t93\tTURNIP,TURNIP,TURNIP,TURNIP` (not JSON, no header). `claude/felder foo` -> **empty output**, exit 0. `claude/felder set` without arguments prints the plain text `unbekannte Pflanze nil` (not JSON).
- `claude/muell foo` -> **empty output**, exit 0 (only `status` and `dump` are handled, no `else`); `muell` in the repo also has `local zmin, zmax = ...` that are never used (`dump` ignores the z range).
- `claude/area ...` and `claude/mil report` / `claude/mil tabelle` print plain text. They are intentional (fixtures `area_z130.txt`, `mil_report.txt`, `mil_tabelle.txt`) and `is_write`/parsers know them; only COMPANION.md's sentence is wrong.
- Scripts that are modules and print nothing when called as a command (`bauhelp`, `timer`, `util`, `stages`, `sperre`; `config` is dual-use) are fine.

## Evidence
`Bugs/evidence/BUG-410/felder_list.out.txt`, `felder_foo.out.txt` (0 bytes), `muell_foo.out.txt` (0 bytes), `area_default.out.txt`, `mil_report.out.txt`.

## Analysis (reporter's hypothesis)
Early scripts (`felder`, `muell`) predate `util.emit`.

## Suggested fix (optional)
Give `felder` and `muell` an `else` branch with `util.emit({error=..., usage=...})`, make `felder list` emit `{plots=[{id,z,x1,y1,x2,y2,plants[4]}]}`; amend COMPANION.md: "all scripts print one JSON object except `area`, `mil report`, `mil tabelle`".

## Info needed
none.

## Fix
felder/muell unknown commands and felder errors print one JSON object; COMPANION.md names the plain-text reports (area, mil report/tabelle, felder list).
