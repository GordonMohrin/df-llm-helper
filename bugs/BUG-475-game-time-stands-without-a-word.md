# BUG-475 The game tick stood still (0 t/s, "not paused", heartbeat ok) and nobody was told
Status: fixed (offline, live-untested)
Severity: high (a fort at Pop 1-2 stood for hours; i2 showed `pause:popup` without a wording)
Found: 2026-11-05, Run 16 (i4 Mazelanterns Pop 1, i1 Syrupobeyed; i2 status `pause:popup`)
Module: `dfpilot/wake.py` (`Follower._check_stall`, `STALL_S`)

## Actual
State `t.tps` 0, heartbeat `paused:false` and fresh, the tick in the heartbeat did not move. No class-A event: the kernel's PAUSED_BY_DF needs `pause_state` or a popup in `world.status.popups`, and `resume` refuses ("the game is not paused") when neither is there. A screen the kernel cannot list (a modal) held the game.

## Root cause
Nothing compared the heartbeat tick over wall time; the only stall wakes were HB_STALE (heartbeat file old) and the arbiter's pause tracking (needs a pause state or a listed popup).

## Fix
`Follower._check_stall` (read-only, each poll): the kernel's heartbeat file was rewritten within the last `STALL_HB_MAX_S` (30 s; a file that stops moving is HB_STALE's case), its tick has not moved for `STALL_S` (120 s), the game is not paused by the player or the inbox (a pause with `owners.pause` other than `df` / `popup`) and the clock cap is not 0: one synthetic wake `TICK_STALL` (again after 30 min). The line names the pause owner, the newest popup text the kernel logged (PAUSED_BY_DF `popup`, POPUP_GONE `text`) and what is allowed: `pause:df` / `pause:popup` -> `dfllm cmd resume` (the kernel reads the popup, refuses threat or curse words, presses the pause key); no pause and no listed popup -> a screen the kernel cannot close: Gordon presses Esc / Enter in DF. Nothing is clicked from here (fair play: no desktop input).

## Tests
`tests/test_bug474_477_f29ops.py` (stall wake once and again, a moving tick / the player's pause is none, `pause:popup` names the logged text and `resume`, a stale heartbeat is HB_STALE's).

## Live check
Freeze a test fort on a modal: `TICK_STALL` arrives after 2 min with "not paused"; with a listed popup `resume` releases it. Expect no TICK_STALL during an autosave (freeze < 20 s) or a load.
Open: the kernel still cannot read a modal that is not in `world.status.popups`; the wake is the alarm.
