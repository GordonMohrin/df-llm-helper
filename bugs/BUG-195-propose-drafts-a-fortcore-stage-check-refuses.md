# BUG-195 `plan propose` drafts fortcore@same stage 2 that `plan check` refuses ("overlaps project(s) y721s3b2")
Status: fixed (offline, live-untested)
Severity: high (the draft of the core's missing stage can never be applied; a weak model reports and the fort keeps no plan)
Found: 2026-10-29, live test round 3, Trussroads y728 (finding BUG-162..164-live, skeptic re-check); also Earthboat (F5, second propose)
Module: `dfpilot/plan.py` (new `fit_core`, `run`, `auto_plan`), `dfpilot/cmd.py` (`place`, `Occupancy.own_cells`)

## Actual
propose added the phase deliverable fortcore stage 2 @same from the `done` set only. `cmd.place` (label same) clashed with
every project but fortcore's own: refuge_beds y721s3b2 (placed by the y721 minimal plan, opened off the core's refuge room)
blocked it. On Earthboat the later stage clashed with the audit seal wall c1a185ed14e27ebd07 that stands on a stage-1 tile.

## Fix
`Occupancy.add` keeps each project's tpl, anchor, footprint and own cells; `own_cells(tpl, anchor)` = the tiles the placed
stages of that core dig. `place` (same, and the A label of an own later stage) checks only the footprint minus those tiles:
a seal wall or a doorway on the core's own dug tiles is no new ground. `plan.fit_core` dry-places each new fortcore
stage >= 2 @same as `place_all` would (skipped when stage 1 is new in the plan); a blocked stage and its later stages are left
out, a line and the notes name the blocker and `dfllm cmd bp.cancel proj=<id>`. Called by `plan propose` and `auto_plan`.
The FR-86 minimal plan cannot put refuge_beds inside an unbuilt stage: the stage-1 project reserves the later stages
(`footprint`), so refuge_beds can only touch them next to its own anchor, and that touch no longer blocks the core (BUG-196).

## Tests
`tests/test_bug195_198_plan_place.py` (`test_same_stage_ignores_tiles_its_own_placed_stages_dig`,
`test_propose_leaves_a_blocked_core_stage_out_and_names_the_cancel`), fail on bd27973.

## Live check
Trussroads (port 5000): `python -m dfpilot plan propose <scratch>/p.json`, then `python -m dfpilot plan check <scratch>/p.json`:
either check is OK with fortcore@same stage 2 placed, or propose printed `fortcore stage 2 @same left out: ... dfllm cmd
bp.cancel proj=<id>` and the draft has no stage 2. Never a silent propose that check rejects with "fortcore@same ... overlaps".
