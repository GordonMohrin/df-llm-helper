# BUG-587 A raise waits for people beside the bridge while the hostile arrives (bounded hold)
Status: fixed (offline, live-untested)
Severity: high (the bridges of a siege stayed down 2268 and 2800 ticks while two cave dragons and a goblin army came from 61 tiles to 0; Pop 61 -> 1)
Found: 2026-11-09, Run 16c i3 Sealcertain y422 summer (`runs/run-16c/FR-BUGS.md`, `E:/DF-test3/dfllm-runtime/r16c4-sealcertain-site97/` kern.log + events #10520-#10571 read only): SIEGE at tick 170303794, `gate: B1 up still waits for citizen ... walking onto it in 1-13 steps` every 25 ticks, B1 up at 170306062 (+2268), B2 at 170306626 (+2832); the hostile was 30 tiles from B2 after +1450, 10 from B1 after +1750, 0 at +2040 (STRANDED / GATE_FORCED `force_near 3` only then)
Module: `lua/dfllm/gate.lua` (`holders`, new `approach_cfg`, `closing`, `approach_range`, `forced_event`), `lua/dfllm/siege.lua` (`citizen_held`), `config/reflex.json`, `dfpilot/fairplay.py`

## Actual
In SIEGE / BREACH a raise goes ahead past units next to the footprint only with a hostile within `gate.force_near` (3) tiles. The recall of 27 citizens at the alert streamed over B1 and B2: every pass of the gate found a unit beside the footprint or walking onto it (`M.crossers`, the BUG-492 walkers who hold to the end), so the pull was cancelled again and again until the hostile stood at the gate. BUG-543's mover hold (non-emergency raises) had the same shape in ALERT / RECOVERY. BUG-577 then excused the bridge as `held for a citizen` for 1800 ticks even with a dragon 4-10 tiles away.

## Root cause
`gate.lua` `holders` (the SIEGE/BREACH branch): the only way past a hold for people BESIDE the footprint was the 3-tile `force_near`, which is the moment the hostile is already on the bridge. Nothing bounded the wait while a hostile approached. The `raise_movers` call in `holders` and `siege.lua` `citizen_held` (hostile within `force_near` only) followed the same rule.

## Fix
- `gate.holders`: a raise in SIEGE/BREACH that has been held `gate.approach_hold` (300) ticks is forced like a raise with a hostile at the gate when a visible hostile is within `gate.approach_close` (12) tiles of the footprint, or within `gate.approach_near` (30) tiles and CLOSING (4 tiles nearer than 150-900 ticks ago, samples every 30 ticks, `closing`). Only a unit ON the footprint (or its path's first step) still holds it (BUG-310 unchanged); the rest are let go and GATE_FORCED (A) names them (`... a hostile N tiles from it and closing, held H ticks (approach_near 30)`). A parked army (BUG-492: 25 tiles out, not moving) is no approach. `force_near` 0 ("never raise onto a unit") still switches all of it off.
- ALERT / RECOVERY raises: with a hostile within the larger of the two radii nobody waits for MOVERS (`raise_movers`, BUG-543) any more; units beside the footprint and walkers onto it still hold.
- `siege.citizen_held`: a hold older than `approach_hold` with a hostile within `approach_close` is no excuse (the bridge is being forced up).
- Config `gate.approach_near` 0-80 (30), `gate.approach_hold` 0-3000 (300), `gate.approach_close` 0-80 (12) in `config/reflex.json`; `python -m dfpilot.lint --config` checks them; 0 turns the matching rule off.

## Tests
`tests/lua/test_bug587_siege_hold.lua` (5, the siege traffic test): a hostile closing in from 88 tiles and two citizens beside B1: B1 up after approach_hold and before the hostile is within 12, nobody crushed, GATE_FORCED names them; a parked hostile 25 tiles out: B1 stays down; a citizen ON the footprint: never raised onto him, raised right after he leaves; a stream over O1/B1/B2 plus standers: nobody crushed, O1 and B1 up in time; config fallback and the switch-off. `tests/lua/test_bug577_580_audit_siege.lua` (1)/(2) adapted (the hold for a citizen beside B1 is bounded by a hostile 8 tiles out; a far army keeps the old hold), `tests/test_bug587_589_f38.py`.

## Live check
GATE_FORCED with `approach_near`, B1/B2 `up` before the first STRANDED at 0 tiles; no `crushed` DEATH on a bridge in a siege; kern.log `gate: B1 raise held ... only units on the footprint ...` followed by the raise.
Open: citizens already on the far side of a bridge raised this way stay shut out (the siege's CUT rule, BUG-028, accepts that with a hostile near); recalling or re-stationing the people who mill beside a footprint (forbidding the approach) is not done - there is no safe DF mechanism for it (BUG-335); B2 is bounded by its own hostile distance (a stream over B2 with the hostile 26 tiles out and not closing keeps its hold).
