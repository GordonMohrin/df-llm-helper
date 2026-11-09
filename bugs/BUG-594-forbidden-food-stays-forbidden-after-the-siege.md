# BUG-594 Loose forbidden food stays forbidden for 21-30 days after SIEGE_END
Status: fixed (offline, live-untested)
Severity: medium (food the dwarves cannot eat while the brief says "the kernel has not freed them")
Found: 2026-11-09, Run 16b i2 Brotherarrow y405 (5 food items forbidden 21 days after SIEGE_END and PEACE, `unforbid held back: mode SIEGE` earlier), Run 16a i1 Basementflew y406 (2015 drink units, BUG-506)
Module: `lua/dfllm/economy.lua` (`T.forbid`, `M.on.MODE`, `M.DEFAULTS.forbid`), `config/baseline.json`, `dfpilot/fairplay.py`

## Actual
After the fight the daily unforbid pass ran (PEACE/RECOVERY) but left single forbidden food and drink items as they were; the state said nothing (or `mode SIEGE` from the last siege day) and the brief `the kernel has not freed them`.

## Root cause
`economy.lua` `T.forbid` kept the census entries of why `food` (a forbidden food or drink item itself, not its container) unless a starvation (`p.starve`), a burst (>= 100 units, BUG-506) or the siege emergency (BUG-570) was on: it treats them as the player's own forbid. A lockdown and the fight leave such items forbidden too, and nothing freed them afterwards (BUG-570 only covers the hunger emergency inside a SIEGE, BUG-506 only the bulk).

## Fix
`p.fought` = the tick of the last SIEGE / BREACH day (set by the MODE event and by every daily pass in such a mode); for `forbid.after_days` (14; 0 = off; `fairplay.ECONOMY_LIM`) days after it, outside SIEGE / BREACH, `T.forbid` frees loose forbidden food and drink as it does in a starvation (same `per_day` limit). Overlap with BUG-570: the emergency inside a SIEGE is unchanged (`sv`); this starts when the fight ends. Items that stay forbidden say so: `stock.dfwhy` `N food/drink kept (forbidden by hand?)` instead of nothing.

## Tests
`tests/lua/test_economy_supply.lua` (+2: freed after the fight, held before and after the window with the cause; `after_days = 0` keeps the old rule)

## Live check
After a SIEGE_END: kern.log `unforbidden: food ...` within the day, `stock.fforb` back to 0; a food item forbidden by hand a month later stays and the status names `kept (forbidden by hand?)`.
