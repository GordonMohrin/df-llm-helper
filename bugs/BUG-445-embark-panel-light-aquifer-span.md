# BUG-445 The embark panel says 'light aquifer' for a site with four aquifer levels incl. two heavy ones; surfacecore as a fallback
Status: fixed (offline, live-untested)
Severity: medium
Found: 2026-11-05, Run 16b i2 Roadvises 25,21 (`runs/run-16b/FR-BUGS.md`: panel 'light', real span z112 heavy, z115 heavy, z118-120, very deep soil: no stone; the player placed `surfacecore` by hand)
Module: `tools/embark/checklist.lua` (aquifer item), `dfpilot/cmd.py` (`send`: surfacecore)

## Actual
The checklist passed 'light' as a plain warn; the panel names a class, never the number of levels or their weight. When the aquifer proved deep, a surface core was the player's way out (Gordon: no surface fort).

## Fix
- The aquifer item of the embark checklist says the panel shows a class, not the span (several levels, heavy ones too, may lie above the stone; the fort passes each by aqshaft before its core is dug); the verdict stays warn
  (`em.sh rank` / `scan` print the item's text). Light aquifer + very deep soil already fails `stone` (BUG-248).
- `bp.place surfacecore` is refused unless `plan.surface_core` is true (BUG-413's switch): not a fallback. (The plan never drafted it by default; `plan propose` draws aqshaft + core below the aquifer, BUG-412/441.)

## Tests
`tests/lua/test_embark_bug445.lua`, `tests/test_bug441_445_f28.py` (surfacecore refusal).

## Live check
`em.sh scan` on a light-aquifer rectangle: the aquifer item names the unknown span; `dfllm cmd bp.place tpl=surfacecore` refuses with BUG-445.
Open: the real span of a site is known only by digging (the probe shaft, BUG-441).
