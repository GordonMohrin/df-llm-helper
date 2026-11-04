# BUG-344 Drillchamber: drink 0 d for years, a citizen dies of thirst beside well 18324 'wet'
Status: partly fixed (offline, live-untested): the hospital well 18324 with its own pond is a loop despite zone 18276 30
tiles away (not accepted, its pond removed; BUG-343's fix); open: drink 0 d is the brewing (no farms, BUG-340), refilling a
dry well from a brook (a cistern) is not automated
Severity: critical
Found: 2026-11-04, Run 15d (i4 Drillchamber y379-y397; code 14ff5a3), FR-BUGS "Patienten verdursten trotz Hospital-Zone:
Brunnen trocken, GiveWater laeuft ohne Wirkung" (y381), "Zwerg verdurstet AM Brunnen 18324" (y397)
Module: `lua/dfllm/water.lua` (was :514 and :556/:567: any wet Water Source zone switched the loop rule off)

## Actual
- y381: patients at thirst 68,000-74,000 with `jobs 0 open/1-2 running`; refuge `its 1 well is dry` (the Tiefe+ well, another
  one); y397: unit 27342 dead at 75,50,142 beside well 18324 (76,50,142), `inspect water_sources` lists 18324 as wet in Kern+.
- kern.log: `hospital ok, refuge dry (6 wells, 1 in Tiefe+, 0 of them wet), 3-4 wet sources`.

## Cause
bp/c1a1a42305c01d4601.json (hospital, anchor 74,47,142): its well `l` at 76,50,142 (= 18324) over the channel h(2x1)
76-77,50 and the zone `p{pond=true}` at 77,50,142: the hospital template's bucket-filled sump. The wet Water Source zone
18276 at 87,82,141 (~30 tiles) switched the loop rule off, so the well's trickle counted as wet water and the pond stayed:
the carriers poured the well's own water back. Same mechanism as BUG-343.
`drink 0 d` itself is the drink stock: no farms (`bp sites farms` 0 sites, BUG-340), nothing brewed; the citizens drink water.

## Fix
BUG-343: `M.pond_fed` (a zone feeds a pond only when it lies at most as far from it as the well); the well is no accepted
source, its pond is removed (`water: pond zone N removed`), the dry well is named in HOSPITAL_DRY (BUG-266 dry_well: 'only
buckets fill its sump; fill source: ...'), the recipe and the BUG-324 water zone as before. Never a dig beside water:
nothing new digs.

## Tests
tests/lua/test_bug262_266_water.lua `BUG-343/344` (fails on 14ff5a3), tests/lua/test_water.lua pond loop (far zone).

## Live check
i4 after a reload: `water: pond zone N removed: the wet well 18324 beside it was its water source (a loop)`; inspect
water_sources: 18324 no longer accepted (loop), zone 18276 the hospital's water (29 tiles, within `near` 30).

## Open
- Refilling a dry well (a cistern from the brook with a floodgate, a well over a reachable water body) is still a plan the
  player places (HOSPITAL_DRY recipe / bp sites cistern); the kernel decides nothing new here.
- Whether citizens keep walking to a dry well to drink is the game's.
- drink 0 d: brewing needs farms (BUG-340 open).

Related: BUG-263, BUG-266, BUG-324, BUG-340, BUG-343
