# fixtures/v3/freeze (spec v3-04, time-standstill and window guard)

All files are SYNTHETIC scenario descriptions, shaped after the live incidents (Run 5 Y109 Justice+Help standstill,
live trade test F15 MessageBox + leftover pause.hold/caravan.flag). `tests/test_freeze_guard.py` turns them into a
mock game: `screens` = focus stack (joined with '|' like getCurFocus(true)), `paused`, frame counter `fc` / year tick
`yt` (they move only while no window holds time or `time_moves_with_window` is true), optional `flags`, `trade_flow`
(store kv "trade.flow") and `stuck` (LEAVESCREEN has no effect).

Fixture gaps: a recorded watcher session (CLEAR_CMD output with fc/yt) of a real standstill, the real focus string of
the DFHack MessageBox after a trade, the effect of LEAVESCREEN on DF's Info/Justice panel (assumed: closes it).
