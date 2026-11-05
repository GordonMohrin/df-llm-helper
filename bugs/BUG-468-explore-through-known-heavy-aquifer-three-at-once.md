# BUG-468 `plan propose` draws explore shafts through known heavy aquifer levels, and three explores at once
Status: fixed (offline, live-untested)
Severity: high (every such explore stopped at a heavy aquifer: breach:heavy_aquifer, the shaft plugged; the miners busy for nothing)
Found: 2026-11-05, Run 16c i3 Castletongs (explore to z110 every year through the heavy z113), Run 16a i1 Basementflew (explore depth 24 from z129 through the heavy z123 / z120 with `p.avoid` empty, three explore@S1 in s0/s1/s2, "y372s3b1 stand 35 d set aside, no runner slot")
Module: `dfpilot/bp/sites.py` (`heavy_breach_levels`, `avoid_levels`), `dfpilot/plan.py` (`draft_supply`, `fit_explore`, `explore_running`, `heavy_explore_levels`, `supply_goals`)

## Actual
The manifest held `breaches` with `why heavy_aquifer` at z112, z110 (i3) and z123, z120 (i1) from earlier explores; the next propose drafted the next explore with the default depth through them again, in every season of the year.

## Root cause
`sites.avoid_levels` (the levels an explore shaft must not reach) took `p.avoid`, damp / cavern / warm marks and cavern breaches, not the heavy aquifer breaches; `aquifer_ok` lets shafts pass by design. `draft_supply` put one explore in EVERY remaining season, all placed at once.

## Fix
- `sites.heavy_breach_levels(manifest)`: every level a breach of ours showed a heavy aquifer on (any template); `avoid_levels` includes it, so `bp sites explore`, `bp.place`, `fit_explore` (the depth falls through 12, 9, 6, 4, 2) and `deep` stop above it. The notes and the CLI line say "stops above the heavy aquifer zN". A shaft that must PASS a heavy level is an `aqshaft` (its ring), never an explore.
- `draft_supply` drafts ONE explore, in the current season; `fit_explore` leaves it out while an explore project is under way (`plan.explore_running`: bp file, no PROJECT_DONE, not stopped at a breach), the note names it; `plan check` warns about two explores in one season.

## Tests
`tests/bp/test_bp_explore.py` (heavy level avoided, other breach reasons not), `tests/test_bug465_468_f29.py` (one at a time, stopped / done ones do not count, heavy note and depth), `tests/test_plan_supply.py`, `tests/test_bug241_244_plan_propose.py` (adapted: one explore per draft).

## Live check
`dfllm plan propose` in i3 (breaches at z112 / z110): one `explore@S1` with a depth that ends above z112 or none ("no explore site at any depth"), never two; with a running explore: "BUG-468: explore ... is under way".
Open: with the first hard stone below a heavy level an explore cannot reach it (see BUG-465: do not embark there); the aqshaft ring is the way down.
