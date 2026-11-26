# BUG-912 The autochop target lies above the plugin's own log count
Status: fixed (offline, live-untested)
Severity: high (no tree was felled while orders waited for wood)
Found: Run 17 i2 Whirledrampart: kern.log `autochop target 150 60 (floor 5, wood ordered 24)`, later `autochop target 197 107 (floor 5, wood ordered 82)` with the kernel counting 192 logs: the plugin fells only when ITS log count is below the min.
Module: `lua/dfllm/economy.lua` (`T.chop` l.12957, `M.chop_count` l.12953)

## What autochop counts (read in the DFHack docs, not from memory)
`E:/DF-test4/hack/docs/docs/tools/autochop.txt`: "Autochop checks your stock of logs and designates appropriate trees for chopping once every in-game day. Logs that are forbidden or inaccessible (e.g. in hidden parts of the map, under water, etc.) are not counted towards your target." The plugin counts every free, reachable log of the whole map, near the fort or at the edge, in or out of a stockpile. `autochop target <max> [<min>]`: "the target range for the number of logs you want to have in stock". The plugin source is not in the DF folder (only `plugins/autochop.plug.dll`), so the exact filters (owned, in a job, other walk group) are NOT known: the kernel counts in what the docs do not exclude (wood + wood_dist + other-walk-group logs + logs held by a job); forbidden logs and logs on a tile with no walk group (under water, walled in) are out. An over-count only fells a little more (bounded by `wood.chop_cap`, 1200), an under-count would keep the fort felling nothing.

## Fix
`T.chop`: need = floor + wood on order + margin (as before); gap = need - near usable logs (`M.wood_usable`, 0 while disbelieved). With a gap and the plugin seeing more logs than the kernel counts near (`M.chop_count(inv) > near`): min = plugin count + gap, max = min + band (90), capped by `chop_cap`; otherwise the old absolute target (floor + ordered + margin, clamped 60..cap). The reapply step (10) is the old one. The area is unchanged: the kernel never sets `autochop chop <burrow>`, so the plugin takes the accessible trees of the whole map (DF's own rules for the woodcutters and the civ alert burrow stay); no new outside rule, no new risk rule.

## Alarm
`T.chop` returns before any target change unless the mode is PEACE or RECOVERY (`HUNT_MODES`, as `T.woodpile`): in SIEGE, ALERT and BREACH the autochop target is left as it is, so the relative boost never sends woodcutters outside in an alarm. Test: SIEGE and ALERT with 192 far logs and 80 on order send no autochop command.

## Tests
`tests/lua/test_bug910_915_holz.lua`: i2 numbers (192 far logs, 80 ordered: min 312 > 192), enough near logs (no command), disbelieved (min = count + gap); `test_economy_chains.lua` target tests unchanged and green.

## Live-Erwartung
i2: kern.log shows `autochop target <max> <min> (... relative to its count)` with min above the log count the plugin sees (about 192 + floor + ordered + margin) within 3 game days of the reload (the next economy run); `FellTree` jobs appear (`inspect what=workload`, gamelog 'fells'); order 6936 builds its first barrel within 30 game days, or WOOD_DISBELIEVED explains why not. Risk: woodcutters walk out for the trees DF designates anywhere accessible (as before; the target now makes them go).
