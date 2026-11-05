# BUG-441 The fort core is queued before the aquifer span is known and lands above / in the aquifer
Status: fixed (offline, live-untested)
Severity: critical (Gordon's goal is a fort UNDER the aquifer: two of four forts got a core on the wrong side, `bp sites aqshaft` found no free column)
Found: 2026-11-05, Run 16b i2 Roadvises (`runs/run-16b/FR-BUGS.md`: "Kernel queued fortcore vor jedem Plan", z120/z119 light, z115 and z112 heavy, `fortcore aquifer=pass depth 8` hit 40,101,112) and Run 16c i3 Castletongs ("aqshaft nicht planbar: fortcore Stufe 1 wird beim Adopt schon platziert", `bp sites aqshaft --fresh`: all 42 sites lie on or beside the placed core)
Module: `dfpilot/wake.py` (`_place`, `_check_core_site`), `dfpilot/plan.py` (`core_span_gate`, `core_over_aquifer`, `probe_state`, `known_aquifer_levels`), `dfpilot/fairplay.py` (`plan.core_probe`)

## Actual
One minute after `adopt` the PLAN_EXHAUSTED of phase P0 made `wake._request_starter` place `fortcore` stage 1 (kern.log `queued c1a1aa... (fortcore, 5 stages)`; the id is follow's `bp.place`, not an own queue of the kernel).
Nothing was known about the rock below the start (the embark panel says 'light', hidden rock is unknown), so the core's dig ran into the aquifer (i2: stopped at z115 heavy, z112 heavy) and its footprint
made every `aqshaft` column 'beside a placed project'. A fortcore placed that way and not yet dug stayed where it was.

## Root cause
`dfpilot/wake.py _place` (the `fortcore` stage 1 branch) guarded only a site that is wet on the snapshot (`wet_core_guard`, BUG-419: score 0 / 'aquifer at'); with no aquifer known every site is dry, so the starter core was placed at once.
Nothing looked for a queued core that a LATER-known aquifer made wrong (`plan.core_resite` handles breach stops only).

## Fix
- `plan.core_span_gate` (called by `wake._place` for follow's own fortcore stage 1 after the wet-site guard): a level known (manifest `aquifer_levels`, snapshot `aqz`, breaches, levels two fortcore stops share)
  -> refuse (AUTO_FAIL names the lowest level and the route: `plan propose` drafts aqshaft@S1 then fortcore p.aquifer=pass below the lowest level, the aqshaft pierces every level down to it);
  nothing known and no probe -> an `aqshaft` probe of `CORE_PROBE_DEPTH` (12) levels is placed instead (`auto:probe` in cli.log); the probe digs -> wait (refuse with the reason);
  the probe is done (PROJECT_DONE) and no level was found -> the core is placed as before. `config/baseline.json plan.core_probe` (true; false = the old behaviour).
- `plan.core_over_aquifer` + `wake._check_core_site` (every 5 min, PEACE, not with --no-auto): a fortcore stage 1 that is queued but not started (state.proj `s1.*` row, at most 20 % dug, no PROJECT_DONE, no
  p.aquifer / retrofit) whose deepest level (anchor z - 2 - depth - refuge) + 1 is not under the lowest known aquifer level gets a plain `bp.cancel` (only designations not dug yet go) and wakes PROJECT_STALE;
  `plan propose` then draws the aqshaft and the core below the aquifer (BUG-412/429 route).
- The core depth rule itself is unchanged: `aquifer=pass` ranks only cores whose deepest level + 1 lies under the LOWEST known level (`sites.aquifer_ok`), the aqshaft depth runs `AQ_REACH` levels under it (BUG-432).

## Tests
`tests/test_bug441_445_f28.py` (gate: known / none / running / done / off; follow places the probe, waits, refuses; `core_over_aquifer`; follow cancels once and never in a fight).

## Live check
A new fort: `adopt`, then in cli.log `auto:probe` (aqshaft depth 12) instead of `auto:starter ... fortcore`; kern.log `queued ... (aqshaft`; after the probe `plan propose` (levels known) drafts aqshaft + fortcore p.aquifer=pass.
Open: the probe shaft digs 12 levels outside any core on a dry world (AQ_PASS_DONE needs `dry_levels` dry levels after the last aquifer level, a dry world digs the full depth). A world whose first aquifer lies deeper than 12 levels is found by the core's own stop (BUG-129/130 re-site).
