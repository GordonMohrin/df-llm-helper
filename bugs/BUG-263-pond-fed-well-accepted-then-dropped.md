# BUG-263 A well fed only by its own pond is accepted, bp sites places the hospital by it, then the loop rule drops it
Status: fixed (offline, live-untested)
Severity: high (a hospital placed on water that runs out: HOSPITAL_DRY 13 days later, patients without water)
Found: 2026-10-29, Run 15 Drillchamber y373 autumn, fix6-water
Module: `lua/dfllm/water.lua` (`M.loops`, `M.loop_mark`, `pond_loops`, `M.dropped`, `M.dry_causes`, `emit_gate`, `src_list`),
`dfpilot/bp/sites.py` (`_near_water` text)

## Actual
y373 aut d19: status `src 1 (well 17813 at 91,70,136 in Tiefe+)`, `bp sites hospital` accepted it, the hospital c1a18777bbab69ac01
was placed. kern.log: `cistern y373s0b0 done, its well 17803 dry for 30 days: bucket-fed, its pond zone 17804 removed as a pond loop
... no accepted water to carry from (no revealed water source)`, then `pond zone 17822 removed: the wet well 17813 beside it was its
water source (a loop)`. #420 aut d32 HOSPITAL_DRY `no accepted water on the map`, src 0. water.lua accepted any water down a well's
shaft, while `pond_loops` called the same well a loop (its pond's water came from itself): acceptance and loop detection disagreed.

## Fix
One predicate (`M.loops`, after `pond_loops` each run): a wet well with a Pond zone within `pond_near` while no wet Water Source zone
exists, or one whose pond `pond_loops` removed (persist `m.water.lw`, forgotten once the well reads dry), holds a store, no source:
`s.wet` false, `s.loop` = the pond, `s.water` true. The state's `water.src` (what `bp sites hospital` ranks by), `served()`, the
gate and the removal read `s.wet`; the refuge's drink and `wet_wells` (siege, readiness) and CISTERN_DRY read `s.water`. The nearest
accepted source is remembered (`m.water.slast`); when none is left HOSPITAL_DRY (why and message) names it and why it dropped out
(`the accepted well N at x,y,z dropped out (fed only by its own pond P: a loop)`), else the loop well itself; a cistern whose well is a
loop says so (cistern_state).

## Tests
`tests/lua/test_bug262_266_water.lua` `BUG-263 ...` x3 (two fail on 2b9c009; the Water Source zone case is the guard).

## Live check
Drillchamber-like fort: `dfllm status` `src` no longer lists a well whose pond zone lies beside it (no Water Source zone);
`inspect water_sources` sources show it `accepted 0`; `bp sites hospital` refuses with "a well fed only by its own pond is none";
HOSPITAL_DRY `(well N at x,y,z is fed only by its own pond P (a loop ...)`. With a zone on a brook the well counts again.
