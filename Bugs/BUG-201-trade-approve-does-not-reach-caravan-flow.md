# BUG-201: `trade approve` has no effect on `caravan` (two separate state machines); `trade status` shows IDLE while `caravan` waits in REVIEW; `trade step` in REVIEW shows nothing to judge

- **Status:** fixed in ab33904
- **Severity:** S2 (documented manual approval path does not work; the orchestrator is told to run a command that changes nothing)
- **Area:** `df_llm_helper/cli.py` `cmd_trade` (kv `trade.flow`) vs. `df_llm_helper/caravan.py` (kv `caravan.state` -> `["flow"]`); docs `docs/MANUAL.md` 9.2 and section 2 table ("trade approve after the dry run")
- **Reported:** 2026-10-02, commit `6dedd96`
- **Environment:** Windows 11 Pro, Python 3.14.3, replay of real recorded answers (`fixtures/run5_live`). Game paused, fort date 27. Granite, Jahr 118 (no caravan present live).

## Command / steps
```
cd "<project folder>"
R="--replay-file Bugs/evidence/BUG-201/car_replay_low.jsonl"     # as car_replay.jsonl but select --dry returns ratio_x100 = 120
python -m df_llm_helper $R caravan reset
python -m df_llm_helper $R caravan --loop --interval 0     # starts the trade, stops in REVIEW
python -m df_llm_helper $R caravan --loop --interval 0     # evaluates the dry run: "NOT approved: Ratio 1.20 < 2.0"
python -m df_llm_helper $R trade approve
python -m df_llm_helper $R caravan --loop --interval 0     # still "NOT approved", nothing is bought
python -m df_llm_helper $R trade status                    # "State IDLE" although caravan is in REVIEW
```
Second scenario (`car_replay.jsonl`, normal ratio): `trade reset`, then `trade step` x7 -> REVIEW. `trade step` prints only `State now: REVIEW`.

## Expected
- MANUAL 9.2: "Otherwise trading waits; warning ... -> `trade approve` by hand". After `trade approve` the caravan autopilot (same trade) must move from REVIEW to the live selection.
- `trade status` and `caravan status` must show the same trade.
- In REVIEW the orchestrator needs the data to decide (goods, ratio) and the next command.

## Actual
```
$ ... caravan --loop --interval 0      (2nd call)
Caravan: REVIEW (trade)
Must-have goods in offer: wood 62, food 155
NOT approved: Ratio 1.20 < 2.0
$ ... trade approve
Live selection approved (state IDLE)
$ ... caravan --loop --interval 0
Caravan: REVIEW (trade)
Must-have goods in offer: wood 62, food 155
NOT approved: Ratio 1.20 < 2.0
NOT approved: Ratio 1.20 < 2.0
$ ... trade status
State IDLE; approved: False; last steps:
$ ... trade step      (REVIEW, normal ratio replay)
State now: REVIEW
```
(`NOT approved` lines pile up with every call.)

## Evidence
`Bugs/evidence/BUG-201/` (both replay files, outputs `r_low_*.out`, `r_trade_status5.out`, `r_ts1.out`).

## Analysis (reporter's hypothesis)
`cmd_trade` persists `TradeFlow` in kv `trade.flow`; `CaravanPilot` persists its own `TradeFlow` inside kv `caravan.state`. `trade approve` calls `flow.approve()` on `trade.flow` only; `CaravanPilot.step` recomputes `dry_ok(...)` every call and never reads `trade.flow` or an approval kv. Additionally `cmd_trade approve` sets `approved=True` on an `IDLE` flow without complaint ("state IDLE"), so a later trade would skip its review (REVIEW -> SELECT_LIVE immediately).

## Suggested fix (optional)
One persistent flow for both commands (or `trade approve` writes `caravan.state.flow.approved`, and `caravan` honours it); refuse `trade approve` unless the flow state is REVIEW; print in REVIEW the dry-run summary (goods, value, ratio) and the exact next command (`python -m df_llm_helper trade approve` / `trade reset`).

## Info needed
Which of the two commands is the intended primary interface during a real trade (INTEGRATION section 8 uses `trade step`, MANUAL 9.2 uses `caravan --loop`)? The cloud session should decide and make the other one a thin alias. Gordon: with the next real caravan, please run `trade status` and `caravan status` side by side once and attach both outputs.

## Fix
Decision: `caravan` is the primary interface (MANUAL 9.2); `trade approve` now approves the trade that waits in REVIEW in the caravan autopilot (kv `caravan.state`) and/or the manual automaton (kv `trade.flow`) via `caravan.approve_review`, and is refused (rc 2) when nothing waits in REVIEW. `trade status` adds a `Caravan autopilot: <state>` line; REVIEW lines no longer pile up and name the next command; `trade step` in REVIEW prints how to judge and approve. Test: `test_bug201_*` (replay `fixtures/bugs/BUG-201/car_replay_low.jsonl`). Live check for Gordon (next caravan): `trade status` and `caravan status` side by side.
