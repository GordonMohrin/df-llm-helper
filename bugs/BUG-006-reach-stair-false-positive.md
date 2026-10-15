# BUG-006 `reach` reports a down stair without counterpart although the shaft below is all stairs
Status: open
Severity: low (a wrong flag in a report, no action taken)
Found: 2026-10-15, Run 9 save autosave 1, dfpilot main 3edc277
Module: `lua/dfllm/seal.lua` (stairs check in the reach audit)

## Actual
```
inspect: reach main group 1 (age 3490): stairs: 3 without counterpart (down stair at 30,66,109)
"stairs":[[30,66,109,"down stair","no stair below"],[67,92,116,"up stair","above unrevealed"],[62,99,116,"down stair","no stair below"]]
```
Lua at the same time, column (30,66): z109..z80 all `STAIR` tiles (the shaft was dug as `j`, 14 x `i`, `u`; every level is open and
walkable). So "no stair below" is false.

## Cause (suspected)
Stale snapshot (age 3490 ticks, the shaft was dug shortly before) or an up/down stair below a down stair is not accepted as the
counterpart; "above unrevealed" for the second entry shows the snapshot only knows revealed tiles.

## Fix proposal
Re-read the single tile with `dfhack.maps.getTileType` before reporting a flag, and accept `STAIR_UPDOWN` as the counterpart of both
directions.

Related: FR-63, FR-22
