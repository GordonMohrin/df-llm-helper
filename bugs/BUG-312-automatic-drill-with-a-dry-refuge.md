# BUG-312 Automatic drills started while the refuge and the kern burrow had no drink
Status: fixed (offline, live-untested)
Severity: medium (every drill failed, STRANDED and GATE_CRUSH_RISK at each one, wake noise)
Found: 2026-10-29, Run 15d Drillchamber (y376-y378), fix11-gate-crush
Module: `lua/dfllm/drill.lua` (`check`, `M.dry_hold`), `lua/dfllm/seal.lua` (`M.refuge_drink`)

## Actual
`PEACE>DRILL drill: auto: retry` three times (#2318, #2484, #2621), each with REFUGE_FAIL `Kern+: drink 0<38 (3 wells, none wet)`
at the start, STRANDED #2180 `B1, O1 held: it would cut 11 citizens off from drink or food`, `drill failed: raised -1` and
GATE_CRUSH_RISK #2332/#2664 at the drill's bridge moves; readiness listed refuge_dry for years. Root cause: drill.lua `check`
(lines 433-468 on 9ef2ccb) held automatic drills for danger, settling, supply (BUG-294), bridges and levers, never for a refuge or
alert burrow without drink.

## Fix
`drill.dry_hold`: no automatic drill while `readiness.refuge_dry` is set ('refuge dry') or seal's audit finds the kern burrow (the
drill's alert burrow) below its drink need without a wet well ('Kern+ dry'; `seal.refuge_drink(K, 'kern')`). The hold shows as
state ready.dhold / status; the player's `drill` stays his choice.

## Tests
`tests/lua/test_fix11_drill_dry.lua` (both fail on 9ef2ccb).

## Live check
Drillchamber: `dfllm status` shows `drill never (auto: refuge dry)` or `Kern+ dry`; no `auto: retry` MODE event and no REFUGE_FAIL
in DRILL until the refuge has drink.
