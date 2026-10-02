# BUG-222: the open trade window holds the game paused while the trade waits for approval

- **Status:** fixed in 4012e2e
- **Severity:** S2 (the fort stands still for up to 15 min of REVIEW)
- **Area:** `df_llm_helper/trade_flow.py` (state REVIEW), `caravan.py` (`approve_review`), `cli.py` (`caravan --loop`)
- **Reported:** 2026-10-02 (retest of 8e67f05, live trade), commit `61e5c13`
- **Environment:** Windows 11, game running (DF 53.16 + DFHack)

## Actual
Without an immediate approval the automaton stayed in REVIEW (timeout 900 s) with the trade window open. DF pauses
while the trade screen is open, so the whole fort stood still until the approval or the timeout.

## Fix
- New state WAIT. When REVIEW has no approval, the automaton sends `claude/handel finish --live` (closes the window)
  and `claude/advance run`, and the game runs on.
- `trade approve` is accepted in REVIEW and in WAIT.
- On approval, WAIT -> OPEN (`claude/advance 0`, `claude/handel open --live`) -> SELECT_DRY (fresh dry check) ->
  REVIEW (already approved) -> SELECT_LIVE.
- The REVIEW timeout dropped to 120 s, because the window is only open for the automatic check now.
- A caravan that leaves during WAIT aborts as before (window already closed).
- `caravan --loop` stops in WAIT, and in REVIEW only without an approval.
- Tests: `tests/test_m3.py::test_trade_waits_for_approval`,
  `tests/test_bugs_autopilots.py::test_bug201_trade_approve_reaches_caravan`.

## Info needed
Live check: on a caravan without automatic approval the game must keep running (`trade status`: `REVIEW -> WAIT`).
