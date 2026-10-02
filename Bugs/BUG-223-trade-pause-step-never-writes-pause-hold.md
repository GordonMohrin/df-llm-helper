# BUG-223: `trade step` PAUSE never holds the game (no `pause.hold` written): "pause has no effect" with a pause guard running

- **Status:** open
- **Severity:** S2 (the whole flow stops at the first step; the caravan time (~3700 ticks) runs out while the orchestrator retries)
- **Area:** `df_llm_helper/caravan.py` / trade flow step PAUSE (new automaton, ae17fff); interaction with `claude/tempo` (timestream)
- **Reported:** 2026-10-02, commit `ae17fff` (plus local `4ac3f16`)
- **Environment:** Windows 11, Python 3.14, game running (DF 53.16 + DFHack), fort date 8./15. Malachite, year 121, human caravan Muboomon `AtDepot`, no `pause.hold`; reproduced with timestream ON and OFF.

## Command / steps
```
python -m df_llm_helper trade reset
python -m df_llm_helper trade step      # repeat every 8 s
python -m df_llm_helper trade status
```
Observed twice in a row (reset in between).

## Expected
`IDLE -> PAUSE (caravan at depot) -> SAVE -> BROKER -> MARK ...` as with the previous caravan (Catten, same day, timestream OFF because of a strange mood).

## Actual
```
State now: PAUSE        (x4 over ~30 s, game keeps running)
State FAILED (pause has no effect); approved: False; last steps: IDLE -> PAUSE (caravan at depot) | PAUSE -> FAILED (pause has no effect)
```
The game was still unpaused afterwards (`df.global.pause_state == false`).

## Evidence
`Bugs/evidence/BUG-223/` none recorded (live loop output only). The earlier flow with the legacy script (`echo handel > tools/pause.hold` before the first step, timestream off) passed PAUSE and SAVE.

## Analysis (reporter's hypothesis - CONFIRMED live, timestream is NOT the cause)
`trade_flow.py:119/125` PAUSE only returns `["claude/advance 0"]` and then checks `o.paused`. In this fort a pause guard (the fort's own watchdog in `lua/claude`, the same pattern as any "keep the game running" service) releases a pause within ~2 s unless `tools/pause.hold` exists. Tests with timestream OFF (`claude/tempo`: `timestream:false, manuell_aus:true`):
```
claude/advance 0        -> {"action":"paused","paused":true,...}
(2 s later)  pause_state -> false          # released by the guard
echo test > tools/pause.hold; claude/advance 0; (4 s later) pause_state -> true   # holds
rm tools/pause.hold; claude/advance run -> running
```
The legacy script that worked wrote `tools/pause.hold` before the first step. Fix: PAUSE step writes `pause.hold` (reason `trade`) via `self.tools` before `advance 0` (and every release path deletes it: RELEASE, ABORT, FAILED, reset), and FAILED text names what was tried. Also add a doc line in docs/MANUAL.md: every deliberate pause needs `pause.hold` or guard services will undo it. Related: BUG-224 (stale holds).

## Addendum 2026-10-02 (second live run, caravan created with `force Caravan`, FP12)
In this fort `tools/pause.hold` has the meaning "stay paused" and the guard enforces BOTH directions: no hold -> a pause is released within ~2 s; hold present -> a running game is paused again shortly after `claude/advance run`. Observed with the hold written by the orchestrator before the first step: `PAUSE -> SAVE -> BROKER -> MARK` pass, but after the BROKER step's `claude/advance run` the game was `paused=true` again (hold still present) so the broker and haulers could not work and MARK would wait for the 600 s timeout. After deleting the hold + `advance run` the game ran and haul jobs dropped (19 left, items at depot 189 -> 224).
So the flow must manage the hold itself: write `pause.hold` in PAUSE (kept through SAVE), **delete it in BROKER before `advance run`** (game must run while the broker walks and the haulers carry), write it again in OPEN/REVIEW (window open, game held), delete it in WAIT/RELEASE/RESUME/FAILED/ABORT/reset. A test with a fake guard that unpauses without a hold and re-pauses with a hold would pin this down.
