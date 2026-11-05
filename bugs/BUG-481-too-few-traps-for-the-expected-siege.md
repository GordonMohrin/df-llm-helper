# BUG-481 Nine traps against 34 goblins and five trolls; 38 listed traps with no mechanism to arm them
Status: fixed (offline, live-untested); open: the shortfall is reported and holds growth, the mechanisms come from the economy / caravans (no new trap kind)
Severity: high (Castletongs, Syrupobeyed: the traps never mattered)
Found: 2026-11-05, Run 16c i3 Castletongs y403 (audit "8 traps min", state traps n 28), Run 16a i1 Syrupobeyed y378-y387 (38 traps, levers and traps without mechanisms)
Module: `lua/dfllm/readiness.lua` (`trap_target`, `trap_shortfall`), `lua/dfllm/siege.lua` (`history`), `dfpilot/plan.py` (`defense_gaps`)

## Actual
Readiness asked 30 armed traps only at R2 and treated fewer as a blocker of nothing: `traps<30` held nothing, and the audit's number (the fewest armed traps on an attacker path) was 8 at a pop of 100 that drew 34 goblins and 5 trolls. In Syrupobeyed 38 traps were listed but the mechanisms (hard stone) did not exist, so they were never armed.

## Root cause
No relation between the traps and the siege the fort draws; R2's fixed 30 is not a growth gate (BUG-377 only held growth at 0 traps).

## Fix
- `readiness.trap_target(K, cit)`: expected army = max(largest army its sieges met (`siege.history.peak`), 0.35 x citizens); target = ceil(expected / `DEF.per_invader` (2)) + 4, clamped to `DEF.traps_floor` (20) .. `DEF.traps_cap` (40). Castletongs: 35 -> 22, Syrupobeyed (peak 40) -> 24.
- From `DEF.trap_pop` (40) citizens: fewer armed traps than the target (the audit's `min_traps` and, when known, the armed traps in all) -> R0 blocker `traps_short`, `ready.ts` ("traps short: 8 armed on the weakest path < 29 for ~50 invaders (largest army 50); N listed tiles lack a trap: a mechanism each (trade.want mechanism, hard stone)") and `ready.tt`, in SIEGE_UNREADY. A shortfall older than `DEF.grace_days` (20) in a fort of `DEF.hold_pop` (30) citizens or more holds max-pop where it stands (ceiling why `defense_short`), lifted when the traps stand.
- `plan.defense_gaps`: gap `traps short N<T` from `ready.tt` -> the existing BUG-377 rules draft the trap hall / traps builds first and hold the plan's population (`defense_cap`).
- Mechanisms: the listed tiles without a trap (`traps.need`) are economy's mechanism demand (ConstructMechanisms in hard stone, `trade.want mechanism` when there is none); the text says so. Cage traps and weapon traps also need a mechanism in DF, so there is no mechanism-free alternative to offer.

## Tests
`tests/lua/test_bug478_481_defense_ready.lua` (blocker, target 29 for peak 50, state, hold after the grace days, lifted with 40 traps; no history -> 0.35 x pop, clamp 20..40; a fort of 30 asks nothing; siege.history persisted), `tests/test_bug478_481_f30.py` (plan gap `traps short`, schema).

## Live check
`status` of a fort with 100 citizens and 8 armed traps: R0 `traps_short`, `ready.ts`; the plan puts the trap hall first; after 20 days max-pop holds at the population.
