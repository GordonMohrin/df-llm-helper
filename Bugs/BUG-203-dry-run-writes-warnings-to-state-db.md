# BUG-203: `--dry-run` is not dry for `mood reserve`, `siege`, `caravan`: critical/warn rows are written to state.db and show up in the next `check`

- **Status:** verified fixed (retest 2026-10-02, 8e67f05)
- **Severity:** S2 (a dry run can raise a CRIT warning that wakes the orchestrator; verified for siege, mood reserve and caravan)
- **Area:** `df_llm_helper/cli.py:705` (`cmd_mood`: `mm.reserve()` gets no `dry`), `df_llm_helper/moods.py:279` (`reserve`: `store.warn` unconditional); `df_llm_helper/siege.py` `SiegeRunner.run` `finally:` block (`self.store.warn(...)` for every `flow.notify` even with `dry=True`); `df_llm_helper/caravan.py` `step` (`self.store.warn(... "caravan:review" ...)` and in `_release_stuck`, no `dry` guard)
- **Reported:** 2026-10-02, commit `6dedd96`
- **Environment:** Windows 11 Pro, Python 3.14.3, reproduced in the isolated mock state (`runtime/mock/state.db`); game running (DF 53.16 + DFHack, paused), fort date 27. Granite, Jahr 118. Live commands were only run with `--dry-run` against the iso/live config; I did not look for the warning rows in the live DB.

## Command / steps
```
cd "<project folder>"
bash Bugs/evidence/BUG-203/repro.sh        # or the commands below
python -m df_llm_helper --mock fixtures/run5 siege --dry-run
python -m df_llm_helper --mock fixtures/run5 mood reserve --dry-run
python -m df_llm_helper --replay-file Bugs/evidence/BUG-203/car_replay_low.jsonl caravan --dry-run --loop --interval 0
python Bugs/evidence/BUG-203/warnings_query.py runtime/mock/state.db siege mood caravan
```

## Expected
`--dry-run` ("show only", MANUAL 9.1, 9.3, INTEGRATION section 3) changes nothing: no warning rows, no kv, no flags.

## Actual
Rows with `shown=0` (they are printed by the next `check`/`digest`):
```
(2, 1790935282.5, 'siege',   'siege:pilot_siege status not readabl', 'crit', 'pilot_siege status not readable - run the siege by hand', 0)
(4, 1790935285.2, 'mood',    'mood:reserve', 'warn', 'Mood reserve missing: bone 1/5, leather 2/3, metal 0/3, rough gems 0/4, wood 0/10', 0)
(12,1790936125.5, 'caravan', 'caravan:review', 'warn', 'Trade waits for the orchestrator: Dry run not readable', 0)
```
(each one written by a command run with `--dry-run`; the ts changes with every dry run, i.e. the dry run also refreshes an existing row). `mood reserve --dry-run` is the clearest case: the flag is accepted by argparse but ignored.

## Evidence
`Bugs/evidence/BUG-203/` (`repro.sh`, replay files, `warnings_after_dry_runs.txt`, outputs).

## Analysis (reporter's hypothesis)
Each of the three modules guards its *game* commands with `dry`, but the `store.warn(...)` calls were added without the guard. `cmd_mood` never passes `dry` to `reserve()`.

## Suggested fix (optional)
Pass `dry` to `MoodManager.reserve`, `SiegeRunner.run` (`finally`) and `CaravanPilot.step/_release_stuck` and skip `store.warn`/`store.set`. A test per command: run with `--dry-run`, assert `store.take_warnings() == []`.

## Info needed
Please check the other `--dry-run` commands of the repo for the same pattern (`workload`, `care`, `water watch`, `tools`, `remote` looked clean when reading the code: their `store.warn`/`store.set` calls are inside `if not dry`; not verified row by row in the DB).

## Fix
`mood reserve --dry-run` passes `dry` (`MoodManager.reserve(dry=)`), `SiegeRunner.run` writes no warnings in a dry run, `CaravanPilot` writes `caravan:review`/`caravan:stuck` warnings only in a real run. Other `--dry-run` commands checked: workload/care/water/tools/remote/bottleneck/forecast/reboot already guard their writes. Generic part (mock/replay state isolation): BUG-104. Test: `test_bug203_*`.
