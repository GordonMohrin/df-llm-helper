# BUG-262 No aquifer well: a fort without a brook and with a light aquifer never gets accepted water (hospital held back)
Status: fixed (offline, live-untested)
Severity: high (goal G3 hospital unreachable; patients die of thirst in a fort that has water in its rock)
Found: 2026-10-29, Run 15 Inkintense (no brook, light aquifer) and Guildcleans (G3 red, `bp sites` refused, no water), fix6-water
Module: `dfpilot/bp/rooms.py` (`cistern_layout`, `cistern`, `WATER_KINDS`), `dfpilot/bp/sites.py` (`aquifer_well`, `rank`,
`_near_water`), `lua/dfllm/aqshaft.lua` (`A.basin`, `A.observe`, `A.wet`, `A.add_pt`), `lua/dfllm/water.lua` (`M.recipe`, `M.aq_level`)

## Actual
Inkintense plan draft: `hospital held back (BUG-034): no accepted water in the fort`; the site has no brook, a light aquifer; the
cistern y372s3b7 (bucket-fed) was being built. water.lua accepts a well over revealed water or a deep Water Source zone; aqshaft.lua
and observe mode smooth every aquifer wall a dig meets (they seal); no template dug a basin into an aquifer; the only cistern kinds
were bucket-fed (a pond: a loop without a source, BUG-263) or a brook intake. Guildcleans STAND y374: `Krankenhaus: kein Wasser (bp
sites verweigert)` (not re-verified live).

## Fix
`cistern` p.water = `aquifer` (no path): no pond hole, no pond zone; the 3x3 basin one level below the well room is dug into an
aquifer level. `dfllm bp sites cistern water=aquifer` (`sites.aquifer_well`) ranks only sites whose basin level is a known aquifer level
(manifest `aquifer_levels`, the snapshot's damp marks), whose room level and the level above it are dry, and whose basin level has no
recorded heavy aquifer (manifest breaches why heavy_aquifer/water: refused); damp marks do not reject it; ValueError with the reason.
Runner side (observe mode, aqshaft.lua): damp stone in a cistern's basin (an own tile with an own tile right above) is kept rough
(point state `keep`, never smoothed by `A.tick`), its rising water is no heavy stop (the runner's probe still stops at > seep_max:
a heavy aquifer is refused). water.lua's HOSPITAL_DRY recipe names the aquifer well when an aquifer level is known and nothing better
is in reach; the `bp sites hospital` refusal names it too.

## Tests
`tests/bp/test_bug262_aquifer_well.py` (4), `tests/lua/test_bug262_266_water.lua` `BUG-262: damp stone in a cistern basin ...` and
`BUG-265: ... BUG-262: an aquifer level known` (fail on 2b9c009).

## Live check
A light-aquifer fort with `aquifer_levels` in `inspect manifest`: `dfllm bp sites cistern water=aquifer` lists sites with
`basin on aquifer level zN`; bp.place it; the dig meets damp stone: kern.log `damp stone at x,y,z in the cistern basin: its walls stay
rough`, AQ_SEEP `(observe, cistern basin)`, no AQ_HEAVY for a light aquifer; after the build `inspect water_sources` shows the well
accepted (1, depth > 0) and `bp sites hospital` ranks beside it. Uncertain: whether the basin floods to 4/7+ while the dig stage is
still probed (then the runner stops it as heavy); whether aquifer water rises into the stair to the well room.
