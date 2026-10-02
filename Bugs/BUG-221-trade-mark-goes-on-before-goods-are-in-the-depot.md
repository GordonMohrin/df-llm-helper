# BUG-221: trade automaton leaves MARK before the marked goods are in the depot

- **Status:** fixed in COMMIT
- **Severity:** S2 (the trade window opens with the goods still on their way; the review judges an incomplete offer)
- **Area:** `df_llm_helper/trade_flow.py` (`TradeFlow.step`, state MARK), `caravan.py`
- **Reported:** 2026-10-02 (retest of 8e67f05, live trade), commit `61e5c13`
- **Environment:** Windows 11, game running (DF 53.16 + DFHack)

## Actual
MARK went to OPEN on the next step without any condition, so OPEN -> SELECT_DRY -> REVIEW ran while the depot still
had 50 `BringItemToDepot` jobs (see the recorded `claude/handel status` in `fixtures/bugs/BUG-200/car_replay.jsonl`).
The game also stayed paused from PAUSE on, so neither the broker nor the haulers could move.

## Fix
- `TradeObs.haul_pending` = number of `BringItemToDepot` jobs of the first depot (`depots[0].jobs` of
  `claude/handel status`; `None` when unknown).
- SAVE -> BROKER also sends `claude/advance run`: the broker walks and the haulers carry while the game runs.
- MARK waits until `haul_pending == 0`. After `MARK_MAX_S` (600 s) it opens anyway with what is in the depot. That is
  logged with the number of open jobs and is no abort. MARK has no abort timeout any more.
- MARK -> OPEN sends `claude/advance 0` before `claude/handel open --live`.
- Tests: `tests/test_m3.py::test_trade_mark_waits_for_the_haulers`, `test_trade_obs_counts_haul_jobs`, the happy path
  with the new command list. The BUG-200/201 replay tests use a copy in which the goods have arrived.

## Info needed
Live check: the next caravan should show `MARK -> OPEN (goods in the depot)` in `trade status`.
