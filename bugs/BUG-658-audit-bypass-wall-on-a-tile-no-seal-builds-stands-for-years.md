# BUG-658 An audit bypass wall on a tile no seal can be built on stands in every audit for years
Status: fixed (offline, live-untested)
Severity: medium (R0 `bypass` / audit_fail for years, `seal at=audit` 'nothing to close', `plan check` text 'seal project  builds the wall' with no project)
Found: 2026-11-10, Run 16d i4 Trumpetrealms y437-y441 (`bypass: wall 89,100,139 floor -> 88,101,139` in 14 audits from tick 176865457 to 177686319, no seal project ever touched the tile), Run 16a i1 Basementflew y414-y441 (`bypass: wall 98,89,129 floor (+more) -> 97,85,129` after 28 finished seals; a door stands there where a wall cut citizens off)
Module: `dfpilot/bp/topo.py` (`choke_pick`, `choke`, `audit`), `dfpilot/cmd.py` (`audit_avoid`, `audit_routes`), `dfpilot/wake.py` (`compute_audit`), `dfpilot/plan.py` (`audit_gate`)

## Actual
The audit names the same wall tile in every run; the follow wake and `plan propose` have nothing to build (`audit_routes` puts the tile in `core` / `built` / `doored`), `seal at=audit` answers 'nothing to close (left out (a fortcore tile, the fort's own way): 89,100,139 (y372s0b0))', and `plan check` warned 'seal project  builds the wall; dfllm audit once it stands' (empty project list) for the fortcore case. Replayed from the Trumpetrealms events (cut at the audit of tick 177668979, a copy of the save folder): `core = {'89,100,139 floor wall': 'y372s0b0'}`, `open = []`.

## Root cause
`topo.choke_pick` (topo.py ~280) picks the wall tile from the route alone: the foreign tiles of the route walking back from the target, the first floor/ramp tile that closes it (fallback: any tile, the fort's own included). It knows nothing of the projects: a tile of a fortcore project (the fort's own corridor, never walled: BUG-211) or the tile of a seal that finished (a door that stands because the wall cut citizens off: BUG-487; a wall the audit reads again: BUG-579) is picked again and again, while `cmd.audit_routes` refuses to build there. Nothing moves the finding to another tile of the same route. `plan.audit_gate` had no branch for the fortcore tile and fell through to the `pending` text with an empty id list.

## Fix
- `topo.audit(..., avoid=None)` -> `choke(.., avoid)` -> `choke_pick(.., avoid)`: tiles in `avoid` ((x,y,z) set) are skipped as wall candidates of the FINDING; the next closable tile of the route is named, else `bypass: via ...` / the plain route text. The `min_traps` walk (the walls assumed built) is unchanged, so the trap count does not drop.
- `cmd.audit_avoid(save_dir, tick)`: `core_cells` (every fortcore project footprint) plus the tiles of seal projects finished `WALL_BUILT_LAG` before the snapshot (the rule of `audit_routes` `built`). `wake.compute_audit` passes it (when `audit` takes `avoid`).
- `plan.audit_gate`: a `core` wall with nothing pending says the wall lies on fortcore <id> (the fort's own way), no seal is built there, the next audit names another tile or none.

## Tests
`tests/test_bug657_658_f43_seal.py` (the audit names the next tile; every tile avoided: no wall, the route finding stays; `audit_avoid` holds the core footprint and a finished seal only after the lag; `audit_gate` names the fortcore). Replay of the Basementflew snapshot (`s188038439-13`, manifest of the save): before `wall 98,89,129 floor (+more)`, after `wall 97,90,129 floor (+more)` with 351 tiles avoided.

## Live check
After the next audit: no `bypass: wall` on a fortcore or finished-seal tile; the status audit route names another tile (or `bypass: via ...`), `seal at=audit` places it or says 'nothing to close' only when the route has no tile left; `plan check` no longer prints 'seal project  builds the wall'.

## Residual risk
A route whose only closable tiles are all avoided now reads 'no wall tile on the route' (R0 `bypass` stays until the fort changes); a finished seal whose wall was destroyed later is not named by the audit (the entrance check / SEAL_LEAK still opens it). The Basementflew route is `(+more)`: one wall never closes all of it, each audit names the next one.
