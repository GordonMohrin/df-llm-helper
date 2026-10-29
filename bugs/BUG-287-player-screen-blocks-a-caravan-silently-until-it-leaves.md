# BUG-287 a player screen blocks a caravan's trade x7-x14 and the caravan leaves without a question
Status: fixed (offline, live-untested)
Severity: medium (the player is told once by a class B CARAVAN event, then the visit times out)
Found: 2026-10-29, Run 15 (Earthboat: three visits blocked in a row by the same sheet)
Module: `lua/dfllm/trade.lua` (`finish` ui_busy)

## Actual
The BUG-016 CARAVAN `blocked` event (class B) came once per visit; every PHASE_MS a `trying again later` log line; at OPEN_MIN the
visit failed `time`. No wake asked the player to close the screen.

## Fix
`finish(ui_busy)` counts the tries of the visit (`v.busy`, persisted); at `BUSY_ASK` (3) it emits DECISION_NEEDED (A) once per visit
(`v.asked`): `id trade_screen`, `screen` = the focus string (<= 80 bytes), `n`, `q` with the ticks left. The kernel still never
touches the player's screen. Schema: DECISION_NEEDED `screen:s`; RULES row DECISION_NEEDED.

## Tests
`tests/lua/test_bug286_287_sheet.lua` `BUG-287: ...` (one question, the screen named, never repeated, nothing closed). Fails on
abc2f95.

## Live check
With a sheet open by hand at a caravan: `dfllm events --type DECISION_NEEDED` shows `trade_screen` with the focus after 3 tries;
follow wakes on it.
