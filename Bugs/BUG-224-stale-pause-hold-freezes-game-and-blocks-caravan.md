# BUG-224: a stale `pause.hold` (reason "karawane" / "alarm") keeps the game paused for a long time; nothing warns, the caravan never arrives

- **Status:** open
- **Severity:** S2 (game frozen for the player, approaching caravan can never reach the depot because no ticks run)
- **Area:** `df_llm_helper/waechter.py` / `caravan.py` / `digest.py` (writers/readers of `tools/pause.hold`)
- **Reported:** 2026-10-02, commit `ae17fff`
- **Environment:** Windows 11, Python 3.14, game running, fort dates 21. Limestone y120 and 8. Malachite y121.

## Command / steps
1. A citizen goes berserk (`BERSERK_CITIZEN` wake alarm); the hold file `tools/pause.hold` with text `alarm` is written.
2. The danger is over a minute later (unit struck down); nobody deletes the hold.
3. 15 min later the game is still paused (`df.global.pause_state == true`, frame counter stands still); `digest` shows no hint. Same with text `karawane`: a caravan was `Approaching` (3706 ticks left) while the game was paused by the hold, so it could never arrive; `trade step` stayed IDLE for 8 minutes.

## Expected
`digest`/`check`: `!! pause.hold stale (age 15 min, reason "alarm", no active danger) - game is frozen`; the wake filter emits it once; optional `autopilot` releases holds older than N minutes when no danger is active.

## Actual
No message; the orchestrator found it only by chance (`claude/advance run` did nothing visible, the military agent reported "game stands still").

## Evidence
none recorded; `tools/pause.hold` content `alarm` / `karawane`, `pause_state=true`, frame counter unchanged over 10 s.

## Analysis (reporter's hypothesis)
Writers of `pause.hold` exist in `siege.py`, `caravan.py`, `waechter.py`, `freeze_guard.py`, `settings.py`, `perf.py`, `camera.py` but there is no common owner/expiry. Suggest a hold file with `reason`, `ts`, `max_age_s` and a check that reports `stale hold` when the game is paused, no danger is active and the age exceeds the limit.
