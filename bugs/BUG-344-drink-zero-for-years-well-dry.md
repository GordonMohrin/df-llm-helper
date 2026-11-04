# BUG-344 Drillchamber: drink 0 d for years, citizens die of thirst beside well 18324 'wet'
Status: partly fixed (offline, live-untested): economy's DECISION_NEEDED `thirst` now carries water's verdict and commands
(`water.drink_fix`): the well a thirsty citizen stands at without drinking, or `no accepted water` with the recipe (a Water
Source zone from a reachable bank, a well over a pit, a cistern, an aquifer well), `cmds` = `dfllm cmd inspect
what=water_sources`, `dfllm bp sites cistern`, the farms command for brewing; open: nothing refills or replaces a dry well by
itself (the player places the cistern/well the decision names), why well 18324 serves nobody
Severity: critical
Found: 2026-11-04, Run 15d (i4 Drillchamber y379-y397; code 14ff5a3), FR-BUGS "Patienten verdursten trotz Hospital-Zone:
Brunnen trocken, GiveWater laeuft ohne Wirkung" (y381), "Zwerg verdurstet AM Brunnen 18324" (y397)
Module: `lua/dfllm/economy.lua` (alarm_check :3154: the thirst decision's fixed text `water near the fort (well), brewing,
barrels?`), `lua/dfllm/water.lua` (no public verdict on the water for economy)

## Actual
- events.jsonl: DECISION_NEEDED `thirst` 271 times from tick 150244499 (`2 thirsty, drink 0 d: water near the fort (well),
  brewing, barrels?`), never a place, a source or a command.
- 37 citizens `dehydrated`; 13 of them, no patients, at 75,49,142 / 75,50,142 = 1 tile beside well 18324 (76,50,142) between
  tick 155131609 and 161091605, hunger 51,683-94,529 (they starved too). `inspect water_sources` read 18324 wet in Kern+;
  readiness `nearest accepted water: well 18324 at 76,50,142 in Kern+`.
- kern.log: `hospital ok, refuge dry (6 wells, 1 in Tiefe+, 0 of them wet), 2-4 wet sources`.

## Cause
- The thirst decision had no water facts: the kernel knew the accepted sources (water's last run) and the recipe
  (HOSPITAL_DRY's M.recipe, with commands), economy asked neither.
- Why 18324 serves nobody is not known offline: it is the hospital template's well (bp/c1a1a42305c01d4601.json: well `l` at
  76,50,142 over the channel 76-77,50 with its own `p{pond=true}` at 77,50,142, a bucket-filled sump). The citizens who die
  beside it with hunger rising too were standing there for days: the well gives them no water (a trickle the game does not
  serve, or they are stuck there). The first pass's explanation (a pond loop while zone 18276 lies 30 tiles away,
  M.pond_fed) is withdrawn with BUG-343's review: it would churn every template hospital and does not explain the hunger.
- `drink 0 d` is the drink stock: no farms (BUG-340), nothing brewed; the citizens drink water.

## Fix
- `water.drink_fix()` (public, report only): by the last run, a citizen (no patient) at thirst ≥ `well_thirst` (50,000)
  within 1 tile of an accepted well -> `citizen N (thirst T) stands beside well W at x,y,z, read wet: it gives no water;
  <recipe>`; no accepted water -> `no accepted water; <recipe>`; else `accepted water: <label>`. The recipe is M.recipe
  without the hospital's tail (`bare`); it only names the scan's safe ways and digs nothing (a dig it names stays the
  player's, under the PLAYBOOK's water checks). The census keeps up to `THIRSTY_MAX` (16) thirsty citizens' positions a run.
- economy alarm_check: q `N thirsty, drink D d (brew: farms, barrels): <drink_fix txt>` (≤ 200), `cmds` = drink_fix's command
  lines + `FOOD_CMD.farms`. Without water (module missing) the old text stays.

## Tests
tests/lua/test_bug262_266_water.lua `BUG-344` (drink_fix: before the first run, accepted, a thirsty citizen beside the well,
2 tiles away, no water) and `BUG-344: economy's thirst decision` (q and cmds). Both fail on 14ff5a3.

## Live check
i4 after a reload, with a citizen over thirst 50,000 at 75,50,142: DECISION_NEEDED thirst `... citizen N (thirst T) stands
beside well 18324 at 76,50,142, read wet: it gives no water; <recipe>` and `cmds`.

## Open
- Refilling or replacing a dry well (a cistern from the brook with a floodgate, a well over a reachable water body) is the
  player's placement from the decision's commands; the kernel builds nothing by itself (safety: no automatic dig near water).
- Why well 18324 does not serve (depth under it, the game's well rule) needs a live `inspect water_sources` read.
- drink 0 d: brewing needs farms (BUG-340 open).

Related: BUG-259, BUG-263, BUG-266, BUG-324, BUG-340, BUG-343
