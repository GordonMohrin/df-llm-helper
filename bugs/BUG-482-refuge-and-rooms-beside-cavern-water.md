# BUG-482 REFUGE / ROOM sites beside known cavern water; `plan check` demands the template there
Status: fixed (offline, live-untested)
Severity: high (the refuge, traps and explore of Roadvises hung on a site next to a cavern lake for years)
Found: 2026-11-05, Run 16b i2 Roadvises y398-y400 (FR-BUGS "Refuge liegt neben Cavern-Lake", "plan check erzwingt refuge_beds"; refuge z107 84-92,103-109, cavern lake at 91,110,107; refuge_beds y399s0b3 at 91,109,107 parked CAVERN_PLUG "no automatic plug for refuge_beds"; refuge_drink y398 the same)
Module: `dfpilot/bp/sites.py` (`cavern_water`, `cavern_keep`, `_no_store`), `dfpilot/plan.py` (`refuge_gate`, unchanged: it now sees `bed_site` False)

## Actual
The room ranking (`_rooms`) never looked at the manifest's `caverns` / cavern_lake breaches (only fortcore had `_dry` / `_flooded`, and the explore shaft its own avoid rules). `bp sites refuge_beds` offered the same spot again after the project parked at the lake, `plan propose` drafted it again, and `plan check` (refuge_gate) kept ERRORing "the refuge comes first ... add refuge_beds n=25", so the player had to take it back into the plan.

## Root cause
`sites.rank` for room templates: `_rooms` -> `aquifer_ok` -> `reachable` (sites.py rank), no cavern-water rule at all. The refuge gate's `_bed_site` (plan.py `_bed_site`) turned the free ranking into `bed_site` True/False; with the site on the lake always True, the gate demanded the bed build.

## Fix
`sites.cavern_water(snap, manifest)` lists the known cavern water: manifest `caverns` (recorded cavern / cavern_lake stops), breaches whose `why` starts with `cavern`, revealed water tiles that carry a cavern mark on the snapshot. `sites.cavern_keep` (called from `rank` right after `_rooms`, so for every room template incl. refuge_beds, refuge_drink, a refuge cistern) drops each site whose box, grown by `CAV_KEEP` (4) tiles in x/y and one level in z, holds such a tile; when nothing is left ValueError "all N candidate site(s) lie within 4 tiles of known cavern water (e.g. x,y,z) ... another quadrant, or none now". `_no_store` (refuge_drink's smaller-store hint) uses the same rule. Result for the gate: `free_sites` raises, `_bed_site` returns False, `refuge_gate` WARNS ("no free site takes refuge_beds now: the plan may be applied") instead of demanding the template, and `plan propose` (`refuge_drafts`: `bed_site is not False`) drafts none. Hidden rock is unknown and never counted.

## Tests
`tests/bp/test_bug482_cavern_keep.py` (4: the water list, refuge_beds/refuge_drink keep off a recorded stop - 3 sites become 1 -, no site left says why, a far cavern changes nothing).

## Live check
A fort with a `caverns` / cavern_lake entry in its manifest: `dfllm bp sites refuge_beds --fresh` offers no site within 4 tiles of it (the reason line names the water when none is left); `plan check` WARNs for the beds instead of ERROR; `plan propose` draws no refuge_beds there.
Open: the refuge ROOM itself (fortcore stage 3) is the fortcore ranking's (`_dry` keeps its dig BREACH_R=10 from every recorded breach and `_flooded` drops sites with revealed water within FLOOD_R of the deep dig); a refuge that already stands beside a lake keeps its beds on the far side only.
