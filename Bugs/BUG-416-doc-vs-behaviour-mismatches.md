# BUG-416: documentation vs behaviour mismatches in the Lua helpers (`config aquifer`, `tempo rate`, "read-only" report, positions `--force`, handel.log growth)

- **Status:** open
- **Severity:** S3
- **Area:** `lua/claude/config.lua:6,15` + `:308-323`, `lua/claude/tempo.lua:2`, `lua/claude/report.lua:1,171-186`, `lua/claude/positions.lua:62`, `lua/claude/handel.lua:44` (`emit` -> `log`), COMPANION.md
- **Reported:** 2026-10-02, commit `6dedd96`
- **Environment:** Windows 11 Pro, game running (DF 53.16 + DFHack, **paused**, fort "Windrings", date `27. Granite, Jahr 118`)

## Command / steps and results
1. `./dfhack-run.exe claude/config aquifer` -> byte-identical to `claude/config` (`Bugs/evidence/BUG-416/config_aquifer_arg_ignored.out.txt`). The header (config.lua:6 and the embark checklist line 15/39: "repeat `claude/config aquifer` for every newly discovered tunnel") describes a subcommand; the script ignores all arguments and always scans the fixed `FORT_BOX` x `SURFACE_Z-40..SURFACE_Z` (0.5-0.6 s). There is no way to scan a different box/z range.
2. `claude/tempo` usage line (`tempo.lua:2`) lists `rate`; no branch exists (`cmd == 'rate'` falls through to the status output). The undocumented `say` branch exists (`tempo.lua:202`).
3. `claude/report` is "read-only, changes nothing" (header) but appends one CSV line to `<home>/metrics.csv` on every call (`report.lua:171-186`; file grew 15,291 -> 20,555 bytes while I made ~12 report calls plus other agents' calls). Intended ("measurement log for feedback loops") but contradicts the header and COMPANION.md; it also means `report` is not idempotent for the trend data (two calls in the same second add two rows). `is_write("claude/report")` is False.
4. `claude/positions assign|vacate` can never run: the guard `not a.force` (positions.lua:62) tests a field of the plain argument array (`a.force`), which is never set; the script is marked DEPRECATED, so this is just dead code - verified live: `claude/positions assign MANAGER 315` -> `"veraltet: bitte claude/aemter assign|vacate benutzen"`.
5. `claude/handel`: `emit()` logs the **complete JSON answer of every call** (also `status`, `plan`, `scan`) to `tools/out/handel.log` (no rotation). The file is 1,330,652 bytes now and grew ~28 KB during ~25 handel calls of this test. Similar unbounded logs: `tools/out/mil.log` (every `mil` call, 14,984 -> 18,455 bytes), `metrics.csv`.
6. `claude/schau profile ...` is documented (`docs/manual-v3/10-camera.md:16,24`, `docs/INTEGRATION.md:131`) and present in the repo `schau.lua`, but missing in the live copy (answer: usage text without `profile`), see BUG-420.
7. Header of `claude/mil` "no change without --apply" is wrong for `update` and `refuge` (BUG-407).

## Expected
Docs and code agree; read-only commands do not append files (or say so).

## Evidence
`Bugs/evidence/BUG-416/config_aquifer_arg_ignored.out.txt`, `tempo_status.out.txt`; item 3 and 5 are file-size observations (`tools/out/handel.log`, `metrics.csv`, `tools/out/mil.log` in the live runtime folder `dwarf-fortress/`).

## Suggested fix (optional)
Implement `config aquifer [x1 y1 x2 y2 z1 z2]` (the function `aquifer_seen(x1,...)` already takes them) or delete the references; drop `rate` from the usage; move the metrics append of `report` behind `report log` or document it in COMPANION.md; log only failures in `handel.emit` (or truncate to N KB).

## Info needed
- Player: is the metrics.csv side effect of `report` wanted on every call, or only for the periodic call of the orchestrator?
