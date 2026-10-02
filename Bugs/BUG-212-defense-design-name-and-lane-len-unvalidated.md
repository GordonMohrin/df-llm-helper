# BUG-212: `defense design --name` is not validated (path traversal out of `--out`, spaces break the printed `quickfort run` commands); `--lane-len 0` is silently ignored, `--lane-len 9999` burns 17 s CPU

- **Status:** open
- **Severity:** S2 (write outside the target folder; generated build commands that quickfort cannot parse)
- **Area:** `df_llm_helper/features/defense.py` `_design` (`name = args.name or ...`, `od / f"{name}.csv"`, `if args.lane_len:`), `apply_commands`; `df_llm_helper/planners/defense.py` (lane search)
- **Reported:** 2026-10-02, commit `6dedd96`
- **Environment:** Windows 11 Pro, Python 3.14.3, `--mock` (design never contacts the game); game paused, fort date 27. Granite, Jahr 118. Never used `--apply`.

## Command / steps
```
cd "<project folder>"
mkdir -p /tmp/o/sub     # any folder
python -m df_llm_helper defense design --terrain fixtures/v3/defense/plateau_z133.txt --out /tmp/o/sub --name "../escape"
python -m df_llm_helper defense design --terrain fixtures/v3/defense/plateau_z133.txt --out "<dir with space>" --name "my def"
python -m df_llm_helper defense design --terrain fixtures/v3/defense/plateau_z133.txt --lane-len 0
python -m df_llm_helper defense design --terrain fixtures/v3/defense/plateau_z133.txt --lane-len 9999
```

## Expected
`--name` limited to `[A-Za-z0-9_-]+` (it becomes a quickfort blueprint name `claude/<name>.csv`); files stay inside `--out`; `--lane-len` must be a positive number within the terrain (refuse 0/negative with a usage message; fail fast when it cannot fit).

## Actual
```
Written: ...\out\sub\..\escape.csv (+ .txt sketch)       -> files land in the PARENT of --out (escape.csv, escape.txt)
Build later (explicit): quickfort run claude/../escape.csv -n /walls -c 98,93,133
Build later (explicit): quickfort run claude/my def.csv -n /walls -c 98,93,133        (unquoted space)
--lane-len 0    -> designs a 20-tile lane (value ignored)
--lane-len 9999 -> after 17.5 s: "Defense design FAILED: no lane of length 9999 fits (searched 300120 nodes)"
```
With `--apply --confirm` the same unvalidated name would also be copied to `defense.blueprint_dir/<name>.csv` and passed to `quickfort run claude/<name>.csv`.

## Evidence
`Bugs/evidence/BUG-212/` (`name_escape.txt`, `g_df5.out`, `g_df11.out`, `g_df12.out`).

## Analysis (reporter's hypothesis)
No validation of `name`; `if args.lane_len:` treats 0 as "not given".

## Suggested fix (optional)
`re.fullmatch(r"[A-Za-z0-9_-]{1,40}", name)` else exit 2; `type=positive int` for `--lane-len` with an upper bound (e.g. 60); search node cap.

## Info needed
None.
