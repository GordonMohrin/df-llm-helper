# BUG-202: `trade step` never leaves DONE/ABORT/FAILED: the next caravan is silently ignored, and the old `approved: True` stays (live state.db right now)

- **Status:** fixed in ab33904
- **Severity:** S2 (next caravan is not traded; no message says why; a stale approval is stored)
- **Area:** `df_llm_helper/trade_flow.py` `TradeFlow.step` (terminal states return `[]`), `df_llm_helper/cli.py` `cmd_trade` (no auto-reset), `docs/MANUAL.md` section 2 ("call trade step repeatedly")
- **Reported:** 2026-10-02, commit `6dedd96`
- **Environment:** Windows 11 Pro, Python 3.14.3, game running (DF 53.16 + DFHack, paused), fort date 27. Granite, Jahr 118. Live state.db of the repo (`data/state.db`).

## Command / steps
Live (read only, no game call besides `claude/handel status` / `claude/advance clock`):
```
cd "<project folder>"
python -m df_llm_helper trade status
python -m df_llm_helper trade step --dry-run
```
Replay reproduction with a caravan at the depot (state DONE from an earlier trade):
```
R="--replay-file Bugs/evidence/BUG-201/car_replay.jsonl"
python -m df_llm_helper $R trade reset
python -m df_llm_helper $R trade approve ; (7x) python -m df_llm_helper $R trade step      # -> DONE
python -m df_llm_helper $R trade step                                                     # caravan "AtDepot" again
```

## Expected
After a finished/aborted trade the automaton returns to IDLE as soon as the caravan has gone (like `CaravanPilot` does: `not cars` -> `CaravanState()`); `approved` is cleared for the next trade. If it refuses to start, it says so ("state DONE: run `trade reset`").

## Actual
Live:
```
$ python -m df_llm_helper trade status
State DONE; approved: True; last steps: CONFIRM -> FINISH | FINISH -> RELEASE | RELEASE -> RESUME | RESUME -> DONE
$ python -m df_llm_helper trade step --dry-run
State now: DONE
```
(raw game answers: `Bugs/evidence/BUG-202/l_trade_step_dry.jsonl`; no caravan on the map.) Replay with a caravan at the depot:
```
$ ... trade step
State now: DONE        (7th, 8th, ... call: no command, no hint)
```

## Evidence
`Bugs/evidence/BUG-202/` (live `trade status`, replay outputs `r_tz8.out`, `r_tst.out`, `r_tst2.out`).

## Analysis (reporter's hypothesis)
`TradeFlow.step` handles `IDLE` (start on AtDepot) but for `DONE`, `ABORT`, `FAILED` falls to `return []`. Nothing resets the persisted flow (kv `trade.flow`) except the manual `trade reset`, which the manual does not mention in the normal cycle. `approved=True` also survives, so the first review of the *next* trade would be skipped if someone resets only the state.

## Suggested fix (optional)
In `cmd_trade` step: if the flow is terminal and no caravan is `AtDepot` (or the caravan id changed) -> `TradeFlow()`; if terminal and a caravan is at the depot, print `State DONE (previous trade) - run 'trade reset' to trade with this caravan` (or reset automatically). Reset `approved` whenever a trade reaches DONE/ABORT.

## Info needed
Gordon / orchestrator: is the DONE+approved state in the live `data/state.db` from the Run 5 trades? It is harmless today but will block the next caravan; `python -m df_llm_helper trade reset` clears it (I did not run it - write action on the live store).

## Fix
`TradeFlow.step` renews a terminal automaton (DONE/ABORT/FAILED) as soon as no caravan is on the map; `approved` is cleared whenever a trade ends; `trade step` in a terminal state with a caravan still present says `run trade reset`. The live DONE+approved row in `data/state.db` is renewed by the next `trade step` after the caravan left (or `trade reset`). Test: `test_bug202_*`.
