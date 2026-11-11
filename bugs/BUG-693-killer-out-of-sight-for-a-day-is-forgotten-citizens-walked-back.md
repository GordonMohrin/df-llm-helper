# BUG-693 A killer that left the census for a day is forgotten: the citizens are walked back into its burrow
Status: fixed (offline, live-untested)
Severity: high
Found: 2026-11-11, Run 16d i4 Trumpetrealms y461 winter (events 186243128-186244845): 'REFUGE_FAIL Tiefe+: hostile inside at 84,111,134, last seen 1154 ticks ago' then 'REFUGE_SWITCH Innen+ -> Tiefe+ during the BREACH: Innen+ supply (WET)'
Module: `lua/dfllm/seal.lua` (`hostile_in`, `M.rlatched`, `M.KLATCH`)

## Actual
`REFUGE_FAIL ... no separated burrow ... civ alert off, citizens flee on their own` fired every ~25 ticks while the goblin stood in Tiefe+ / Kern+ (the alert was off, flee=1); 1,200 ticks after the last sighting the refuge passed again and the supply rule walked the survivors back into the shaft: 17 killed in one day, later 22 more.

## Root cause
`seal.lua` `M.rlatched` (BUG-588) holds only the REFUGE refused for `RLATCH` (1,200) ticks after the last sighting, in a SIEGE / BREACH. A killer is out of the census more than a day at a time; Kern+ and Innen+ had no latch at all, so the pick fell back to them as soon as the goblin was out of view.

## Fix
`hostile_in` (once per census): a hostile with the kill mark (`kl`) standing in Kern+, the interior burrow or the refuge latches that burrow in `mem.klatch`; `M.rlatched(K, name, t)` returns it for `M.KLATCH` (7,200 ticks, six game days) after the last sighting in a SIEGE / BREACH, for any burrow; `rate` / `area_ok` refuse the burrow (as BUG-588 does), so the pick is another burrow or 'no confinement' (the citizens flee freely, away from it). A hostile that never killed keeps the old refuge-only RLATCH.

## Tests
`tests/lua/test_bug693_killer_latch.lua` (2: refuge refused past RLATCH, free again after KLATCH; a killer in Kern+ latches Kern+, a non-killer does not). Siege traffic: `test_bug588_589_refuge_destroyers.lua` (the old latch) unchanged.

## Live check
kern.log / REFUGE_SWITCH: no 'X -> Tiefe+' while a killer was seen there in the last 6 days. Open: a dead killer keeps the burrows refused until KLATCH or the end of the SIEGE / BREACH (no 'killed' signal clears it); the latch is runtime memory (a reload forgets it); the recall of citizens outside still follows the alert's pick (none = they flee).
