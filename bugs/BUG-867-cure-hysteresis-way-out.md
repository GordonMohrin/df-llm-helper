# BUG-867 The container cure flapped ON/OFF about once a game day; the 'nothing to make them of' line came every look
Status: fixed (offline, live-untested)
Severity: medium
Found: Run 17 i1, i2, i4 kern.log: `container cure OFF: ... 4x in 7 d (< 5)` then `ON: ... 6x in 7 d (>= 5)` every 1200-3600 ticks (55 lines on i4); i1 'container reserve: 10 containers wanted ... nothing to make them of: 0 usable logs, 0 free boulders' for two game years.
Module: `lua/dfllm/economy.lua` (`M.cx_reason`, `M.cx_log`, `M.plan_reserve`), `economy.cancel.cx_off_n` / `cx_off_days`, `dfpilot/fairplay.py`

## Root cause
`cx_gate` was a plain `n >= cx_min_n` on a rolling 7-day count, so a count hovering at 4-6 flipped it, and `cx_expire` gave the pile limits back at each dip. The no-material warning was throttled to once per game day only.

## Fix
Hysteresis in `cx_reason`: ON at >= `cx_min_n` (5), OFF only after the count stayed under `cx_off_n` (2) for `cx_off_days` (14) game days (latch `st.cxh`); the reserve's own repeat state machine reads the plain count (`raw`). The no-material line is said once per game week and names the way out: DF refuses the boulders (`inspect what=stone`), boulders exist but none free, or dig for stone (pick count), and `trade.want barrels or logs`.

## Tests
`tests/lua/test_bug854_reserve.lua` (hysteresis; the way out once a week), `tests/lua/test_bug851_gamelog_cadence.lua` (OFF after the window and the quiet days).

## Live-Erwartung
i1/i2/i4 kern.log: at most one ON and one OFF line per real shortage, no alternating pairs every day; i1: the no-material line at most once per game week with the way out. NOT promised: that stone becomes usable on i1 (why DF refuses CLAYSTONE/SANDSTONE for rock jobs is not shown by any log; the text names the denial).
