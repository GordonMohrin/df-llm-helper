# BUG-104: `--mock` together with `--config` is not isolated: a mock run deletes real flag files and writes fixture data into the live `state.db`; the live DB already contains mock rows

- **Status:** open
- **Severity:** S2
- **Area:** `df_llm_helper/cli.py:1203-1204` (`force_overrides(mock_overrides() if (args.mock or args.replay_file) and not args.config else None)`), `df_llm_helper/config.py:161-168`
- **Reported:** 2026-10-02, commit `50cee52` (code identical to `6dedd96`)
- **Environment:** Windows 11 Pro, Python 3.14.3, game running (DF 53.16 + DFHack, **paused**), fort "Windrings", date `27. Granite, Jahr 118`

## Command / steps
```
cd "<project folder>"
python Bugs/evidence/BUG-104/repro.py                # temp folder only
# the dangerous form, on a real installation (do not run live):
python -m df_llm_helper --mock fixtures/run5 --config config.yaml autopilot
```

## Expected
`--mock` / `--replay-file` never touch the live tools folder or `data/state.db` (README: "report from recorded real game answers (own state in runtime/mock/)"; commit abdc26c "mock runs isolated from live state").

## Actual
The isolation is skipped when `--config` is present ("an explicit --config wins" - only a code comment, not in `--help`, README or MANUAL). With the player's normal `config.yaml`
(`paths.tools` -> the live tools folder) a mock run is a real run for everything that is *not* a DFHack command:
```
flag exists before: True                       (stale alert.flag, 238 min old, in the configured tools folder)
$ python -m df_llm_helper --mock fixtures/run5 --config <cfg> autopilot
stale_alert_flag: delete_flag flag:alert -> deleted
flag exists after : False    state.db written: True
```
The mock autopilot deleted the real flag (the same rule would delete real `dig/migranten/notfall/wirtschaft/food/mood` flags), the fixture snapshot (pop 24, Y102) goes into the configured `state.db`, and
`heartbeat`, `guard.state`, loop-protection counters etc. are written too. Control run without `--config` is isolated (section B of the output).

**The live `data/state.db` is already polluted with mock data** (`Bugs/evidence/BUG-104/live_state_db_readonly_queries.txt`): snapshot ids 1 and 4 (08:07, 08:29) are the fixture
`12. Hematite, Jahr 102 / pop 24 / drink_days 76 / jobs 199`, in between real `Y116`/`Y118` rows with the same `game_id`. Consequences seen today in the live digest/metrics:
spurious trends `~ Dig jobs 63->0 / Drink days falling 76->49 / Food days falling 189->85 / Idle 30%->57% / Open jobs 199->101` in the first live `digest`, and two bogus rows (`Y102 pop 24`) in `metrics` output.
(I cannot tell which command produced them; it was before this test session. An explicit `--config` with `--mock` is the only way I found that does it with the current code.)

## Evidence
`Bugs/evidence/BUG-104/repro.py`, `output.txt`, `live_state_db_readonly_queries.txt`.

## Analysis (reporter's hypothesis)
The isolation overrides are applied only `if ... and not args.config`. `--mock` should always override `paths.state_db/tools/scopes/gamelog` (and `journal.events_log`), whatever else the config says
(an explicit config may still change thresholds/rules). Provide `--mock-home <dir>` if a test needs a particular folder.

## Suggested fix (optional)
`force_overrides(mock_overrides() if (args.mock or args.replay_file) else None)`; if the user wants own mock paths they can set `DF_LLM_HELPER_HOME`.

## Info needed
Gordon: the live `data/state.db` has mock rows in `snapshots`/`kpis` (ids 1 and 4). Do you want them removed (e.g. `DELETE FROM snapshots WHERE id IN (1,4)` + matching `kpis`) or `state.db` rebuilt? The tester did not touch it.
