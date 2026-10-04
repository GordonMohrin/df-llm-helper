# BUG-433: Pausing for a trade blocks the caravan from arriving; `pause.hold` is released after 90 s by two guards

- **Status:** open (related: BUG-222, BUG-223, BUG-224)
- **Severity:** S2
- **Area:** `tools/aufsicht/supervisor.py`, scratchpad holdguard, `claude/advance`
- **Reported:** 2026-10-04, commit `eb0f007`
- **Environment:** Windows 11, Python 3.14, game: running (DF 53.16 + DFHack), fort Windrings year 183 (Run 5)

## Command / steps
1. Caravan with `trade_state 1` (arriving, about 3550 ticks left).
2. The orchestrator pauses the game for the trade agent (`claude/advance 0` plus `pause.hold`).

## Expected
The helper lets time run until the merchants and the broker stand at the depot and only then pauses for the trade window.

## Actual
- While paused the merchants never walk to the depot (state stays 1), so an early pause wastes the hold.
- `supervisor.py` (`HOLD_MAX_S = 90`) and the second guard delete any `pause.hold` older than 90 s and run `advance run`; the hold had to be refreshed every 30 s by a loop (max 15 minutes).
- Without a pause, tool latency let the game run several hundred ticks per call and the caravan left before the broker was at the depot (22:12 attempt).

## Evidence
Section "Handel 04.10. nachts" in `ERFAHRUNGEN.md` of the dwarf-fortress repo.

## Analysis (reporter's hypothesis)
Two different needs: (a) advance in small steps (`advance 300`) until the broker is at the depot, (b) hold only for the open trade window.

## Suggested fix
The trade flow advances in steps of at most 300 ticks while `trade_state == 1`, holds only once `trade_state == 2` and the broker is at the depot, renews the hold itself, and the supervisor ignores holds written by a live trade run (heartbeat).

## Info needed
none.
