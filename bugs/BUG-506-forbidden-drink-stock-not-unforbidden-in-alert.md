# BUG-506 2015 drink units stay forbidden for ~100 days after a siege: the unforbid ran only in PEACE / RECOVERY
Status: fixed (offline, live-untested); open: what forbade the barrels is not proven
Severity: critical (the drink days read 4-15 beside 736 real ones: every drink alarm, the brewing and the thirst decisions work on a wrong number)
Found: 2026-11-05/06, Run 16a i1 Basementflew after the y406 siege (FR-BUGS "2015 Trinkitems forbidden seit der Belagerung")
Module: `lua/dfllm/economy.lua` (`T.forbid`, `M.forbid_note`), `dfpilot/brief.py`, `dfpilot/schema.py`, `lua/dfllm/util/contract.lua`

## Actual
`status` said "2015 drink items forbidden (not in the days above; the kernel unforbids them)" with `drink 4d! -> 13d! -> 15d!` at Pop 31 for 60+ game days (it had been 252 d at Pop 98); the kernel did not free them.

## Cause (read-only logs of the live run, `r16a5-basementflew-site97`)
`economy.T.forbid` (the FR-76 burst, 400 units a day) starts with `if not HUNT_MODES[K.mode()] then return true end`: PEACE and RECOVERY only. events.jsonl: SIEGE_END at tick 163909942, then `MODE PEACE>ALERT hostile` / `ALERT>PEACE quiet` from 163910419 to 164039265 (about 129,000 ticks, 107 game days, a wandering ELK_BIRD predator: `LOCKDOWN interrupt PREDATOR`). The daily economy run found the mode ALERT almost every time. The first and only unforbid line is at tick 164092869: `unforbidden: container x106; seeds x4 (a forbidden stock: 2015 drink + food units, up to 400 a day)`, at the first daily run in PEACE. The state of that fort now (drink_d 736, no `dforb`) shows the burst works once it runs.
What forbade the 106 containers is NOT proven: no kernel module forbids drink or its barrels (care forbids only the mood reserve classes, reflex forbids doors) and the log has no line for it. DF's own flagging during the siege / recall is the only candidate left.

## Fix
- `M.FORBID_MODES` = PEACE, RECOVERY, ALERT, DRILL: the daily unforbid (and the burst) runs in ALERT and DRILL; SIEGE / BREACH still skip it (units may be outside).
- `M.forbid_note` + state `stock.dfd` (daily runs the forbidden drink / food stock stood) and `stock.dfwhy` (`mode SIEGE`, or `N off the walk group` when items are forbidden on a hidden or cut-off tile the kernel will not touch).
- `status` / `brief`: from 3 runs the line is a warning: "N drink items forbidden for D days, NOT in the days above (the drink days understate the stock); the unforbid is held back: <why>!" instead of the unconditional "the kernel unforbids them".
- The forbidden units are already counted separately (`stock.dforb` / `fforb`, FR-76); `drink_d` stays the free stock.

## Tests
`tests/lua/test_economy_supply.lua` (BUG-506: ALERT and DRILL unforbid, SIEGE does not and reports `dfd` / `dfwhy`, `forbid_note`), `tests/test_bug506_509_f32.py` (status lines, state schema).

## Live check
After the next siege with a PEACE / ALERT flip: kern.log `unforbidden: ...` within a day of the ALERT; `status` has no "NOT in the days above" line; `state.stock.dfd` / `dfwhy` while forbidden items remain.
Open: who forbade the barrels. If it was DF (siege recall), an unforbid of drink in SIEGE would be the next step; it was not added because the units may be outside.
