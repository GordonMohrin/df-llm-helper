# BUG-200: `caravan` after a finished trade is not terminal: every further call repeats `claude/advance run`, deletes `pause.hold`/`caravan.flag` again and duplicates "Trade completed"

- **Status:** fixed in ab33904
- **Severity:** S2 (a repeated call un-pauses the game and deletes a `pause.hold` that may belong to something else, e.g. an alarm hold)
- **Area:** `df_llm_helper/caravan.py` (`CaravanPilot.step`, final `if flow.state == "DONE": self._resume(...)`), `df_llm_helper/cli.py` (`cmd_caravan`)
- **Reported:** 2026-10-02, commit `6dedd96`
- **Environment:** Windows 11 Pro, Python 3.14.3, replay of recorded real answers (no game involved in the reproduction). Game: running (DF 53.16 + DFHack, paused), fort date 27. Granite, Jahr 118 (no caravan on the map at the time, so the live run only showed `Caravan: IDLE`).

## Command / steps
```
cd "<project folder>"
python -m df_llm_helper --replay-file Bugs/evidence/BUG-200/car_replay.jsonl caravan reset
python -m df_llm_helper --replay-file Bugs/evidence/BUG-200/car_replay.jsonl caravan --loop --interval 0 --max-steps 12   # call 1: starts the trade, stops in REVIEW
python -m df_llm_helper --replay-file Bugs/evidence/BUG-200/car_replay.jsonl caravan --loop --interval 0                  # call 2: approves + buys + DONE
python -m df_llm_helper --replay-file Bugs/evidence/BUG-200/car_replay.jsonl caravan --loop --interval 0                  # call 3: trade is already DONE
```
`car_replay.jsonl` = `fixtures/run5_live/handel_status_atdepot_open.json`, `handel_list_theirs.json`, `handel_select_dry.json`, `fixtures/run5/status.txt` and `{"paused": true}` as the answers to `claude/handel status`, `claude/handel list 0`, `claude/handel select --dry`, `claude/status`, `claude/advance clock` (the caravan stays "AtDepot" in the replay, as it does in the game for several days after the last good is bought).

## Expected
Once the state is `DONE` the autopilot has nothing more to do for this caravan: no commands, no flag deletions, report shown once.

## Actual
Call 2 sends `claude/advance run` **twice** (once from the trade automaton RESUME step, once from `_resume`). Call 3 (state DONE, caravan still on the map) sends `claude/advance run` again, again deletes `caravan.flag` and `pause.hold`, and appends a second `Trade completed` line:
```
$ ... caravan --loop --interval 0          (call 2)
  ok claude/handel select --live
  ok claude/handel confirm --live
  ok claude/handel accept --live
  ok claude/handel finish --live
  ok claude/handel release --live
  ok claude/advance run
  ok claude/advance run
Caravan: DONE (trade)
Must-have goods in offer: wood 62, food 155
approved: Must-have goods: food; ratio 2.43
Trade completed

$ ... caravan --loop --interval 0          (call 3)
  ok claude/advance run
Caravan: DONE (trade)
Must-have goods in offer: wood 62, food 155
approved: Must-have goods: food; ratio 2.43
Trade completed
Trade completed
```

## Evidence
`Bugs/evidence/BUG-200/` (`car_replay.jsonl`, outputs of the three calls).

## Analysis (reporter's hypothesis)
`CaravanPilot.step()` returns early for DONE only when `not cars`. While the caravan is still listed (it walks away for days) the code falls through to `flow.step(obs)` (no-op in DONE) and then runs the unconditional block `if flow.state == "DONE": self._resume(st, dry, log, "Trade completed")` on **every** call. `_resume` deletes the flags and runs `claude/advance run`. The first `advance run` is already sent by `TradeFlow` (RELEASE -> RESUME), so the first completion sends it twice.

## Suggested fix (optional)
Run `_resume` only on the transition into DONE (compare the state before/after `flow.step`), and return early with an empty log when the persisted flow state is already DONE. Do not append `Trade completed` twice.

## Info needed
None for the fix. Live check for Gordon with a real caravan (only possible with time running): after the trade finished, call `python -m df_llm_helper caravan --dry-run` twice and check that no `[dry] claude/advance run` is listed.

## Fix
`CaravanPilot.step` returns early (no command, no flag deletion) while the persisted flow is DONE/ABORT/FAILED and the caravan is still listed; `_resume` runs only on the transition into DONE and does not send a second `advance run` (the automaton already sent it in RELEASE -> RESUME); report lines are not duplicated. Test: `tests/test_bugs_autopilots.py::test_bug200_*` (replay `fixtures/bugs/BUG-200/car_replay.jsonl`).
