# BUG-003 `inspect tombs` shows stale numbers after burials succeeded
Status: fixed in 7006350 (offline, live-untested). Live (677bc3e): CONFIRMED. `inspect tombs` reports `last.entombed 1`, 311 coffins, 8 free, 49 unburied, numbers move with the burials.
Severity: medium (the operator thinks nothing happens and starts hand work)
Found: 2026-10-15, Run 9 save autosave 1, dfpilot main 3edc277
Module: `lua/dfllm/care.lua` (tomb phase index, `acts`, `inspect tombs`)

## Expected
`inspect what=tombs` reflects the state after the repair run: bodies already inside a coffin do not count as unburied,
`acts.entombed` counts the `entomb` runs, `free` counts usable empty coffins.

## Actual
After 8 new coffins were built and the kernel assigned zones and ran `entomb --unit <id> --haul-now` for them
(`commands.log`: `care act.run ["entomb","--unit","24631","--haul-now"] ok`, also 24633 and 24896), Lua showed 8 corpses
inside the new coffin tiles (21..29,50..52,109) and no PlaceItemInTomb jobs left (they had completed). The inspect still said:

```
inspect: tombs: 252 coffins, 0 free, 26 unburied, 6 ghosts, 0 burial jobs {"acts":{"assigned":0,"entombed":0,"failed":0,"freed":15,...
```
(the same numbers 3 minutes later; `entombed` stayed 0 though the commands ran ok; the zones had been assigned by the kernel:
zones at the new coffins carried unit ids, e.g. (21,50) -> 24631).

## Cause (suspected)
The index is rebuilt "each care run" but the care run that assigned the zones does not publish its `acts`, or the tomb phase
result is cached between runs (`repaired:1` in the first read). The legend and counts come from the previous index.

## Fix proposal
Publish the acts of the run that ran `entomb` (count the ok result), rebuild the index on `inspect` when older than one
frame batch, and count a body as buried when its item is `in_building` of a coffin.

Related: FR-45, FR-41, FR-26

## Fix (7006350, offline)
- A dead citizen with remains inside a coffin (`in_building`, holder in the COFFIN vector) counts as buried; loose parts of
  the same body elsewhere no longer keep it unburied (`buried_loose` in the inspect data).
- The tomb index is published by the run that acted (end of the tomb phase, not the end of the care run), and
  `inspect tombs` carries `last` = the acts of the last run that changed anything (tick, assigned, entombed, freed, ...),
  also in the message (`last acts tick N: assigned 3, entomb 3, ...`).
- An index older than one care period (1,200 ticks) is rebuilt for the inspect, read-only (`fresh: 1`, `run_tick`).
- Live check: after `entomb` ran, `inspect tombs` shows `last.entombed > 0`; a body in a coffin leaves `unburied`;
  `fresh: 1` while care lags (doctor shows care slow).
