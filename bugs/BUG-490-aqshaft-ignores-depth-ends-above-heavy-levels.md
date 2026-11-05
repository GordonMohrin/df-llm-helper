# BUG-490 AQSHAFT ignores p.depth: passed after the first light level and two dry levels, with heavy levels below
Status: fixed (offline, live-untested)
Severity: high (the shaft that should reach the core level ended at z125; z123/z120/z116 stayed unpassed)
Found: 2026-11-05, Run 16a i1 Basementflew y390 Herbst (FR-BUGS "Aquifer-Ebenen aqshaft #2"): aqshaft c1a1ac68a2 (16 levels, "down to the core level" z114) said AQ_PASS_DONE at z125 after 2 levels ("passed levels 127"), PROJECT_DONE; the manifest aquifer_levels read [119,126,127] while `bp sites` named z123/z126/z127
Module: `lua/dfllm/aqshaft.lua` (`A.next_level`, `A.pass_done`, `A.below`), `lua/dfllm/runner.lua` (`Q.aq_below`, `Q.hv_level`), `dfpilot/schema.py` (AQ_PASS_DONE `rest`)

## Actual
`A.next_level` declared the pass done when `aqn > 0 and dry >= dry_levels` (two dry levels under the last aquifer level), whatever p.depth said and whatever the kernel knew about the levels below. Known heavy levels (`m.runner hvl`, the heavy_aquifer breaches `dz`) were consulted only for the ring method, never for the stop. The level lists differed: `Q.hv_level` recorded a heavy level in `hvl` only, never in the manifest's `aquifer_levels` (`Q.aq_level`).

## Fix
- `Q.aq_below(z)`: the one list of known aquifer levels under z (manifest `aql` + `hvl` + heavy_aquifer breaches), descending; `Q.hv_level` records every heavy level in `aql` / manifest `aquifer_levels` too.
- `A.next_level`: dry enough, but a known aquifer level under z lies within the shaft's depth (the stage count) -> the shaft goes on (log "the shaft goes on"); heavy levels get the ring method as before (`ring_level` / `heavy_known`). `A.pass_done` says what is left: known levels BELOW the depth are named in AQ_PASS_DONE (`rest` int[] <= 6, msg "NOT passed: ... place another aqshaft from zN"), so the shaft does not end silently.
- Contract: AQ_PASS_DONE optional `rest` (schema.py, CONTRACTS.md and its appendix).

## Tests
`tests/lua/test_bug490_shaft_depth.lua` (3): goes on past two dry levels with z92 known inside the depth; ends at the depth with `rest = {80}` and "NOT passed"; a heavy level joins the manifest list and `aq_below` is descending.

## Live check
A shaft placed with p.depth 16 above known heavy levels digs past the second dry level (kern.log "the shaft goes on"), rings z123/z120/z116 from above, and ends with AQ_PASS_DONE only below the last known level (or names `rest`). `inspect manifest` aquifer_levels lists every heavy level.
