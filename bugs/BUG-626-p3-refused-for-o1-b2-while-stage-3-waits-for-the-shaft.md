# BUG-626 P3 and P5 plans refused for O1 and B2 in a fort whose stage 3 waits for the aqshaft (BUG-523 undone by round 39)
Status: fixed (offline, live-untested)
Severity: high (the fort sat on P2 and a pop ceiling of 29)
Found: 2026-11-09, Run 16a i1 Basementflew y455-y456 (after round 39, main ef3a291: `plan check` ERROR "needs O1, B2 and the refuge" for P3 and P5, only P2 applied; before it, round 35-38, P5 was accepted)
Module: `dfpilot/plan.py` (`stage3_gate`, `stage3_waits`, `surface_facts`)

## Actual
`plan propose` drew P5, `plan check` refused it (and P3, P4) with "stage 3: phase_target P5 (P3+) needs O1, B2 and the refuge standing or being built first ... add fortcore stage 3 as the first build". The fort has a core (stages 1 and 2) whose stage 3 lies under aquifer z114-z127.

## Root cause
BUG-523/551 let the gate off (`plan.py no_core_why`) while `fort.surface.aq_late.ok` was False: no `aqshaft` column ranked, so no stage 3 could ever be dug. Round 39 (BUG-602, `cmd._aq_open_sites`) made `bp sites aqshaft` rank open-ground columns: `aq_late.ok` became True, `no_core_why` went quiet and the gate asked for the stage 3 again (y455); once the shaft was placed (y455s1b0, stalled at z125), `aquifer_late` returns None ("a shaft is under way: its pass is awaited") and the gate stayed on its ERROR. The stage 3 itself cannot be in the plan: it waits for the PASSED shaft (`p.aquifer=pass`, and `fit_core` drops it while other projects touch its tiles). Reproduced offline on a copy of the Basementflew save folder: the draft of `plan propose` for P5 carried the ERROR with the round 39 code, and with the code of d43f91e on the same folder (the placed shaft is the trigger).

## Fix
- `surface_facts` sets `aq_wait` (`{live}`) when an aqshaft is placed and not passed (`aq_shafts`: under way, or its bottom unknown) in a fort with a fortcore or an aqshaft applied.
- `stage3_gate`: when the plan holds no stage 3 build and `stage3_waits` finds the reason (`surface.aq_wait`, or `surface.aq_late.ok` with an `aqshaft` among the plan's new builds) the gate is a WARNING that names the shaft ("is not held for O1 and B2 until the shaft passed"), like the BUG-523 branch. A plan with a stage 3 keeps the ordering check; a fort that can dig stage 3 now (no shaft in the way) keeps the ERROR.

## Tests
`tests/test_bug626_628_f40_plan.py` (5 for BUG-626: placed shaft, drafted shaft, forts that stay held, `surface_facts` aq_wait, a fort with an aqshaft but no fortcore applied)

## Live check
In Basementflew: `plan propose` at P5, `plan check` shows `warn stage 3: O1, B2 do not stand and fortcore stage 3 waits for the aqshaft ...` and no ERROR; the plan applies. After the shaft passed, the next draft carries fortcore stage 3 again.
