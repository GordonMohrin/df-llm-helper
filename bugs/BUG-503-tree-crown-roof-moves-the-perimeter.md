# BUG-503 The perimeter opens again and again on sapling / shrub tiles: tree crowns count as a roof in the entrance check
Status: fixed (offline, live-untested)
Severity: high (R0 open_perimeter and the pop cap hold for years; `seal at=last` 3-6 times a year)
Found: 2026-11-05, Run 16a i1 Basementflew y396-y398 (`runs/run-16a/FR-BUGS.md` "OBS Seals bei Oberflaechen-Fort: Perimeter oeffnet sich periodisch neu"; events.jsonl SEAL "LEAK at 11,51,131 (sapling no door)", "3,127,131 (shrub no door)", "167,87,131", "183,100,131" ...; read only). Earlier: BUG-323 (Open: "tree crowns read as inside"), BUG-375 (Open: "where the saplings come from needs a live look")
Module: `lua/dfllm/seal.lua` (`open_sky`, `bfs` eval, `learn_perimeter`, `inside` in the door search)

## Actual
On a soil fort the ways in named by SIEGE_UNREADY / SEAL are floor, sapling and shrub tiles all over the surface (x = 3 ... 183), come and go with the seasons, and each `seal at=last` closes 1-4 of them (BUG-375 put the piece on the plant itself). The new ones keep coming.

## Root cause
`seal.lua bfs` (eval, `o = des.outside and 1 or 0`) classifies a tile as outside by `des.outside` only. A surface tile under a tree crown has `outside` false (DF counts the canopy as a roof), so the "inside" of the entrance check (the BFS from the citizens over tiles of their walk group) ran out through the forest; its rim (the entries) is wherever the crowns end and moves with every growing or falling branch. The tile a route enters through is then a sapling or a shrub at the rim, not a mouth of the fort. This is the mechanism BUG-323 suspected.

## Fix
`seal.lua open_sky(des, x, y, z)`: `des.outside`, or (not `subterranean` and the tile right above is a tree part: BRANCH, TRUNK_BRANCH, TWIG) = open sky. Used by the BFS classification (`eval`), the door search's `inside()` and `learn_perimeter`'s outer-neighbour test. A built roof (a floor above) and cave tiles are unchanged.

## Tests
`tests/lua/test_bug503_505_sealreach.lua` (2: a crown-roofed strip west of a wall gap is outside, the first leak is the gap, not the rim (fails with the old classification); the same strip under a built roof is inside).

## Live check
`dfllm cmd inspect what=entrances key=refresh` on a forest soil fort: the `ways` are tiles at real mouths (a wall gap, a door), none far into the trees; `open_perimeter` no longer returns after each season. If a way still names a plant tile far from the fort, send the tile and the tile type above it.
Open: only the tile directly above is read (a crown two levels up over open air is not).
