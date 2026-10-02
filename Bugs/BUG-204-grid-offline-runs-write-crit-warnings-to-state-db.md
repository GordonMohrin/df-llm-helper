# BUG-204: offline `--grid` runs of `perimeter`, `reach`, `digcheck` write CRIT warnings and kv state into the configured (live) state.db

- **Status:** fixed in e47790f
- **Severity:** S2 (a documented offline fixture test raised a false critical alarm "forbidden access to the core" in the live store; it was displayed once - warning row 14 in the live `data/state.db`, now `shown=1`)
- **Area:** `df_llm_helper/features/perimeter.py` `Perimeter.evaluate` (`store.warn`, `store.set` guarded only by `dry`), `df_llm_helper/features/reach.py` (`reach.last`, `reach:unreachable` warning), `df_llm_helper/features/digcheck.py` (`digcheck.unreported`); docs `docs/manual-v3/01-perimeter.md`, `02-digcheck.md`, `11-reach.md` ("`--grid ...` offline on a grid fixture")
- **Reported:** 2026-10-02, commit `6dedd96`
- **Environment:** Windows 11 Pro, Python 3.14.3, game running (DF 53.16 + DFHack, paused), fort date 27. Granite, Jahr 118; live `config.yaml` (state_db = `data/state.db`)

## Command / steps
```
cd "<project folder>"
python -m df_llm_helper perimeter --grid fixtures/v3/grid/perimeter_j109_open.grid      # NO --mock, default config (I did this by mistake once)
python -m df_llm_helper perimeter status                                                # shows the fixture result as if it were the live state
```
Isolated reproduction (own state file, same code path): `Bugs/evidence/BUG-204/outputs.txt` + `state_after_grid_runs.txt` were produced with a config whose `paths.state_db` points to a temp file:
```
python -m df_llm_helper --config <cfg with temp state_db> reach --grid fixtures/v3/grid/reach_p1p2_built.grid
python -m df_llm_helper --config <cfg> digcheck 131 100 70 122 77 --grid fixtures/v3/grid/dig_north_opening.grid
python -m df_llm_helper --config <cfg> perimeter --grid fixtures/v3/grid/perimeter_j109_open.grid
```

## Expected
`--grid FILE` means "evaluate this fixture, do not touch the running fortress state": no warnings, no kv `perimeter.sig/last`, `reach.last`, no action-log rows (or an explicit `--store` opt-in).

## Actual
State file after the three offline runs:
```
warnings: (1,'reach','reach:unreachable','crit',0)  (2,'perimeter','perimeter:forbidden','crit',0)
kv: reach.last, reach.last_ts, digcheck.unreported, perimeter.sig, perimeter.last, perimeter.last_ts
```
In the live DB the same happened: row 14 `perimeter:forbidden` crit "WAKE perimeter: forbidden access to the core at (96,88,z132) ..." (fixture data), and `perimeter.last` showed "Accesses: 1 allowed, 0 forbidden ... through the traps" (the *sealed* fixture) until the next real scan. The overwritten `perimeter.sig` also distorts the next real WAKE line ("only on a change").

## Evidence
`Bugs/evidence/BUG-204/` (`outputs.txt`, `state_after_grid_runs.txt`, `live_state_db_rows_readonly.txt`, `g_p1_mock.out`). Note: the same pattern is visible in older live rows 9-13 (`mood:reserve` with mock numbers, `reach:unreachable Well`), i.e. other offline/mock tests leaked too.

## Analysis (reporter's hypothesis)
`--mock`/`--replay-file` isolate the state (`config.mock_overrides`), `--grid` does not. The features call `store.warn/set/log_action` unless `dry`.

## Suggested fix (optional)
Treat `--grid` like `--mock` in `cli.main` (use `mock_overrides()` when any feature has `--grid`), or force `dry=True` when `args.grid` is set. Add a test: run with `--grid` and assert the store is unchanged.

## Info needed
Gordon / orchestrator: warning row 14 (and kv `perimeter.sig/last`) in the live `data/state.db` are test artefacts of mine. I wanted to delete row 14 but the sandbox refused the DELETE (write action on the live store) and I left it. Please ignore it, or run one real `python -m df_llm_helper perimeter` to overwrite `perimeter.last/sig`. Only `perimeter` was affected in the live DB (reach/digcheck grid runs were done with `--mock`/temp state).

## Fix
`perimeter`, `reach` and `digcheck` with `--grid FILE` use a throw-away in-memory store: no warnings, kv or action rows in the configured state.db. Generic part (mock/replay isolation): BUG-104. Test: `test_bug204_grid_runs_do_not_touch_state`. The leaked live row 14 / `perimeter.sig/last` are overwritten by the next real `perimeter` scan.
