# BUG-225: `trade step` ends in ABORT "window not open" right after the MARK->OPEN timeout while an alarm / a paused game is active

- **Status:** open
- **Severity:** S2 (the whole trade is lost although the caravan is still at the depot; the flow does not wait for the danger to pass)
- **Area:** `df_llm_helper/trade_flow.py` (`TradeFlow.step`, states MARK -> OPEN, lines ~139-158), `caravan.py` (`claude/handel open --live`)
- **Reported:** 2026-10-02 ~18:26 (real time, live trade), commit `22b9b03`
- **Environment:** Windows 11, Python 3.14, game running (DF 53.16 + DFHack), human caravan at the depot; the game was paused by `tools/pause.hold` (see BUG-224) and a berserker was attacking in the fort

## Related
- BUG-221 (MARK left too early): **fixed in 4012e2e**, confirmed live (MARK waited, after 600 s `MARK -> OPEN`). Only a reference here, no new work for BUG-221.
- BUG-223 (PAUSE writes no `pause.hold`), BUG-224 (stale `pause.hold`): the paused state in this report came from such a hold.

## Command / steps
```
cd <project folder>
python -m df_llm_helper trade step        # repeated every ~8 s by the orchestrator
```
1. Caravan `AtDepot`, trade flow runs PAUSE -> SAVE -> BROKER -> MARK; goods still being hauled.
2. After `MARK_MAX_S = 600` s the flow goes `MARK -> OPEN` (BUG-221 behaviour, as designed).
3. In the same minutes a citizen went berserk / attacked; the wake alarm wrote `pause.hold`, the game stood paused.
4. `trade step` in OPEN: `claude/handel open --live` is tried, `trade_open` stays false.

## Expected
The flow notices that the game is in a danger state (`alert.flag` / `pause.hold` with reason `alarm`/`gefahr`, or a focus other than `dwarfmode/Default`) and **waits** (state WAIT or a "blocked by danger" sub state with its own timeout), then retries OPEN once the danger is over. ABORT is only for a leaving caravan or a real failure, and the abort must leave the caravan tradable (the goods stay marked).

## Actual
Observed output of the orchestrator (verbatim wording from the session notes, no recording of the raw JSON exists):
```
MARK -> OPEN (… haul jobs still open after 600 s - opening with the goods in the depot)
OPEN  ok
ABORT (window not open)
```
i.e. after the timeout OPEN reported ok, the next step(s) did not see an open trade window and, after the two allowed retries (`self._retry("open", 2)`), the flow went to ABORT with `window not open`. The caravan was still at the depot; the player had to restart the trade.

## Evidence
none recorded (the game answers of that minute were not captured). Needed from the player: see "Info needed".

## Analysis (reporter's hypothesis)
`trade_flow.py` state OPEN: `if o.trade_open and focus==FOCUS_TRADE and stable_s>=2 -> SELECT_DRY`, `elif o.trade_open: wait`, `else: retry open max 2, then _abort(now, o, "window not open")`. Only two blind retries, no check **why** the window did not open and no look at `o.paused` / `pause.hold` / `alert.flag` / focus. With an open Squads window (BUG-224 addendum) or a dwarfmode popup the trade window cannot be opened by `claude/handel open --live`; the second retry runs within seconds, so a short blocking situation is enough to abort. Probably also the abort path (`_abort_cmds`) does not restore the marked state, so the next run starts from MARK again after another 600 s.

## Suggested fix
1. Extend `TradeObs` by `danger` (alert.flag/pause.hold reason) and `focus`; in OPEN: if `danger` or the focus is not `dwarfmode/Default`, stay in OPEN (or go WAIT) with a separate timeout (e.g. 300 s) and a clear status line `blocked: alarm active / focus=<x>`.
2. More retries with a delay (e.g. 5 x 8 s) before `window not open`; log the raw answer of `claude/handel open --live` in the abort reason.
3. On ABORT because of `window not open` do not release the marked goods; allow `trade step` from ABORT/IDLE to re-enter at OPEN if the caravan is still `AtDepot`.

## Acceptance (fixture based)
Replay with `fixtures/bugs/BUG-200/car_replay.jsonl`-style rows: caravan `AtDepot`, `trade_open=false` for 10 consecutive observations with `paused=true` and `alert.flag` present -> the flow stays in OPEN/WAIT with the message "blocked by danger", no ABORT; when the flag disappears and `trade_open` turns true the flow continues with SELECT_DRY.

## Info needed
Player/orchestrator: the next time OPEN fails, save the raw output of `claude/handel open --live` and `claude/handel status` plus the current focus string (`df.global.game.main_interface` / `dfhack.gui.getCurFocus()`) under `Bugs/evidence/BUG-225/`.
