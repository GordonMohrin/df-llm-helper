# BUG-213: `forecast backtest` default `--file` points outside the repo (traceback); `--horizon 0/-3` and garbage files are accepted silently; live `forecast` shows "Food 267±6409 days" from a series with a 5,000-day-old point

- **Status:** verified fixed (retest 2026-10-02, 8e67f05)
- **Severity:** S3 (S2 for the stale-series part if the line is used for decisions; it carries `[confidence 0.3]`)
- **Area:** `df_llm_helper/cli.py:1056` (`--file` default `Path(__file__).resolve().parents[2] / "metrics.csv"`), `cmd_forecast` (`series_from_metrics`), `df_llm_helper/forecast.py` (series window / band)
- **Reported:** 2026-10-02, commit `6dedd96`
- **Environment:** Windows 11 Pro, Python 3.14.3, mock and live (state.db read for `forecast`), game paused, fort date 27. Granite, Jahr 118

## Command / steps
```
cd "<project folder>"
python -m df_llm_helper forecast backtest                       # MANUAL 9.5: "forecast backtest [--file metrics.csv --horizon 3]"
python -m df_llm_helper forecast backtest --file fixtures/run5_live/metrics_run5.csv --horizon 0
python -m df_llm_helper forecast backtest --file fixtures/run5_live/metrics_run5.csv --horizon -3
python -m df_llm_helper forecast backtest --file fixtures/run5_live/metrics_run5.csv --horizon 9999
python -m df_llm_helper forecast backtest --file fixtures/run5/status.txt            # not a metrics file
python -m df_llm_helper forecast --dry-run                      # live
```

## Expected
Default file inside the project (e.g. `runtime/metrics.csv`, the output of `journal metrics`) and a one-line error when it is missing ("no metrics file: run `python -m df_llm_helper journal metrics --out runtime/metrics.csv` first"); `--horizon` >= 1; a file without the metric header is refused. The live forecast ignores or flags points far outside the window.

## Actual
```
$ python -m df_llm_helper forecast backtest
FileNotFoundError: [Errno 2] No such file or directory: 'C:\\Users\\admin\\claude gordons projects\\metrics.csv'     (traceback, rc 1)
--horizon 0   -> "food: 76 predictions, mean error 0.222" (different from horizon 3: 0.326)     --horizon -3 -> identical to 0
--horizon 9999 and --file status.txt -> "food: 0 predictions, mean error None, median None" (rc 0, no explanation)
$ python -m df_llm_helper forecast --dry-run          (live)
Forecast: Food 267±6409 days (-1.3/day), Drink 151±1018 days (-3.4/day) [confidence 0.3]
```
Live `claude/status` says `food_days 85`, `drink_days 49` for the same moment: the forecast is 3x more optimistic. The stored series (kv `forecast.series`, [day, pop, food, drink]) is `[[34367.2, 24, 97, 109], [39281.5, 176, 384, 653], [39282.2, 176, 382, 648], [39674.6, 174, 350, 512]]`: the first point is ~5,000 game days (about 14 years) old with population 24, the last two are 392 days apart.

## Evidence
`Bugs/evidence/BUG-213/` (tracebacks and outputs); series values quoted from the live `data/state.db` (read only).

## Analysis (reporter's hypothesis)
The default path was written for the private project layout (`../metrics.csv`). The forecaster keeps up to 50 points regardless of their age (`min_dt_days` only guards the lower bound), so rates are computed across epochs; a band of +-6409 days comes from the slowest/fastest "measured rate" over those gaps.

## Suggested fix (optional)
Drop points older than e.g. 30 game days (or reset the series when the gap > N days or population differs by > 2x); suppress the `±` band when `confidence < 0.5`; catch `FileNotFoundError` in `cmd_forecast` and validate `--horizon >= 1` and the CSV header.

## Info needed
None. (Live check for Gordon once time runs: after ~5 `check` cycles the line should converge towards `claude/status` food/drink days, or say `n/a`.)

## Fix
Default `--file` = `runtime/metrics.csv` (else `../metrics.csv`), one-line errors for a missing file (`journal metrics --out runtime/metrics.csv` hint) or a file without the metrics header, `--horizon` >= 1, `0 predictions` explained. Forecaster drops points older than `max_age_days` (60 game days) and shows no +- band below confidence 0.5 (the live series reduces to 1 point -> `Food ?` until new points arrive). Test: `test_bug213_*`.
