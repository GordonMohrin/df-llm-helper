# BUG-165 A save of another instance's line writes no TIMELINE_RESET
Status: fixed (offline, live-untested)
Severity: high (the folder's alarm.txt and log of a line the loaded save never had stay valid; DEFCON 1 after the load)
Found: 2026-10-29, live test round 2 i2 (DEFCON-AFTER-LOAD, NEW5)
Module: `lua/dfllm/kern.lua` (boot), `dfpilot/schema.py` (TIMELINE_RESET `kind`), `dfpilot/wake.py` (follow log text)

## Actual
i2 loaded `autosave 1` from the shared save folder. Another instance had written it: its persisted `kern.ev` was about 33436, this runtime
folder's events.jsonl ended at #32748 (tick 289621609), the clock (290707200) stood later than the folder's last tick. BUG-121 only compares
the clock with the folder's last tick, so no marker came, alarm.txt kept the old line's file, and the event numbers collided (#32248 a PAUSE
here, an ARRIVAL in the save).

## Fix
Boot also tests `kern.ev of the save > the folder's last event` (with a log in the folder): TIMELINE_RESET `kind=foreign`, `n_alt` = the
folder's last event, alarm.txt deleted as in the clock-back case (that one now says `kind=clock`). Numbers continue after the larger of the two.
`K.reset = {kind, n_alt}` tells the modules' init (reflex, BUG-166). Follow logs "save of another line loaded".

## Tests
`tests/lua/test_bug165_166_boot.lua` (first two tests), `tests/test_bug165_169_reflex.py` (schema, follow text); fail on b805745.

## Live check
Load a save written by another instance into a folder whose log ends earlier: `dfllm events --type TIMELINE_RESET` shows kind foreign with
n_alt = the folder's old last event; alarm.txt is the save's own while still paused.
