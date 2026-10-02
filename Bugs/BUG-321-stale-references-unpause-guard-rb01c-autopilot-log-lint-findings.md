# BUG-321: Stale references after the watcher replacement: runbook rb05 and the KB entries `waechter_blind`/`guard_start` still tell the reader to restart `unpause-guard.ps1`; `rb01c_e18_release` and `autopilot log` do not exist; `docs/LINT-FINDINGS.md` lists findings that are gone

- **Status:** open
- **Severity:** S3
- **Area:** `data/runbooks/rb05_waechter_blind.yaml`, `data/kb/curated.yaml` (waechter_blind, guard_start), `data/runbooks/rb01_e18_pick.yaml`, `docs/manual-v3/05-tools.md`, `docs/LINT-FINDINGS.md`
- **Reported:** 2026-10-02, commit `50cee52`
- **Environment:** Windows 11, Python 3.14, game: running (DF 53.16 + DFHack) but PAUSED and untouched - this test uses the mock only

## Command / steps
```
cd <project folder>
python -m df_llm_helper --mock fixtures/run5 runbook show rb05_waechter_blind
python -m df_llm_helper --mock fixtures/run5 kb get waechter_blind
python -m df_llm_helper --mock fixtures/run5 kb get guard_start
python -m df_llm_helper --mock fixtures/run5 autopilot log
python -m df_llm_helper --mock fixtures/run5 lint lua
grep -n "^| .*.lua" docs/LINT-FINDINGS.md
```

## Expected
Every command, runbook, KB id and file named in the documentation exists and is current: the watcher section says `python -m df_llm_helper waechter --loop` (MANUAL 1, 8), not `unpause-guard.ps1` (replaced 2026-10-01, `tools/unpause-guard.ps1` is not part of this repository).

## Actual
Findings (verbatim evidence below; 112 backticked names in the docs were checked, 49 `python -m df_llm_helper <cmd> <sub>` forms from README/MANUAL/OVERVIEW/AGENT-PROMPT/INTEGRATION/manual-v3/specs were run with `-h`; everything else existed):

```
$ python -m df_llm_helper --mock fixtures/run5 runbook show rb05_waechter_blind
rb05_waechter_blind: Guard blind: last-report-id larger than the highest report
Symptom: last_report_id is not None and max_report_id is not None and max_report_id >= 0 and last_report_id > max_report_id
KB: waechter_blind
Player consent needed: False
 1. action: reset_report_id
 2. manual: Restart unpause-guard.ps1 (own process, e.g. Invoke-CimMethod Win32_Process Create); Start-Process -WindowStyle Hidden dies
Verify: last_report_id is not None and max_report_id is not None and last_report_id <= max_report_id
[exit 0]

$ python -m df_llm_helper --mock fixtures/run5 kb get waechter_blind
[waechter_blind] Guard blind: events.log empty, last-report-id too large
Cause: After a new game report IDs restart at 0; last-report-id.txt (e.g. 28181) stays -> no report is read. Runs 4 and 5.
Fix: Set the file to the highest report ID (python -m df_llm_helper guard does this), restart the guard (Invoke-CimMethod Win32_Process Create; Start-Process -WindowStyle Hidden dies). Runbook rb05_waechter_blind.
Source: SPEC appendix A5; session Run 5 08:01
[exit 0]

$ python -m df_llm_helper --mock fixtures/run5 kb get guard_start
[guard_start] PowerShell guard dies after starting
Cause: Start-Process -WindowStyle Hidden ends the process together with the calling shell.
Fix: Start via Invoke-CimMethod Win32_Process Create (independent process); check the syntax first; restart after a script change.
Source: Session Run 5
[exit 0]

$ python -m df_llm_helper --mock fixtures/run5 autopilot log
usage: df-llm-helper autopilot [-h] [--dry-run] [--loop] [--once]
                               [--interval INTERVAL]
                               [{run,rules,conflicts,enable}] [rule]
df-llm-helper autopilot: error: argument action: invalid choice: 'log' (choose from run, rules, conflicts, enable)
[exit 2]

$ python -c "does the runbook rb01c_e18_release mentioned in rb01_e18_pick.notes exist?"
rb01 note mentions rb01c_e18_release; exists: False
runbook ids: rb01_e18_pick, rb01b_e18_foreign, rb02_grabstau, rb03_kochschleife, rb04_alarm_burrow, rb05_waechter_blind, rb06_karawane, rb06b_karawane_abschluss, rb07_stimmung, rb08_hospital, rb09_aquifer, rb10_timestream, rb15_hunger_trotz_essen, rb16_abbruchschleife, rb17_koks_brennstoff, rb18_manager_buero, rb19_dienste_starten, rb20_fertigwaren_lager, rb21_flut
[exit 0]

$ grep -rn 'autopilot log' docs
docs/manual-v3/05-tools.md:34: - Every action is in `state.db` (`python -m df_llm_helper autopilot log` / table `actions`, rules `tools_miners`, `tools_pickfix`) with
[exit 0]
```

