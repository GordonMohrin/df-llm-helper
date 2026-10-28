# BUG-125 the seal demand blocks every other build, including a hospital, coffins and tombs, food and drink
Status: fixed (offline, live-untested)
Severity: high (life before the refuge: a dying fort could not build its hospital)
Found: 2026-10-28, Run 14 (y710), game session note 102 and its Nachtrag
Module: dfpilot/plan.py (refuge_gate, LIFE_TPLS)

## Actual
`refuge_gate` counted every new build that is not a refuge fix as an "other new build" the seal must precede: with an open stair head the
plan was refused (ERROR) for adding a hospital, tombs, a farm, a stockroom or a cistern.

## Fix
`plan.LIFE_TPLS` (hospital, tombs, farms, stockroom, cistern, refuge_drink) are not "other new builds": they never hold the seal
demand back and are not held back by it. A real exposed refuge (an open stair with a revealed head tile that lacks a hatch) is still
demanded first for every other build (dining, temple, ...), and at phase_target P3+ as before. Tests: `tests/test_refuge_stair_102.py`.

Related: BUG-031, BUG-049, BUG-047, note 101 (TIMELINE_RESET), BUG-123, BUG-124, BUG-125
