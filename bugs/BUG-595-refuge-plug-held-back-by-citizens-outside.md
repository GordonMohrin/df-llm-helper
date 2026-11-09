# BUG-595 The refuge plug is held back all siege by citizens outside Tiefe+, the destroyers walk in through the hatch
Status: fixed (offline, live-untested)
Severity: critical (loses citizens: Pop 86 -> 2)
Found: 2026-11-09, Run 16b i2 Brotherarrow y414 (22nd invasion, 57 goblins and Blind Cave Ogres, 100+ days of siege, O1 and B2 toppled after 85 days, an ogre inside Tiefe+ at 84,121,131 via the hatch 84,121,134)
Module: `lua/dfllm/seal.lua` (`plug_eval`, `choose`), `lua/dfllm/siege.lua` (`deep_step`, the BREACH call)

## Actual
SIEGE_DEEP at tick 167090147 named 2 Blind Cave Ogres in sight 107 tiles out and "nor the refuge hatch 84,121,134", 23 civilians went to Tiefe+. The REFUGE_PLUG (walls round the stair foot, the only thing a building destroyer cannot break) was queued at tick 167209299, 119,000 ticks later, in the BREACH, when an ogre already stood at 84,121,131. The refuge was lost.

## Root cause
What the plug builds: constructed walls (`Cw` cells, `seal.lua` `plug_eval`), not a hatch or a door; the walls are right, the plug came too late. Round 38's early plug (`plug_eval`, BUG-589) walled the foot at once only when "nobody is outside the refuge burrow". In Brotherarrow 4-8 citizens always were (patients of a hospital outside Tiefe+, carers on the way: RECALL "+4 more out of Tiefe+ since", PATIENT_OUT), so `outside` stayed true the whole siege: `wait:destroyers far`, and the second check `wait:citizens not inside` kept it back until the BREACH. A nobody-outside rule holds for ever in a long siege. Also: destroyers the siege popup only announced (`st.bdx`, nothing in sight) never counted, and a plug that was queued but not built counted as a wall in `choose`, so a destroyer already on the stair did not move the citizens elsewhere.

## Fix
`plug_eval`: bedridden patients (`needs_healthcare`) outside the refuge burrow do not hold the plug back at all (they cannot walk in, waiting only costs the walls); walkers outside hold it back until no more of them got in for `PLUG.out_wait` (1800) + `PLUG.out_each` (600) per walker still outside ticks (`mem.plug_prog`, reset whenever one more is inside, so a stream of arrivals is never cut off); after that the foot is walled anyway (REFUGE_PLUG `early`, `out` = how many walkers stood outside). The old `wait:citizens not inside` rule stays for walkers while a destroyer is farther than `PLUG.close` and the clock has not run. `siege.deep_step` / the BREACH call pass `announced`, so announced engineers count as destroyers in sight. `choose`: a plug counts as a wall only when the runner project is done or no destroyer is within `PLUG.close` (10) tiles of the stair head; otherwise the BUG-589 rule applies (the separated burrow farthest from the destroyers holds the citizens).

## Tests
`tests/lua/test_bug595_597_refuge_siege.lua` (1), (2) (siege traffic with walking units: citizens stream to the stair over time while a destroyer walks in from 100 tiles; a bedridden patient outside; a stuck walker; the popup-only case; the walls finished / unfinished when the destroyer is on the stair); `tests/lua/test_bug588_589_refuge_destroyers.lua` (3) adapted (the plug stands = project done).

## Live check
In a siege with building destroyers REFUGE_PLUG `early=1` comes within about 2 game days of SIEGE_DEEP even with a patient outside (walkers still streaming in get their time); the event carries `out` (walkers only).

Related: BUG-479, BUG-588, BUG-589