`docs/LINT-FINDINGS.md` table (documented findings) versus the real output of `lint lua`:
```
$ grep -n '^| .*\.lua' docs/LINT-FINDINGS.md
docs/LINT-FINDINGS.md:8: | bauprog.lua:83 L10 | Warning: reads tiles for its own planning (grid/build/mood slots); verify only revealed tiles are read |
docs/LINT-FINDINGS.md:9: | gesund.lua:200 L10 | Warning: reads tiles for its own planning; verify only revealed tiles are read |
docs/LINT-FINDINGS.md:10: | mil.lua:297 L08 | False positive: target of a squad station order (squad_order_movest), not a teleport |
docs/LINT-FINDINGS.md:11: | mood.lua:82 L10 | Warning: reads tiles for its own planning; verify only revealed tiles are read |
docs/LINT-FINDINGS.md:12: | mood.lua:213 L10 | Warning: reads tiles for its own planning; verify only revealed tiles are read |
docs/LINT-FINDINGS.md:13: | raster.lua:106 L10 | Warning: reads tiles for its own planning; verify only revealed tiles are read |
docs/LINT-FINDINGS.md:14: | pilot_caravan.lua:21 L07 | Intended: send stuck merchants home (`flags1.left`); df-llm-helper only calls it with an exception-register entry FP09 (player consent) |
[exit 0]

$ python -m df_llm_helper --mock fixtures/run5 lint lua
lua\claude\bauprog.lua:83: L10 reading a tile without checking 'discovered' (designation.hidden) (warning)
lua\claude\gesund.lua:200: L10 reading a tile without checking 'discovered' (designation.hidden) (warning)
lua\claude\mood.lua:82: L10 reading a tile without checking 'discovered' (designation.hidden) (warning)
lua\claude\mood.lua:213: L10 reading a tile without checking 'discovered' (designation.hidden) (warning)
lua\claude\raster.lua:128: L10 reading a tile without checking 'discovered' (designation.hidden) (warning)
lua\pilot_caravan.lua:21: L07 setting unit 'left' (stuck traders, exception required)
6 findings (1 errors)
[exit 1]
```

The table claims `mil.lua:297 L08` (no longer reported: the `unless_prev` exemption was added) and `raster.lua:106 L10` (now `raster.lua:128`); the test `test_bundled_lua_scripts_linted_without_crash` only checks that new findings are documented, not that documented ones still exist.

## Evidence
`Bugs/evidence/BUG-321/*.txt`.

## Analysis (reporter's hypothesis)
Left-overs of (a) the PowerShell watcher replacement (MANUAL 8: "Deadman: df-llm-helper only. The PowerShell watcher is replaced"), (b) a runbook id that was planned but never written (`rb01c_e18_release`; the KB entry `e18_release` is the only text), (c) `manual-v3/05-tools.md:34` documenting a non-existent `autopilot log` sub-command (`autopilot` has `run|rules|conflicts|enable`).

## Suggested fix (optional)
rb05 step 2 / KB waechter_blind + guard_start: replace by `python -m df_llm_helper waechter --loop` started as an independent process (MANUAL 1); rb01 note: point to `kb get e18_release`; `05-tools.md`: use `bus read`/`journal`/the `actions` table or implement `autopilot log`; trim the findings table (or make the test assert each documented finding still exists).

## Info needed
Already reported elsewhere (not repeated here): `LINT-BEFUNDE.md` file name in OVERVIEW/CHANGELOG -> BUG-119 item 4.
