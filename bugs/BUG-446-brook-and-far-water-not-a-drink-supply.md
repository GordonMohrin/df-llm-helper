# BUG-446 A brook is no water for the scan, and water 72 tiles away is "reachable water"
Status: fixed (offline, live-untested); open: whether brook tiles really read 1-3/7 with tiletype BROOK_BED / BROOK_TOP in the running DF
Severity: high (the fort runs out of drink and nobody asks)
Found: 2026-11-05, Run 16b i2 Roadvises y372-y374 and Run 16c i3 Castletongs y372 (`runs/run-16b/FR-BUGS.md` "STRANDED/Thirst: einzelne Zwerge ... Bach im Embark-Rechteck wird nicht als akzeptierte Quelle gefuehrt", `runs/run-16c/FR-BUGS.md` "Wasser weit weg beim Embark")
Module: `lua/dfllm/water.lua` (scan_group, scan_body, best_way, recipe, drink_access), `lua/dfllm/snapshot.lua` (liquids), `lua/dfllm/economy.lua` (no_water)

## Actual
- The embark scan said `brook=in`; the kernel's water scan found only a pond 72 tiles away (i2) or the first water ~100 tiles out (i3). i2 had drink 0 days and no brewable plants; nobody was asked.
- Cause 1: `snapshot.liquids` was always read with `min = water.deep` (4/7). A brook lies under 1-3/7 of water over tiletype BROOK_BED / BROOK_TOP, so none of its tiles was a "body" (water.lua `scan_survey`, `scan_read`),
  and the bank, the recipe and `drink_access` never saw it. (`STAND` and `snapshot.tile` knew BROOK_* since BUG-102.)
- Cause 2: `water.drink_access` counted a body with a reachable bank at ANY distance as drink (`ok = acc + bank > 0`), so economy's `no_water` (BUG-401, `economy.lua` `M.no_water`) stayed silent with the only bank 72 tiles from the fort and
  "nobody thirsty: they drink water" (they walked 72 tiles).

## Fix
- `snapshot.liquids(..., brook)`: with `brook` n (1 <= n < min) a tile of depth >= n is listed too when its tiletype is BROOK_BED / BROOK_TOP, a sixth field 1 marks it (no puddle, rain or seepage is).
- `water.brook_min` (1, 0 = off): the survey and the box reads pass it; a body with no tile >= deep is `brook` 1. It gets its bank like any body and counts for `drink_access`, but no Water Source zone (the game wants 4/7: `zone_cands` skips it),
  no well spot, and its own recipe ("the brook at x,y,z is drinkable from the bank ... a cistern piped to it: python -m dfpilot.bp.sites cistern --near x,y,z"); `best_way` offers it after the other ways (kind `brook`, `way_text`).
- `drink_access` returns `far` (no accepted source and the nearest body with a bank farther than `water.drink_far`, 40, 0 = off), `bd` (that distance), `bat` (its nearest water tile), `far_d`. `economy.no_water` treats `far` like dry
  when no brewable plant is in stock and drink is under `water.drink_far_d` (120) days: DECISION_NEEDED `no_water` ("water is 72 tiles away ..."), commands `python -m dfpilot.bp.sites cistern --near <bat> --radius 20`, `trade.want add plant, drink, seeds`,
  `inspect what=reach`; from `drink.access_d` drink days a PROJECT_REQUEST cistern why=no_water at `bat`; the gatherers and caravans as before.

## Tests
`tests/lua/test_bug446_449_water.lua` (brook body / flags / recipe, brook_min 0, far, economy decision and its negatives).

## Live check
`dfllm cmd inspect what=water_sources` on a fort with a brook: a body with `brook: 1`, `way` names it; economy: DECISION_NEEDED `no_water` (once a week) with the cistern command when only far water exists. If brook tiles read 0/7 or
another tiletype name in the running DF, `water.brook_min` has no effect: dump one brook tile's flow_size / tiletype shape.
