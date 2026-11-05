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
- `plan.core_over_aquifer` + `wake._check_core_site` (every 5 min, PEACE, not with --no-auto): a fortcore stage 1 that is queued but not started (state.proj `s1.*` row, no tile dug yet (CORE_UNSTARTED_PCT 0; before the review fix: at most 20 %), no PROJECT_DONE, no
  p.aquifer / retrofit) whose deepest level (anchor z - 2 - depth - refuge) + 1 is not under the lowest known aquifer level gets a plain `bp.cancel` (only designations not dug yet go) and wakes PROJECT_STALE;
  `plan propose` then draws the aqshaft and the core below the aquifer (BUG-412/429 route).
- The core depth rule itself is unchanged: `aquifer=pass` ranks only cores whose deepest level + 1 lies under the LOWEST known level (`sites.aquifer_ok`), the aqshaft depth runs `AQ_REACH` levels under it (BUG-432).

## Tests
`tests/test_bug441_445_f28.py` (gate: known / none / running / done / off; follow places the probe, waits, refuses; `core_over_aquifer`; follow cancels once and never in a fight).

## Live check
A new fort: `adopt`, then in cli.log `auto:probe` (aqshaft depth 12) instead of `auto:starter ... fortcore`; kern.log `queued ... (aqshaft`; after the probe `plan propose` (levels known) drafts aqshaft + fortcore p.aquifer=pass.
Open: the probe shaft digs 12 levels outside any core on a dry world (AQ_PASS_DONE needs `dry_levels` dry levels after the last aquifer level, a dry world digs the full depth). A world whose first aquifer lies deeper than 12 levels is found by the core's own stop (BUG-129/130 re-site).

## Review fix (pre-deploy review of round 28)
- The probe could never be placed on a fresh embark: `bp sites aqshaft` raises `room sites need the fort manifest with zones.Z4` without a core, and `_aqshaft` only takes Z4 floor tiles. Now `bp.sites.probe_column` (via `plan.core_probe_args`) picks an open surface floor tile (sky above, citizens' walk group) nearest to the embark centre / depot, with the aqshaft safety rules (rock on its 4 sides, no cavern/warm level, keep-out boxes) and no open water within 4 tiles on any level it passes; follow sends `bp.place aqshaft site=S1 p.x/p.y/p.top/p.depth` (the explicit-column path of `cmd.place`, BUG-433). No column fits: DECISION_NEEDED `core_probe_noprobe` with the command to name one and `plan.core_probe = false`; the next ask of the starter places the core as before (no AUTO_FAIL loop, no coreless fort).
- `core_span_gate` 'wait' has an end: a probe not finished after `plan.PROBE_WAIT_DAYS` (45) game days (CMD event tick of its bp.place, else file age x ticks per second) is `stalled`: PROJECT_BLOCKED why=stalled + DECISION_NEEDED `core_probe_stalled` (bp.cancel command), the next ask places the core. A probe that finished but dug less than `CORE_PROBE_DEPTH` levels is `short`: it need not have reached below the aquifer, the span is NOT known (same escape).
- `CORE_UNSTARTED_PCT` 20 -> 0: a core with any dug tile is never cancelled by the re-site. `core_over_aquifer` still reports it (`started`), follow says DECISION_NEEDED `core_over_aquifer` (i2 Roadvises: a blocked stage-1 core over the aquifer, nothing was said). A re-site that does cancel (0 % dug) now also says DECISION_NEEDED `core_resite` (the fort has no core: `plan propose`, `plan apply`).
- Tests: `tests/test_bug441_445_f28.py` (probe through the real `cmd.place` without Z4, water/cavern refusal, no-probe -> decision -> core, stalled / short, started core -> decision, re-site decision).
