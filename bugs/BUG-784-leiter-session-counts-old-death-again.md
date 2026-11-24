# BUG-784 `leiter --sitzung` counted a death reported before the session start again
Status: fixed (offline, live-untested)
Severity: low
Found: 2026-11-23, NEU1 verifier (offline): a unit whose first DEATH came before `--start` counted as a session death when its 'found dead' revision arrived during the session; the first fix only looked one season back.
Module: `dfpilot/leiter.py` (`session_lines`)

## Actual
`session_lines` loaded the events since the start n and deduplicated within that window only; missing dwarves are often found seasons later, so the revision counted as a new death.

## Fix
The set of units already dead at the start is read from every DEATH event with n <= the start n (`wertung.load_events(save_dir, 0)` without a tick floor); those units are dropped from the session deaths.

## Tests
`tests/test_neu1_wertung_leiter.py::test_session_skips_deaths_reported_before_start` (first report three seasons before the start, revision and one old-age death during the session: 'Tote 1 (Alter 1)').

## Live-Erwartung
1. `dfpilot leiter --start` at a session start and `--sitzung` at its end print a SITZUNG line whose deaths equal the DEATH events of that span.
2. A dwarf first reported dead (missing) before `--start` and found dead during the session is not counted in the SITZUNG deaths.
