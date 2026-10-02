# Spec 08: Water and Flood Watchdog (`python -m df_llm_helper water`)

Priority: P1 | As of: 01.10.2026 (Run 5, Windrings) | Status: implemented (PR v2-08), not yet live-tested | Framework: see README.md

## Goal and Benefit
Prevent water disasters. In Run 5 the attempt to run a tunnel diagonally to the shore flooded approx. 40 tiles (approx. 110 units); only an emergency wall built in under a minute saved it. Lessons: water also flows diagonally along rock edges, never open the bank of a river.
**Expected gain:** avoidable total losses, decisions with measurement instead of guesswork.

## Behavior
1. **Water scan** (`pilot_water.lua`, not yet live-tested): count tiles with `flow_size > 0` (water/magma) in configurable boxes and levels; output count, bounding box, level, "front".
2. **Pre-check:** `python -m df_llm_helper water check --designate x y z` checks whether a planned tile borders water or ramps with flow orthogonally, diagonally or vertically (z±1); result `ok/unsicher/verboten` (ok/uncertain/forbidden; conservative).
3. **Watchdog** (in `check`): counts water tiles in the fort box; increase > 0 → critical warning "Wasser im Fort bei (x,y,z)" (water in the fort at) and proposal of an emergency wall (quickfort grid `r5_notwand.csv`, cursor at the narrowest corridor before the front).
4. **Emergency wall runbook** `rb21_flut`: wall construction between front and fort, measurement after 60 ticks, dig ban in the region.
5. **Restricted boxes** (`water.forbid_dig`): `lint` refuses dig designations in them (e.g. x ≥ 127, y 97–101, z 127–129 and x = 180).

## Configuration
`water: {watch_box: [60,40,126, 190,130,131], fort_box: [60,40,126, 140,130,133], forbid_dig: [[127,97,127, 181,101,129]], notwand_blueprint: r5_notwand.csv}`

## Fair Play
The emergency wall is a normal build order. No liquid manipulation via script.

## Acceptance Criteria
1. Test "diagonal access": `check` reports `verboten`, even if the orthogonal neighbors are rock.
2. Replay "flooding 40 tiles": watchdog reports critical, runbook proposes the emergency wall at the right place.
3. `lint` refuses designation in the restricted box (positive/negative case).
4. Water scan on the Run 5 map: 0 tiles in the fort (baseline), > 0 in the tunnel fixture.

## Fixtures/Tests
Tile excerpts (`flow_size`, `liquid_type`) at the tunnel end before/after the test, `r5_notwand.csv`, `LAYOUT-run5.md` section 11.
