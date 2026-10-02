# BUG-121: `metrics` writes one row per digest call (identical rows seconds apart), four of the 18 columns are never filled, `budget` "Bytes in" is the command length

- **Status:** fixed in 3fff919
- **Severity:** S3
- **Area:** `df_llm_helper/metrics.py:28-31,86-99` (`KPI_COLUMNS`, `export_csv`), `df_llm_helper/pilot.py:124-126` (`record_kpis` on every orchestrator digest), `df_llm_helper/cli.py:53-55` (`_usage`)
- **Reported:** 2026-10-02, commit `50cee52` (code identical to `6dedd96`)
- **Environment:** Windows 11 Pro, Python 3.14.3; mock + temp (repro), live `data/state.db` (`live_metrics_head.txt`), game paused, `27. Granite, Jahr 118`

## Command / steps
```
cd "<project folder>"
python Bugs/evidence/BUG-121/repro.py
python -m df_llm_helper metrics | head -12          # live
python -m df_llm_helper budget
```

## Expected
`metrics`: "KPI time series in the format of metrics.csv" (OVERVIEW) - one row per measurement time, all columns of `metrics.csv` filled where the data exists. `budget`: bytes in = what the call received.

## Actual
1. **Duplicate rows:** every `digest`/`check`/`cycle` call (also `--dry-run`) appends a KPI row, so 3 digests within 3 seconds give 3 identical rows (mock: 12:26:09/12:26:10/12:26:10/12:26:10; live: 11:53:41, :44, :47 and 11:59:01, :17 are the same measurement). A "time series" with seconds resolution and no change is noise for `forecast backtest` / `journal metrics` and grows `state.db`.
2. **Columns never filled:** `tierkadaver`, `sawdeadbody`, `death`, `ghosthaunt` are empty in every row. The Lua-written `metrics.csv` (`fixtures/run5_live/metrics_run5.csv`, 83 rows) fills all four (e.g. `...;102;0;12;201;2;6762;43;1;0`; written by `lua/claude/report.lua:166-192`), and the data is in `claude/report`:
   live `kadaver_tiere_in_festung: 343`, `negative_gedanken_top: ["SawDeadBody=8087", "NeedsUnfulfilled=656", "Death=31", "Thirsty=5"]`. So a CSV continued by the helper has holes exactly in the ghost/miasma KPIs.
3. **Mock rows in the live series** (BUG-104): the first and fourth live rows are `12. Hematite, Jahr 102 ... 24` (fixture), not the real fort.
4. **`budget`:** `Bytes in/out` - "in" is `sum(len(c) for c in pilot.client.calls)` = length of the *commands sent to DF* (e.g. 616 per digest), not what DF returned; header is misleading. (Token numbers are `len(text)//3` of the printed output - fine.)

## Evidence
`Bugs/evidence/BUG-121/repro.py`, `output.txt`, `live_metrics_head.txt`.

## Analysis (reporter's hypothesis)
`record_kpis` has no minimum interval. Add `min_interval_s` (e.g. 60) or "only when a value changed"; map exactly like `lua/claude/report.lua:176-191` does: `tierkadaver <- kadaver_tiere_in_festung`, `sawdeadbody/death/ghosthaunt <- neg('SawDeadBody'|'Death'|'GhostHaunt')` from `negative_gedanken_top` (0 if absent); rename the budget column to `Sent/Printed`.
Note: `claude/report` itself appends a row to `<home>/metrics.csv` on every call (report.lua:166-192), and the helper calls it on every cycle, so that file has the same duplicate-row property.

## Suggested fix (optional)
As above.

## Info needed
None (the mapping is in `lua/claude/report.lua`, see Analysis).

## Fix
`record_kpis` adds no row when the last row is < 60 s old and has the same values; `tierkadaver` (kadaver_tiere_in_festung) and `sawdeadbody/death/ghosthaunt` (negative_gedanken_top, 0 if absent) are filled like `lua/claude/report.lua`; the budget header is `Bytes sent/printed`. Mock rows in the live DB: see BUG-104. Tests: `test_bug121_*`, adapted `tests/test_metrics_cli2.py`.
