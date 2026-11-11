# BUG-705 Census wood 210 beside DF's "Needs logs": the logs lay on another walk group
Status: fixed (offline, live-untested)
Severity: high
Found: 2026-11-11 02:25, Run 16b i2 Whirledrampart y420 aut d30 - y423 (every wooden job cancelled 'Needs logs': tables, chairs, doors, coffins, bins, bolts; buildingplan 40 suspended; 21 of 28 adults idle; 7 mood deaths without furniture or workshop)
Module: `lua/dfllm/economy.lua` (census `classify`, `M.wood_cancel`, `M.wood_probe`, `M.logs_words`)

## Root cause
`economy.lua` `classify`, branch `cat == 'WOOD'` (about line 1136): every unforbidden log counted into `wood`, whatever its walk group. The boulder branch already leaves out far stone (BUG-665, `rock_far`); logs were left as they were ('food, drink and logs keep the plain read'). In Whirledrampart all 210 logs lay on another walk group than the citizens (care's own scan of the same fort said `logs x2: none reachable [210/210/0]`, events.jsonl MOOD_NEED y420). DF's job picker takes only an item a worker can walk to and cancelled 'Needs logs', while economy saw 210: no treeless state (`pieces.treeless_days`), no wood want from the caravans, floors and orders planned against 210 logs, kern.log 'order 562 ConstructCoffin x1: no job for 16 days (Carpenters: 5 shops, 21 jobs (0 working) ...; 210 logs): only reported'. The census also did not separate forbidden logs, and a 'Needs logs' cancel said nothing about why.

## Fix
- Census: a log not carried and on another walk group (`a.far`, the plain read: a tile with no walkable group counts near) is `wood_far`, not `wood`; a forbidden log is `wood_forb` (it was never in `wood`). `reach_mark` only for the logs counted.
- `M.wood_cancel` (called from `cancel` for a DF cancel 'Needs logs'): at most once per 3 game days a warn line: census logs free / on another walk group / forbidden, the cause in words (free logs beside the cancel: 'DF refuses logs the census counts usable'; all far: open the way, bring them in, cut trees; all forbidden; none), and `M.wood_probe` (read only, up to 400 logs: in a job / forbidden / owned / carried, levels).

## Tests
`tests/lua/test_bug705_707_wood_axes.lua`: census split (near 4, far 210, forbidden 3 -> wood 4), all far -> wood 0, the cancel line for all-far and for free logs.

## Live check
`inspect what=census` shows `wood`, `wood_far`, `wood_forb`; after a 'Needs logs' cancel kern.log has `DF cancels ... census logs free N, on another walk group M, forbidden K: ...; levels zN xM`. Open: logs in a job (`in_job`) still count as `wood` (they free up when the job ends; the probe names them); who carries the far logs over is not done (the Woodcutters need an axe first: BUG-706, BUG-707).
