# BUG-479 Trolls broke the refuge hatch and walked into Tiefe+: the refuge's only closer is a building
Status: fixed (offline, live-untested); open: assumes a constructed wall stops building destroyers (the code paths and DF raws say a destroyer attacks buildings, not constructions; unverified live)
Severity: critical (Castletongs: 50 children and the adults died in the refuge; Syrupobeyed: the same with two trolls)
Found: 2026-11-05, Run 16c i3 Castletongs y403 (#5451 "nor the refuge hatch 122,127,122", #5621 "hostile inside at 122,127,121"); Run 16a i1 Syrupobeyed y387
Module: `lua/dfllm/seal.lua` (`M.plug`, `plug_lift`), `lua/dfllm/siege.lua` (`deep_step`, `step`)

## Actual
SIEGE_DEEP knew at once that "the bridges are no barrier, nor the refuge hatch 122,127,122; worn 29% < 60%" and still sent every civilian into Tiefe+ behind that hatch (the best burrow it had). Five trolls (BUILDINGDESTROYER) broke the hatch, walked down the stair and stood in the room; `REFUGE_FAIL ... hostile inside at 122,127,121`, "civ alert off, citizens flee on their own", 46 deaths in a day.

## Root cause
`seal.refuge_closure` classes a hatch/door/floodgate/grate/bars as `soft` and a bridge as `hard`, and BUG-337/378 only used that to decide whether Kern+ or the refuge is the civilians' burrow. Nothing built a line a building destroyer cannot break; BUG-462 showed raised bridges are no such line either. The refuge had one building (the hatch) between the stair and 100 citizens.

## Fix (the second line: a wall round the stair foot)
`seal.plug(K, {bd})` (asked by siege on every deep-defense pass and every BREACH step while building destroyers are latched for the episode): when the way in is only a hatch/door (`refuge_open` nil, closer not a bridge), no hostile is inside the refuge, the stair column and the foot ring are empty of citizens, and the last responsible moment has come (BREACH / a hostile inside Kern+, or a destroyer within `PLUG.near` = 30 tiles of the stair head), it queues one `runner.repair` project of `Cw` cells on every open tile round the stair foot on the refuge level (`refuge_foot`, at most 8). The confined citizens build them from inside (the ring lies inside Tiefe+); a troll that breaks the hatch stands on a foot walled on every side. `REFUGE_PLUG` (A) names the project, the walls, the closer and the nearest destroyer. In PEACE after `PLUG.lift` (2400) quiet ticks the walls are designated for removal (`act.construction_remove`), `REFUGE_PLUG` lifted. Persisted in `m.seal.plug`, constants `seal.PLUG {on, near, lift, retry}`.
It never replaces the hatch (BUG-336 first: an open stair answers 'wait:open way in'); no plug while the stair is occupied, so nobody is shut out or walled onto.
The destroyer-proof choice is made by the civ's own history: the plug is asked only when destroyers are latched (seen, or announced by the popup, BUG-480); a fort whose enemies are plain goblins keeps the hatch alone.

## Tests
`tests/lua/test_bug479_refuge_plug.lua` (5: eight walls on the refuge level, never the stair itself, held on a second ask; waits for open stair / far destroyers / no destroyers / a citizen on the stair / a hostile inside; BREACH is the last moment; lifted in PEACE; survives a reload), `tests/lua/test_bug478_481_siege_traffic.lua` (the deep defense asks for the plug with trolls in sight, in the siege traffic scenario).

## Live check
A siege with trolls and a hatch-only refuge: kern.log `seal: refuge plug: 8 walls round the stair foot ... against building destroyers`, `REFUGE_PLUG` A, the project `rpNNN` builds the walls (needs boulders or blocks: `inspect what=projects`); after the siege `REFUGE_PLUG` lifted. If trolls pass the walls, the destroyer level breaks constructions too: then the plug must be a second hatch line, to be reported.
