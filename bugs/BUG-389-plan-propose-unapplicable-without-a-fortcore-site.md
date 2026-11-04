# BUG-389 plan propose: fortcore with 0 sites + ERROR refuge, hand-built empty P1 plans for 11 years
Status: fixed (offline, live-untested)
Severity: high
Found: 2026-11-04, Run 16a (i1 y376 `runs/run-16a/FR-BUGS.md` line 26), Run 16b (i2), main bb87afb
Module: `dfpilot/plan.py`

## Actual
`plan propose` y376 draws a P5 draft with fortcore (0 sites) and `ERROR refuge`; no fallback. The players set `phase_target P1` and empty builds by
hand (plan-y376b.json) and applied that for 11 years while nothing was built.

## Root cause
`propose` (dfpilot/plan.py) drafts the phase deliverables (fortcore stages 1-4, the stage 3 refuge) whatever `bp sites fortcore` says; `fort_facts`
knew no "no fortcore can be built" state (only a stopped core that cannot move, `core_gate`), and the refuge/stage-3 gates (`refuge_gate`,
`stage3_gate`) demand `fortcore stage 3` (O1, B2) at P3+.

## Fix
- `fort.surface` (`surface_facts`): `need` when no fortcore (depth 3, 2, 1) ranks, the best one has a known aquifer within 3 levels under its anchor
  (`sites.surface_core_why`), or a fortcore stopped on a breach cannot move; `have` when a surfacecore project is placed or in the manifest; `site`/`p`:
  a block for the default or the smallest compound (`w=20 h=12`) is free.
- `propose` (`surface_core_swap`): with `need` every fortcore build leaves the draft (and the stone-dig bedrooms), `surfacecore@S1` comes first (the
  refuge is in it; not when placed already or when no block is free, the note says so), dining/bedrooms/tavern/office/hospital get `p.surface=1`, rooms
  that dig rock (tombs, furnaces, temple, captives, hall, guildhall, barracks, stockroom, refuge_beds/drink, explore) are left out with a note; the
  BUG-197 "only fortcore stage 1" branch is skipped. A draft that places: every build finds its site (tested with `place_all`).
- Gates: `_refuge_stage` counts `surfacecore` (the refuge is in it), `stage3_gate` is silent with a surface core (no O1/B2), `core_order_note` names no
  Z4 order for it, `_has_z4` ignores the surface core's Z4 (the surface hospital stays offered).

## Open
Phase deliverables for fortcore stage 3/4 are replaced in the draft only; the kernel's own phase waits (`phw`: squads, drill, ready) are not changed.
`refuge_beds`/`refuge_drink` need a dug refuge room: the surface refuge has its beds in the template. Dug tombs have no replacement (corpses pile up).

## Tests
tests/test_bug387_389_surface_core.py (propose, gates, facts).

## Live check
i1-like: `plan propose` shows `BUG-387/389: no fortcore can be dug` and `surfacecore@S1`; `plan check` 0 errors; `plan apply` writes the bp files; the plan is
applicable without hand editing.
