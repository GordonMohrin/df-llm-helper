# BUG-551 Every P3+ plan is refused for O1, B2 and the refuge when the core stands but its stage 3 lies under an aquifer with no route
Status: fixed (offline, live-untested)
Severity: high (the fort stays on P2 with a pop ceiling of 29 for years)
Found: 2026-11-06, Run 16a i1 Basementflew y408-y415 (`runs/run-16a/FR-BUGS.md` "plan check y408: P3+ verlangt fortcore st3", "OBS Runde 33 y415 Winter: BUG-523 wirkt hier NICHT"; i1 folder read only)
Module: `dfpilot/plan.py` (`no_core_why`, `stage3_gate`, `stage3_due`, `refuge_drafts`)

## Actual
Aquifer z114-z127 (heavy z125, z123, z120, z116), stone 0. `plan check` on the fort's plan with phase_target P3 / P4 / P5: ERROR `stage 3: phase_target P3 (P3+) needs O1, B2 and the refuge standing or being built first ... add fortcore stage 3 as the first build`. Only P2 passed. Reproduced offline on the i1 end state (`plan.check` with `fort_facts`): P3 had that one error, P4 and P5 that and a legitimate seal demand.

## Root cause
BUG-523 gave a fort with NO core a way forward (`no_core_why`: no ranked site, no aquifer route / surface core site). i1 has a core (fortcore stage 2 applied, `fort.core_any`), so `surface_facts` returns at once (`need` False) and `no_core_why` was ''. What cannot be built there is stage 3 (the refuge, O1 and B2 lie under the aquifer): `surface_facts.aq_late` (BUG-429: the remaining stages meet known aquifer levels; `ok` False = `bp sites aqshaft` ranks no free column, which BUG-549's holders caused) says so, but nothing read it for the gate. `propose` drafted `fortcore@same stage 3` all the same.

## Fix
`no_core_why`: when there is no `have` / `need` case, a core that is not stopped on a breach (`fort.core` None) with no stage 3 under way (`fort.refuge.stage3` False) and `surface.aq_late` with `ok` False returns "the core's stage 3 meets the aquifer (z127, z126, ...) and no aqshaft column is free: <why>". `stage3_gate` then takes its existing BUG-523 branch: no error for O1 and B2, a warning that says what the plan requires instead (separated refuge with beds, the seal on every way in, from P5 the drill) and that O1 and B2 are asked for again once a core route exists. `stage3_due` and `refuge_drafts` draw no `fortcore stage 3` while that reason holds. When a column is free (`aq_late.ok`) the gate and the draft are as before.

## Tests
`tests/test_bug549_553_f35.py`: `no_core_why` (the reason; empty with a route, with stage 3 under way, with a stopped core, with a surface core); `stage3_gate` P4 warns, and refuses once a column is free; `stage3_due` / `refuge_drafts` draw nothing, and the stage as before.

## Live check
`plan check` with phase_target P3..P5 on a fort in that state: no `needs O1, B2` error, WARN `stage 3: ... no fortcore can be built (the core's stage 3 meets the aquifer ...)`; the other gates (audit seal, refuge beds) still apply. The pop ceiling follows the phase target and the defence caps as before.
Open: no explicit "no core" decision is stored; the way back is the existing aquifer fact (a free aqshaft column brings the gate back). The refuge itself is still not built in such a fort (refuge_beds waits for a refuge room).
