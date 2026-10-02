# Time-standstill and window guard (spec v3-04)

**When:** runs by itself inside `python -m dfpilot waechter --loop`; no command of its own. Look at it when
`events.log` shows `time stood still (...)` or `dfpilot check` shows a critical `freeze_guard` warning.

## What happens automatically
- The watcher's status query reports pause state, focus and frame counter/year tick every 2 s. If time does not move
  for 3 ticks (6 s) while not paused and an Info/Help/ViewSheets window is on top (a MessageBox also while paused),
  the guard presses keys like a player: `SELECT` on a MessageBox, otherwise `LEAVESCREEN`, up to 4 times 1 s apart,
  until `dwarfmode/Default`. Then `claude/advance run`, unless pause.hold, alert.flag or an enemy (siege.flag,
  'alarm'/'gefahr' hold) says otherwise. Event: `time stood still (<focus>): screens closed`.
- Trade aftercare: once `trade.flow` (state.db) is DONE, it deletes the leftover `pause.hold` ('karawane') and
  `caravan.flag` of that trade, closes the MessageBox and resumes the game (once per trade; a newer caravan is untouched).
- Every action is logged in state.db (`actions`, rule `freeze_guard`).

## Safety
- Never any input while the trade automaton is in SELECT_LIVE/CONFIRM/FINISH; trade windows are only closed if you
  add `Trade` to `classes`.
- A window you open while the game is running is left alone for `grace_s` (20 s); a window that does not stop the
  game is never touched.
- After 3 unsuccessful attempts: one CRITICAL event + digest warning and no more input until time moves again;
  at most 10 attempts per hour.

## Config (`freeze_guard:`)
`enabled true, ticks_to_act 3, max_leave 4, leave_gap_s 1.0, grace_s 20, classes [Info, Help, MessageBox, ViewSheets],
max_attempts 3, max_per_hour 10, aftercare true`

## Limits
- LIVE-UNTESTED: SELECT on the DFHack MessageBox, the year-tick part of the status line, the aftercare. The
  Info/Help LEAVESCREEN variant ran live on 01.10.2026.
- Other classes (Designate, Squads, Announcement, Trade) are only reported once, not closed.
