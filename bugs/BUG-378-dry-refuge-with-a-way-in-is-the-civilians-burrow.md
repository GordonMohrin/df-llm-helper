# BUG-378 in a siege the civilians go to a dry refuge with a way in, or flee, while Kern+ stands closed
Status: fixed (offline, live-untested)
Severity: critical
Found: 2026-11-04, Run 16d (Plankscale, i4, `runs/run-16d/FR-BUGS.md` "FORT GEFALLEN y382"; events of
`r16d-woodmill-site97`), kernel main ec9bd8e
Module: `lua/dfllm/seal.lua` (choose)

## Actual
Siege y382 winter: `SIEGE_DEEP ... refuge Tiefe+ ... soft hatch` (a cave dragon, a building destroyer) while the refuge was dry at
every siege before (`REFUGE_FAIL Tiefe+: no drink (drink 53<64, 1 well, none wet)`). The alert went to Tiefe+ / none and
`REFUGE_FAIL hostile inside at 78,115,133`, `civ alert off, citizens flee`: DEATHS_3PLUS 15 + 11 in a day. Kern+ was separated and
reachable with no hostile in it at the start of the sieges, but held no drink counts.

## Root cause
seal.lua `choose` (rate / the WET level): Kern+ needs its drink at every level up to WET; the open refuge was refused by BUG-336
and the dry soft-closed refuge was taken by the tail (`if r.danger or mode == 'BREACH'`: `try(refuge, 'BREACH')`, no counts) -
nobody asked whether Kern+ itself was closed. With the refuge open (BUG-336 `ropen`) and dry the tail found no pick at all
(`r.flee`); with it hatch-closed and destroyers in sight (BUG-337 `soft`) it picked the refuge the destroyers break.

## Fix
`choose`, before the danger tail: a refuge without drink (`wet` false) that has a way in - the open stair head (`ropen`), an
opening the dead-end tolerance lets by (`sep_of(refuge).exp`) or a hatch/door with building destroyers in sight
(`refuge_closure == 'soft'`) - is not the civilians' burrow in a SIEGE/BREACH (or with danger): Kern+, then the interior burrow,
separated, reachable and without a hostile (`rate(.., 'BREACH')`), holds them at the BREACH level (no counts, the breach days
window as for the dead end; REFUGE_FAIL names the refuge: `Tiefe+: no drink (drink a<b) and ...`). A burrow an opening reaches or a
hostile stands in is still refused (flee as before). A wet refuge, a closed dry refuge without destroyers and PEACE/ALERT without
danger keep their old picks. Held citizens leave the dry open refuge for Kern+ (REFUGE_SWITCH unsealed) instead of being kept
there (the merge15 test asserted the keep because there was no alternative; changed).

## Tests
tests/lua/test_seal_refuge.lua: 2 new (open dry refuge + Kern+ closed -> Kern+ for the SIEGE and the deep-defense ask, a hostile in
Kern+ -> flee; hatch-closed dry refuge with destroyers in sight -> Kern+, without them -> Tiefe+ as before) and the merge15 'held
in the open refuge' test now expects the move to Kern+. Fail on ec9bd8e.

## Live check
A siege with Tiefe+ dry: REFUGE_FAIL carries `no drink ... and <way in>`, the alert burrow is Kern+ (status `alert Kern+`), no
`civ alert off, citizens flee` while Kern+ is closed. Uncertain: Kern+ without drink holds only for the breach days; the BUG-031
dry mark takes the citizens out again if they go thirsty there.
