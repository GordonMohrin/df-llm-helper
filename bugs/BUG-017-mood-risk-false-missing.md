# BUG-017 MOOD_RISK reports missing materials although the mood dwarf already holds every item
Status: open
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
