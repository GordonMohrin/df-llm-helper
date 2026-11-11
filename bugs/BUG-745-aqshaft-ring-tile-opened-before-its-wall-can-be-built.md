# BUG-745: aqshaft opens a ring tile into the heavy layer before its wall can be built

**Status:** fixed (offline, live-untested)

## Symptom
Run 16c i3 Doorwings y392 (kern c9306a79): the 7th aqshaft S1 74,91,147 reached z140 (aquifer top). The ring tile 75,91,140 was
channelled open; the wall was designated but 'nobody builds it' (kern.log: "shaft z140 waits (the ring wall is designated and not built)
2 d"), then the heavy layer flowed in (flow 4/7), AQ_HEAVY + CAVERN_PLUG, shaft stopped for good. The six earlier shafts (y381, y382, ...)
failed the same way (ring wall unbuilt, no stone). At that moment economy said "stone free 0 (need 73) ... 0 usable by the census" while the
fort had logs: buildingplan still took boulders, so the wall waited for a boulder nobody could hand over.

## Cause
`lua/dfllm/aqshaft.lua` `A.ring_step`: the channel (`designate(... 'h')`, piece `new` -> `chan`) was designated with only the material COUNT
checked once at the ring start; the wall's material route (`X.wall_alt`: buildingplan to logs / ore / flux) was resolved only after the wall
had waited `ring_wait` (2 d) - after the tile was already open into the aquifer. No check that a citizen with the construction labor exists.

## Change
- `aqshaft.lua` `ring_ready` (called before every channel): the wall material for all walls still missing is counted (`plug_missing`, stall
  `no_boulders`/`no_stone`), a citizen with the Building Construction labor exists (`X.builders`, stall `ring_builder`), and the wall route is
  resolved now (`X.wall_alt`). Otherwise the level stalls with NOTHING open (a dry stopped shaft). The `Cw` wall designation calls `X.wall_alt` too.
- `economy.lua` `M.wall_builders(K)`: active citizens with `BUILD_CONSTRUCTION` on (nil: unknown, does not block). Hook `X.builders` in `runner.lua`.

## Test
`tests/lua/test_bug745_ring_ready.lua` (4): route resolved before the first channel; no builder: nothing channelled, stall `ring_builder`, goes
on when one appears; no material: no channel, `no_boulders`; unknown builder count does not block.

## Open
The ring tile still has to be opened before it can be walled (the wall stands on the ramp the channel makes); the window is now only the build
time. Not run live.
