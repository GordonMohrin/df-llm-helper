# BUG-216: `reboot --dry-run` prints "Restart: 10 services started (...)" although nothing was started

- **Status:** open
- **Severity:** S3 (misleading wording; an LLM reading the first line believes the services run)
- **Area:** `df_llm_helper/reboot.py` `Reboot.run` (`out.append(f"Restart: {len(started)} services started ...")`, `do()` returns True in dry mode)
- **Reported:** 2026-10-02, commit `6dedd96`
- **Environment:** Windows 11 Pro, Python 3.14.3, game running (DF 53.16 + DFHack, paused), fort date 27. Granite, Jahr 118. Only `--dry-run` was run live.

## Command / steps
```
cd "<project folder>"
python -m df_llm_helper reboot --dry-run -v
python -m df_llm_helper reboot --dry-run
```

## Expected
`Restart (dry run): would start 10 services (...)`.

## Actual
```
Restart: 10 services started (ueberwacher, arbeit, orders, auslastung, trinken, essen, material, gesund, migranten, raster)
schau off: HUD ticker, not active as a permanent job live on 01.10.; ...
kohle off: Permanent job deliberately off ...
[dry] claude/advance 0
[dry] claude/ueberwacher start
...
[dry] claude/advance run
```
Also: the exit code in dry mode is 0 even if services would fail; and the `[dry] claude/ueberwacher start` lines appear without `-v` while `[dry] claude/advance ...` are hidden (inconsistent).

Plausibility (live): the repeat-util query reports claude-watchdog, -watchdog-alert, -milguard, -tempo running and ueberwacher, arbeit, orders, auslastung, trinken, essen, material, gesund, migranten, raster not running; this matches `brief infra` ("Stopped services [arbeit, auslastung, essen, gesund, material, migranten...]") and the keys equal the `KEY` constants in `lua/claude/*.lua` (checked by grep). So the plan itself is correct: **ten permanent services are currently not running in the live game.**

## Evidence
`Bugs/evidence/BUG-216/` (raw answers `l_rb.jsonl`, outputs).

## Analysis (reporter's hypothesis)
Same text path for dry and real run.

## Suggested fix (optional)
Prefix `Restart (dry run): would start N services`.

## Info needed
Gordon: is it intended that arbeit/orders/auslastung/trinken/essen/material/gesund/migranten/raster are off right now (68 of 119 adults idle)? If not, a real `python -m df_llm_helper reboot` (not run by me) restarts them.
