# BUG-207: `digcheck` reports `ok (0 tiles)` (exit 0) when nothing was checked: unknown stage name, empty CSV, non-`#dig` CSV; R1/R4 are skipped for unrevealed tiles

- **Status:** verified fixed (retest 2026-10-02, 8e67f05)
- **Severity:** S2 (typo in a stage name = green light; the checker is meant to gate dig orders)
- **Area:** `df_llm_helper/features/digcheck.py` `parse_stages` / `parse_qf_csv` / `cmd_digcheck` (no check for an empty target set), `check_targets` (the `if ch == "?": ... continue` comes before R1 and R4)
- **Reported:** 2026-10-02, commit `6dedd96`
- **Environment:** Windows 11 Pro, Python 3.14.3, game running (DF 53.16 + DFHack, paused), fort date 27. Granite, Jahr 118; live `claude/pilot_digcheck dump`

## Command / steps
```
cd "<project folder>"
python -m df_llm_helper digcheck --stages ../dwarf-fortress/lua/claude/stages.lua --stage NOPE
python -m df_llm_helper digcheck --csv "Bugs/evidence/BUG-207/empty.csv" -c 128,140,99
python -m df_llm_helper digcheck --csv "Bugs/evidence/BUG-207/b.csv" -c 128,140,99      # file content: "#build\nCw"
python -m df_llm_helper digcheck 103 90 90 95 95        # z below z_min (104)
python -m df_llm_helper digcheck 141 90 90 95 95        # z above z_max (140), for comparison
```

## Expected
- 0 targets -> `digcheck NOPE: nothing to check (stage not found / no #dig cells)`, exit 2 (refused), never `ok`.
- R1 (level outside 104..140) is a property of the target, not of the tile content: `z103` must be reported as `R1`, also when the tiles are unrevealed.

## Actual
```
digcheck NOPE: ok (0 tiles)                       rc 0
digcheck empty.csv: ok (0 tiles)                  rc 0
digcheck b.csv: ok (0 tiles)                      rc 0     (a #build blueprint)
digcheck rect 103 90 90 95 95: unsafe (36 tiles, 36 unrevealed not judged)   rc 1      <- no R1
digcheck rect 141 90 90 95 95: refused (36 tiles, R1 x36, R2 x36, R6 x36)   rc 2      <- R1 shown when the tiles are "revealed"
```

## Evidence
`Bugs/evidence/BUG-207/` (outputs, `empty.csv`, `b.csv`, raw dump answers `l_d_r1.jsonl`).

## Analysis (reporter's hypothesis)
`check_targets` does `if ch == "?": rep.unrevealed.append(t); continue` before the `R1` and `R4` (forbid box) tests (digcheck.py ~line 189-199). The empty-target case is simply not handled in `cmd_digcheck`.

## Suggested fix (optional)
Move R1/R4 above the unrevealed `continue` (geometry only). If `not targets`: print a refusal naming the cause (stage not found / file has no dig cells / wrong blueprint mode) and return 2.

## Info needed
None. Also noted (S3, same area): coordinates outside the map (`digcheck 130 -5 -5 2 2`, `digcheck 999 0 0 5 5`) are handled as "unrevealed (not judged)" instead of "outside the map (192x192x153)".

## Fix
0 targets (unknown stage, empty CSV, CSV without `#dig`) -> `digcheck <name>: refused - nothing to check (<cause>)`, rc 2. R1/R4 (and negative coordinates as `outside the map`) are judged before the unrevealed `continue`. Test: `test_bug207_*` (recorded dump `fixtures/bugs/BUG-207/l_d_r1.jsonl`). Not done: tiles beyond the map size (no map size in the dump) stay 'unrevealed'.
