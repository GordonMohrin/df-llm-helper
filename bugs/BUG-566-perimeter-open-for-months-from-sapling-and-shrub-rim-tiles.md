# BUG-566 PERIMETER OPEN for up to 123 days from changing sapling / shrub tiles at the rim of a tree crown
Status: fixed (offline, live-untested); open: why the cached answer and `key=refresh` disagreed is inferred
Severity: high (R0 open_perimeter and the pop hold for months; `seal at=last` every season; seals on the outer surface far from the fort)
Found: 2026-11-06, Run 16b i2 Brotherarrow y398 ("PERIMETER OPEN 123 d stale trotz R32", y388 "Sapling zaehlt weiter als Fort-Eingang"), Run 16d i4 Trumpetrealms y397 ("Pflanzen-Leak (shrub/sapling) tritt weiter als SEAL_LEAK auf"); `E:/DF-test2/dfllm-runtime/r16b4-brotherarrow-site97/events.jsonl` read only (SEAL `LEAK at 104,188,139 (branch no door)`, `111,179,139 (sapling no door)`, `15,137,139 (sapling no door)`, `169,9,139 (floor no door)`, SIEGE_UNREADY `ents 78,107,139 floor` then `60,106,139 floor`)
Module: `lua/dfllm/seal.lua` (`open_sky`, `M.veg_way`, `M.veg_only`, `openings_changed`, `seal_pass`, `entrance_doors`, `schedule_periodic`), `lua/dfllm/readiness.lua` (`entrances`)

## Actual
`status` `PERIMETER OPEN 123 days: 1 way in without door: 78,107,139 floor` (before: 81,75,139 shrub, 70,78,139, 98,80,139, 84,128,139: the tile changed every season) with `seal at=last` "nothing to close"; `inspect entrances` `LEAK sapling 72,186,139 / 20,128,139` (map-edge routes, `expect_sealed false`); `inspect entrances key=refresh` then gave "all with a door or bridge". SEAL_LEAK for a shrub in a siege although the plant is no mouth of the fort.

## Root cause
1. `open_sky` (BUG-503) read only the tile directly above: a crown 2-4 levels up still made the ground below it "inside" (DF: `outside` false), the rim of the crown was the opening and moved with every branch.
2. The opening's tile is a plant (`sapling` / `shrub` on the surface): vegetation at the rim of a crown or meadow, not a mouth, but counted by readiness' `open_perimeter` (R0, PERIMETER OPEN, the pop hold) and it raised SEAL_LEAK.
3. In PEACE the periodic check re-used its BFS answer for `bfs_every` (28) days unless a known opening was closed (`opening_open`); a plant that grew or died, or a crown that fell, changed the way's tile and the old answer stood (only `key=refresh`, `why inspect`, ran the BFS).

## Fix
- `open_sky`: reads the column above up to `TREE_UP` (4) levels while it is open air; a tree part decides open sky, anything else (a floor, a wall, a built roof) a roof.
- `M.veg_way` / opening `veg`: an opening whose tile is a sapling or shrub on a surface tile (`subterranean` false) is `veg` 1. `entrance_doors` lists it (`open[i].veg = 1`, `inspect entrances` `ways` still name it); `readiness.entrances` leaves it out of `open` / `ents` (no `open_perimeter`, no PERIMETER OPEN, no max-pop hold; kern.log says how many); `M.veg_only(res)` keeps SEAL_LEAK quiet when every way without a door is vegetation. A plant in a cave doorway still counts.
- `openings_changed(prev)` (a few reads per way): the periodic check compares each way without door or bridge with its tile now (what stands there, open sky); a change runs the BFS at once instead of after 28 days. The periodic check itself runs every game day (`CFG.open_every`) while the last check names such a way (cheap: the BFS only when something changed), else every `seal_every` as before.

## Tests
`tests/lua/test_bug566_vegetation_perimeter.lua` (6): a crown three levels up is open sky (first leak = the wall gap; old: the crown rim); a built floor under the crown is a roof; a sapling mouth is `veg` 1 and listed, a cave-tile plant and a floor are not; no SEAL_LEAK for a vegetation-only leak in a siege, one for a floor gap; a way whose sapling died is checked again within a day and its BFS runs while an unchanged answer is re-used; readiness counts no vegetation-only way, a floor beside it counts. `tests/lua/test_bug564_568_siege_traffic.lua` (3, the siege test). `tests/lua/seal_world.lua`: plants are walked.

## Live check
`status` stops naming `sapling` / `shrub` ways in on a forest soil fort; `PERIMETER OPEN` ends within a game day of a real seal being finished; `inspect entrances` shows `ways` with plants and kern.log `readiness: N ways in on a surface sapling or shrub only ... left out`.
Open: why the periodic BFS and `key=refresh` disagreed on the same day is inferred (cache + moving rim); a real mouth that holds a surface plant on its own tile is left out of the perimeter count until the plant dies (it stays on `inspect entrances`); a crown taller than 4 levels still reads as a roof.
