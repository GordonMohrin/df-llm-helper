# BUG-363 plan propose drafts rooms although the placed fortcore dug nothing (follow placed it before the plan)
Status: fixed (offline, live-untested): a placed stage 1 without a state row counts as digging. Open: stale entries of the applied plan
Severity: medium
Found: 2026-11-04, Run 16b (i2, y372, `runs/run-16b/FR-BUGS.md`), main 595364a
Module: `dfpilot/plan.py` (core_digging)

## Actual
i2 y372: `follow` placed the fortcore (cli.log 1793798199 `follow verb:bp.place fortcore S1`) before the player's plan; the
draft then had office/farms/dining and `plan check` answered ERROR "0 free sites". The report also read "the proposer
places the fortcore": `plan propose` places nothing (it writes the draft file and dry-runs `place_all`); the placement was
follow's, answering the kernel's PROJECT_REQUEST. Not changed (kernel/follow design, gate.lua/bridge untouched).

## Root cause
plan.py `core_digging` (BUG-354) looked for a state.proj row labelled `s1.dig`. state.proj carries 8 rows at most
(schema `proj` hi=8; the runner sorts parked projects last), a project just placed has no row yet, and a queued one may
sit beyond them: core_dig false, z4 false, core_any true -> the BUG-197/354 reduction (seal and stage 1 only) was skipped
and the full phase draft went through.

## Fix
`core_digging`: any non-retrofit fortcore stage 1 bp file without a PROJECT_DONE counts as digging unless its state row says
it is past the dig (`s1.build`, later stages) or on a breach. A fortcore that was never placed (or cancelled: no bp file)
was already reduced by BUG-197; `propose` is shown to leave bp/ untouched.

## Open
A same-year applied plan keeps its builds at their indices (stable_ids): entries of a cancelled fortcore (`fortcore@same
st3`) stay in the draft; count the year up (or bp.cancel and a new year) as Run 16b did. Not changed.

## Tests
tests/test_bug363_propose_core.py (2; the first fails on 595364a), tests/test_bug352_354_sitewg.py (adjusted).

## Live check
i2-like: follow places the fortcore, then `plan propose`: seal only, notes `BUG-354: ... still digging`, no ERROR "0 free sites".
