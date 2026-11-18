# BUG-777 the cavern sweep opens a shaft nobody can close
Status: fixed (offline, live-untested)
Severity: high
Found: 2026-11-11, Run 16d i4 Pagedsculpture y416-y417 (FR-BUGS 'BUG Cavern-Sweep', 'BUG Cavern-Schacht 131,122,137')
Module: `lua/dfllm/cavern.lua`, `lua/dfllm/runner.lua` (sweep_open, sweep_close)

## Actual
P6 turned `caverns.sweep` on; at squad A worn 81 % the sweep opened shaft 131,122,137 (`us167825009`). The u0.stair stage ('Construction
131,122,137: no builder took it ... 2 idle holders reach it') stood 30 days; the shaft top wall was already gone and the plug had no lower
wall (`no wall below it (not done within 1 day)`), so the cavern was joined to the fort. A siege closed the sweep: `plug pl167898198`
`quickfort refused p0.wall` -> `plug_refused` / `seal_failed`, 'the shaft is NOT walled'. The player placed a seal hatch (`c1a1cc2889ec`),
which stood 120+ days without a builder (the hatch at 95,94,141 had waited 7900 days before, BUG-313); troglodyte 28375 came through
(BREACH, killed by sortie A).

## Root cause
1. `runner.sweep_open` (runner.lua, was :7909) took the top wall away first without asking whether the shaft could be closed again:
   no lower wall (`s1` missing or given up), no builder with the hatch labor idle on the shaft's walk group, no stone/wood, a top walled
   in on its level. A shaft with no lower wall stands open the moment the top wall goes.
2. `runner.sweep_close` cancels the unplug project, but the cancel is queued (`R.rm`, removal later in the project's own turn) and the
   plug was registered at once. The snapshot does not see a PLANNED building (`snapshot.classify`: occupancy Planned keeps the floor
   char, bld ''), so `Q.sw_keys` read the top as bare floor, planned only `Cw`, and quickfort refused the wall on the tile where the
   unplug's planned stair still stood (`build_unsuitable` -> `plug_refused`). Nobody retried it.
3. `cavern.run_step` phase `open` waited for the unplug project up to `open_max` (four months) when it was only 'stalled', and watched no
   cavern beast while the shaft stood open.

## Fix
- `Q.sweep_ready` (runner.lua): `sweep_open` answers `not closable: <why>` and designates nothing unless a lower wall stands under the
  top, a tile beside the top is standable (`economy.boxed_in`), at least 4 free stone/wood items exist, `economy.hands` finds an idle
  holder of the hatch labor on the top's walk group, and no other cavern record stands `failed` / `sweep`. Unreadable parts (no economy,
  no census) do not hold it back. `cavern` shows it as `open refused: not closable ...` and waits.
- `Q.sw_unplan` (runner.lua): `sweep_close` first takes the planned (unbuilt) stair / hatch on the shaft tiles back (quickfort undo, as
  the player's remove building on a planned one) and answers `pending: ...` while one still stands; `cavern.to_close` asks again every
  look (`close_retry` 20) before it ends as seal_failed.
- `cavern.run_step` phase `open`: a beast that was not in sight at the start, or any beast within `near_shaft` (3) tiles of the shaft
  column closes the shaft at once (why `hostile`); an unplug project with no progress for `open_stall` (6 days) closes it (why `stalled`).
  SIEGE / BREACH already did.

## Not found
Why the player's seal hatch at 131,122,137 got no builder is not proven offline: the tile had west floor (not boxed), 7 holders were busy
(PlantSeeds), and Pagedsculpture also had other untaken ConstructBuilding jobs (140,114,140; 141,108,140), so a fort-wide builder problem
(BUG-747/768 territory) is likely; a planned stair left on the tile (cause 2) also blocks a hatch. The sweep no longer creates this case.

## Tests
`tests/lua/test_bug777_sweep_closable.lua` (6: refusals for busy / far / no-labor builders, walled-in top, no lower wall; the planned
stair taken back so the plug wall is placed; pending), `tests/lua/test_fr98_cavern.lua` (4 BUG-777 cases: cavern invader, beast at the
shaft column, stall closes, pending plug asked again; the siege-while-opening case existed). Fail before the change.

## Live check
Pagedsculpture / any fort at P6: `inspect cavern` shows `open refused: not closable ...` until a builder is idle; a sweep that opens
ends with a hatch built, or `CAVERN_SWEEP_END why stalled|hostile` and CAVERN_PLUG done (no plug_refused).
