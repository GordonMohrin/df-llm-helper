# BUG-103: `--config <file that does not exist>` is silently ignored and the defaults (incl. the live `data/state.db`) are used

- **Status:** open
- **Severity:** S2
- **Area:** `df_llm_helper/config.py:171-183` (`load_config`: `if p.exists(): ...`), `df_llm_helper/cli.py` (`load_config(args.config)` everywhere)
- **Reported:** 2026-10-02, commit `50cee52` (code identical to `6dedd96`)
- **Environment:** Windows 11 Pro, Python 3.14.3, game running (DF 53.16 + DFHack, **paused**), fort "Windrings", date `27. Granite, Jahr 118`

## Command / steps
```
cd "<project folder>"
python Bugs/evidence/BUG-103/repro.py                     # read-only, only loads configurations
python -m df_llm_helper --config tpyo-config.yaml digest  # do NOT run against a live installation (writes data/state.db)
```

## Expected
`Error: config file not found: tpyo-config.yaml` (exit 2). Only the *implicit* default `config.yaml` may be optional.

## Actual
```
--config 'config.yaml'           exists=True  -> state_db=...\dfpilot-public\data\state.db  tools=...\dwarf-fortress\tools          dfhack_run=E:\Program Files (x86)\...\dfhack-run.exe
--config 'tpyo-config.yaml'      exists=False -> state_db=...\dfpilot-public\data\state.db  tools=...\dfpilot-public\runtime\tools  dfhack_run=C:\Program Files (x86)\...\dfhack-run.exe
```
No warning. The command then runs against the default `data/state.db` (the **live** database when the project folder is the live installation) with a different tools folder
and a different DFHack path. A typo in an agent's command line therefore writes into the live state.
**This happened to the tester**: a `wake` run with a not-yet-created config path reset the live `wake.state` (`events_n` 4322 -> 0); the next real `wake` printed ~100 old
events as new (`Bugs/evidence/BUG-103/what_happened_live.txt`). The tester did not repair the live database (not allowed); it self-healed after one run.

## Evidence
`Bugs/evidence/BUG-103/repro.py`, `output.txt`, `what_happened_live.txt`.

## Analysis (reporter's hypothesis)
`load_config(path)` treats "no such file" as "no overrides". That is right for the optional default `config.yaml` and for `scenario.run_scenario`, which deliberately passes a
non-existent `tmp/none.yaml`, but wrong for an explicit `--config`. Also see BUG-104 (explicit `--config` disables the mock isolation).

## Suggested fix (optional)
In `cli.main` (or `load_config(..., must_exist=True)` when `args.config` is set): `if args.config and not Path(args.config).is_file(): raise ValueError("config file not found: ...")`. Same for a directory (currently `PermissionError` traceback, see BUG-113).

## Info needed
None.
