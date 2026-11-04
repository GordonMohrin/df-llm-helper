# BUG-393 a strange mood short of boulders/blocks (none in the fort) never got a stone dig: the dig it asks for needs a fortcore room site
Status: fixed (offline, live-untested); open: soft vs hard stone is not told apart, bars without ore still depend on a caravan
Severity: high
Found: 2026-11-04, Run 16 round 2 (i3 Yawninggilt `r16c2-w6-17-site97`: 4 mood deaths; i2 Ostgate: 5 failed moods; `runs/run-16c/FR-BUGS.md`)
Module: `lua/dfllm/care.lua` (stone_site, stone_dig, mood_report), `lua/dfllm/runner.lua` (stonedig), `lua/dfllm/snapshot.lua` (tile.mat), `config/baseline.json`, `dfpilot/fairplay.py`

## Actual
i3, events.jsonl #1234-#1312: a Secretive mason's mood `boulders(hard) x1: none in the fort [0/0/0 of 57]` (57 boulders of economic or soft
stone, none usable), MOOD_CRITICAL `material` at 40, 36, 20, 10, 6, 2 days, `DECISION_NEEDED mood_material ... dig stone (bp.place bedrooms
prio=1)`, the mood failed (`MOOD_END ok:0`). A Fey mood `blocks x1: none in the fort` the same way. Over the whole logs i3 counts 10 failed moods (5 Secretive,
2 Possessed, 3 Fey) beside 3 done, i2 21 failed (8 Secretive, 6 Possessed, 7 Fey) beside 5, with `bars`, `boulders`, `cloth`, `gems`, `bone` as the missing classes. The kernel's acquisition for the class (`acq: boulders:dig`) was a `PROJECT_REQUEST bedrooms
why=mood_rock`; follow answered `AUTO_FAIL bedrooms: no sites snapshot` (i3 cli.log): a bedrooms project hangs on the dug Z4
floor of a fortcore, and these forts had none.

## Root cause
`care.lua` `acquire` (the `boulders` branch, `PROJECT_REQUEST bedrooms why=mood_rock`, ~:3533) and `economy.rock_dig` (`why=rock`) are the only stone digs of
the kernel and both are rooms that follow places with `bp.place bedrooms S1`: `bp.sites.rank` offers no site without the fortcore's public floor
(BUG-384 had the same for the hospital). Nothing dug a few tiles of rock for the one boulder a mood needs.

## Fix
- `care.lua` `M.stone_site` (:3399): a safe small dig for the mood: nearest revealed STONE-layer wall (snapshot.tile: `c '#'`, shape WALL, not soil, not a
  vein (`mat`, new in snapshot.tile, BUG-393), no aquifer, no cavern, no designation, no building) within `care.stone_r` (14) tiles of the moody dwarf, beside an
  open floor tile the dwarf can walk to (the walk-group hook `snapshot.reach`), a straight tunnel of short + 2 tiles; no water, magma, aquifer or cavern within
  `care.stone_wet` (3) tiles of any dug tile or right above/below it; the tile behind the last one stays rock (no new way in); at most `care.stone_probes`
  (900) tile reads; hidden tiles are unknown rock, never open.
- `care.lua` `M.stone_dig` (:3483), called from `mood_report` (:3694) when a boulders/blocks need is none in the fort (`rockn`): `runner.stonedig`
  in PEACE only, one dig at a time, at most `care.stone_tries` (3) digs `care.stone_retry` (3) days apart, tiles of an earlier dig are skipped. MOOD_CRITICAL's
  line says `stone dig sdgN: 3 tiles at x,y,z` or `no stone dig: <why>`; the caravans are asked for `stone` as before (`rec.buy`).
- `runner.lua` `M.stonedig` (:5915): a `stonedig` dig project (class living, prio 1, one stage of `d` cells, no manifest); it counts as a mood project (never paused, the
  slot beside `active`), runs in PEACE only, and the usual dig safeguards (damp/warm/cavern stop) apply.
- Config `care.stone_dig/_r/_probes/_wet/_tries/_retry` (baseline.json, `fairplay.CARE_LIM`, CONTRACTS).
- Bars: a mood that needs bars with no ore in the fort cannot be helped by a dig (veins are hidden; fair play): the caravans are asked (`bar:<metal>` in `rec.buy`,
  as before) and BUG-395's decision names the command.

## Tests
tests/lua/test_bug393_395_mood_stone.lua (5 for this bug: dig at the nearest wall, water/aquifer/vein/soil/cavern refused, PEACE only and once, no wall named),
tests/test_bug393_395_mood_stone.py (config limits).

## Open
- snapshot.tile cannot tell soft from hard stone: a soft layer (sandstone, siltstone ...) yields boulders a `boulders(hard)` filter refuses. The next try (3 days later)
  skips the tiles of the first; the caravan stays the fallback. A mat-level check needs a layer read in snapshot.lua (live).
- The dig takes a miner: a fort with no Miners/pick keeps the project open (PROJECT_BLOCKED idle names it).
- The tunnel is dug where the dwarf stands, not where the fort wants rooms; it stays a 1-wide dead end.

## Live check
A fort with a revealed hillside and a Secretive/Possessed mood whose boulders(hard) are none in the fort: kern.log `stone dig sdg<tick> queued: 3 tiles from x,y,z`, a PROJECT_STAGE
`stone.dig`, then boulders in the census (`stock rock`), MOOD_NEED goes away. Near a brook: `no stone dig: ... none safe and reachable`.
