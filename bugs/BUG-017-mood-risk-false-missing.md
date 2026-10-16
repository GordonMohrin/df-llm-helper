# BUG-017 MOOD_RISK reports missing materials although the mood dwarf already holds every item
Status: fixed (offline, live-untested)
Severity: low (class A noise, hides the real shortage: leather)
Found: 2026-10-15 18:20, test fort (y374), dfpilot main 95fe16d
Module: `lua/dfllm/care.lua:1985-2030` (`mood_report`, `nd.avail < nd.n`), `lua/dfllm/reserve.lua`

## Actual
```
#12045 A MOOD_RISK strange mood unit 26325 (Fey) starts without bars x1 (inorganic), cloth(silk) x1, bone x1, logs x1
#12052 A MOOD_RISK mood unit 26325 (Fey) thirst 40197, dies at 75000: missing bars,cloth,bone,logs; a mood job cannot be cancelled, supply it
```
Lua at the same time (unit 26325, job StrangeMoodCrafter at the workshop 74,71,109): `job_items` 8 entries, `job.items` 8 attached: 3 boulders (mudstone), BAR iron,
CLOTH cave spider silk, CORPSEPIECE mule bone, ROUGH tube agate, SMALLGEM topaz; (the 8th, WOOD, is the `logs` need - listed in job_items as quantity 1 and attached as the 8th item by the dwarf).
Stock: 993 cave spider silk cloth, 169 bone-material items, 23 logs, bars exist. The only class never in stock is raw leather (0 SKIN_TANNED items); that really kills the moods that need it
(unit 24497 Macabre, 25852 Secretive, 26238 Fey, 26239 Possessed died of thirst at 75000 with `leather` in their need list).

## Expected
`avail` counts what a dwarf can fetch (free, reachable, unforbidden items), or MOOD_RISK says `reserve holds 0 of 1` instead of `missing`; and it names leather as the item that has no source.

## Fix proposal
Read the mood job's `job_items` / `job.items` when the dwarf has claimed a workshop (the real need list and what is already attached) and report only the needs without an attached item.

Related: FR-44, BUG-008

## Cause (suspected, from the code)
Two paths can report items the dwarf already holds:
1. **Stale list.** The thirst/hunger MOOD_RISK is raised in care's unit phase from `rec.missing`, the list of the *previous* care run
   (up to a game day old); the dwarf attaches items in the meantime. The start check (`starts without`) is written when the needs are
   first read; a sliced run that scans the stock for several frames reports what the job lacked when the run began.
2. **Attached items without a filter index.** `reserve.job_needs` counted an attached item only through its `job_item_idx`; an item
   attached with `-1` (or an index the filters do not have) left its filter open, and the item itself is `in_job`, so the stock scan
   could not count it either. Whether DF 53 attaches mood items this way is not confirmed; the evidence (all 8 attached, 4 filters still
   reported) fits it.

## Fix (Claude, 2026-10-16)
- `lua/dfllm/reserve.lua` `job_needs`: an attached item without a valid filter index is matched (`R.match`: type, material, corpse
  part, cloth kind) to the first need of that kind still short; only needs left over are returned.
- `lua/dfllm/care.lua`:
  - `mood_report` reads the mood job again at report time (`open_filters`) and reports a need only while its filter still lacks an
    attached item (`min(need, still open) - available`); a filter the dwarf filled during the run drops out of MOOD_RISK, MOOD_NEED,
    the wants hook and DECISION_NEEDED.
  - the thirst/hunger MOOD_RISK keeps only the classes of the last report that a filter of the current job still lacks
    (`still_missing`); with nothing open it says `nothing missing` (without "supply it").
  - the stock scan counts per need whether the fort has any matching item at all (usable, forbidden, held or far; busy and carried items
    and hidden tiles not). A short need without one is named: `strange mood unit 26238 (Fey) starts without leather x1, bone x1;
    leather: no source in the fort`, also in MOOD_NEED, the thirst/hunger MOOD_RISK (`missing leather,bone (leather: no source in the
    fort)`) and the DECISION_NEEDED question; d `nosrc` (MOOD_RISK, MOOD_NEED).
- Tests (`tests/lua/test_care_moods.lua`, all four fail on the old code): items attached since the last report (thirst MOOD_RISK
  `nothing missing`); items attached with `job_item_idx = -1` (only the boulder still short); an item attached while the run scans the
  stock (no MOOD_RISK, no MOOD_NEED); no tanned leather in the fort (`leather: no source in the fort` in MOOD_RISK, MOOD_NEED, the thirst
  MOOD_RISK and DECISION_NEEDED).
- **Cloth and thread kinds** (coordinator, Run 10 y418, MOOD_RISK #5072: a plant-cloth mood while the reserve line said `cloth 0/7`,
  all wool):
  - `reserve.kind(it)` reads the kind of a CLOTH/THREAD item (material flags SILK, THREAD_PLANT, YARN); `reserve.token` gives a kinded
    filter the sub-token `cloth:plant` / `cloth:silk` / `cloth:yarn` (`thread:*` alike), plain `cloth` only when any kind fits; this
    is the `buy` field of `care.mood_wants` (the trade branch maps it).
  - MOOD_RISK and MOOD_NEED name a kind with its stock: `starts without cloth(plant) x1; cloth(plant) 0 in stock` (d `nosrc` holds
    `cloth(plant)` when there is none).
  - The mood reserve counts cloth and thread per kind: the hold is split over the kinds in stock (`reserve.split`, water filling: 10
    over plant 2, silk 5, yarn 7 = plant 2, silk 4, yarn 4), so every kind keeps a stash instead of the first 10 in the pile; the
    kern.log line reads `cloth 10/10 (plant 2, silk 5, yarn 7 in stock)`. The class hold itself (and economy's floor) is unchanged; a
    kind already held beyond its share is not released (the next mood frees what it needs).
  - Tests: `tests/lua/test_care_moods.lua` (plant-cloth mood next to wool: text, `nosrc`, `buy` tokens), `tests/lua/test_reserve.lua`
    (kinds, tokens, split, the kind-split reserve and its line); they fail on the old code.
- Live check: at the next strange mood read `job.items` (`job_item_idx` of each attached item) next to MOOD_RISK/MOOD_NEED: the list must
  shrink as the dwarf collects; a mood needing leather with 0 SKIN_TANNED must say `leather: no source in the fort`.
