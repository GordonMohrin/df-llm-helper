# BUG-354 plan propose in year 1 demands farms, dining and bedrooms before the placed fortcore has dug anything
Status: fixed (offline, live-untested): while a placed fortcore's stage 1 digs and no Z4 floor exists, the draft is the seal
only. Open: a hand-made plan with rooms still gets the check's site ERROR (apply cannot place them)
Severity: medium
Found: 2026-11-04, Run 16c (i3, `runs/run-16c/FR-BUGS.md` "plan propose im Jahr 1 verlangt farms@S1 (ERROR no soil marks)"),
main 8890b59
Module: `dfpilot/plan.py` (propose, fort_facts, core_digging)

## Actual
Year 1, fortcore placed by `bp.place` (stage 1 at s1.dig, manifest without Z4): propose drafted farms@S1, dining, bedrooms
(and phase_target P3 with fortcore stage 3); `plan check` answered ERROR "farms: no soil marks in this snapshot" and "no
refuge"; the player applied an empty plan with P2. PLAYBOOK 3a: in year 1 the plan is fortcore stage 1 and the seal only.

## Root cause
plan.py propose (:2509 on): the BUG-197 reduction ("year 1 is the core's stage 1 and a seal only") applied only with no
fortcore project at all (`not core_any`, `not any(fortcore in done)`). A fortcore placed by `bp.place` makes `core_any` true,
so the full phase draft (rooms that open from the dug Z4 floor) went through while `z4` was still false.

## Fix
- plan.core_digging / fort_facts `core_dig`: a fortcore project (not retrofit, not on a breach) is at `s1.dig` in state.proj.
- propose: the reduction also holds while `core_dig` (z4 false, no breach core): only seal builds are kept, the fortcore
  stage 1 is not drafted again, phase_target stays; the notes say `BUG-354: fortcore stage 1 is still digging (no Z4 core
  floor yet): only the seal drafted, phase_target P0 ...; apply, wait for s1.dig, propose again`.

## Tests (fail on 8890b59)
tests/test_bug352_354_sitewg.py (2 BUG-354 tests).

## Live check
i3 / a new fort after `bp.place fortcore`: `plan propose` drafts the seal only (or an empty plan), no farms/dining/bedrooms
ERROR; after s1.dig the next propose is the usual draft.
