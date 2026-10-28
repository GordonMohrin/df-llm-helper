# BUG-132 The automatic minimal plan never raises a phase, and the plan and the state show cap 55 although D-01 = B set it to 100
Status: fixed (offline, live-untested)
Severity: high (the fort stands still for years while goal G2 is green; growth held at 55 against Gordon's decision)
Found: 2026-10-28, goal audit of Run 14 site90 (PLAN_AUTO y715: P0, 0 builds, pop_ceiling 55; status `cap 55 gate 55`)
Module: `dfpilot/plan.py` (`level_cap`, `propose`, `minimal_plan`), `dfpilot/wake.py` (`_check_plan`), `lua/dfllm/kern.lua` (`with_defaults`),
`lua/dfllm/readiness.lua` (`ceiling`)

## Actual
- (a) FR-86's minimal plan set `phase_target` to the current phase and kept only seal, tombs, hospital, food/drink and refuge builds. Follow applied it
  again only after `plan.stale_apply_years` (2) more years, each time at the same phase: site90 stayed in P0 with 0 builds, the plan was "applied" (G2
  green) and the runner never left P0.
- (b) Gordon answered D-01 = B and pop cap 100 (config/decisions.yaml, baseline popcap.max_pop 100, readiness.lua `M.CAPS` 100, RULES §8), but:
  - `plan.R_CAPS` stayed `{0: 55, 1: 55, 2: 75}`: `plan propose` and the minimal plan drafted `pop_ceiling` 55 at R0/R1 and `plan check` refused more;
    readiness takes min(level cap, plan ceiling), so `status` said `cap 55 gate 55`.
  - the kernel's default plan (no plan applied yet, kern.lua `with_defaults`) carried `option A, pop_ceiling 55`.
  - readiness R2 clamps to the siege trigger - 5 (75): with R0/R1 at 100, reaching R2 lowered the ceiling and froze max-pop.

## Fix
- (a) `plan.raise_due`: the applied plan is the minimal one, at least `RAISE_QUIET_Y` (1) game year old, PEACE, no SIEGE_START/SIEGE_END/BREACH or MODE to
  SIEGE/BREACH in the last game year. Then `auto_plan` drafts `propose(upto=next phase)` (never a star phase; all builds propose drafts: refuge,
  `seal at=audit`, fortcore stages, hospital, plus every `add {...}` repair the ERRORs name). ERRORs: an error-free subset of those builds at the next phase
  (drop the build whose removal leaves the fewest ERRORs, latest first, until none; builds that check only together stay), else the plain minimal plan; the full draft's ERRORs are `held` and the PLAN_AUTO line says `N ERROR held back: ...`.
  Follow (`_check_plan`) calls it after one quiet year under a minimal plan (else after the stale years as before), once per game year.
- (b) `plan.R_CAPS = {0: 100, 1: 100, 2: 100, 3: 250}` (D-01 = B, the kernel's table; a test pins Python = Lua = baseline popcap.max_pop) and
  `R_CAPS_A = {0: 55, 1: 55, 2: 75}` for D-01 = A; `with_defaults(plan, phases, decisions)` gives a fort without a plan `option B, pop_ceiling 100`
  (A: 55); readiness R2 ceiling = max(R1 cap, min(level cap, trigger - 5)).

## Effective cap after the fix (D-01 = B)
max-pop = min(readiness level cap 100 (R0..R2; R3 250), plan.policy.pop_ceiling, inbox `popcap.lower`, FR-70 hold), then: a ceiling below the last
applied cap holds at min(last cap, citizens) (the demotion freeze); outside PEACE it never rises; an open perimeter for `perimeter.escalate_days` (2)
with >= `hold_pop` (30) citizens holds it where it stands. A plan applied before this fix keeps its `pop_ceiling` 55 until the next apply (the next
automatic plan or `plan apply` writes 100). Not touched: drill.lua `R1_CAP` 55 is only the "plan wants growth" threshold for automatic R2 drills
(a ceiling of 100 now asks for them), not a cap; `config/allowlist.json` still allows `pop-control set max-pop 55` (a lowering).
