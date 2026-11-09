# BUG-579 `seal at=audit` is drafted every year and the audit names the same bypass tile
Status: fixed (offline, live-untested); open: the audit counts a seal-built hatch or door open
Severity: high (R0 `bypass` for years, the pop ceiling held, the same seal planned and built yearly)
Found: 2026-11-06, Run 16a i1 Basementflew y414-y430 (`SIEGE_UNREADY ... bypass: wall 98,89,129 floor (+more) -> 97,85,129`, seal projects y414s0b0 ... y430s0b0; kern.log `y430s0b0 (seal): nothing built: Slab 98,89,129 (a door wanted)`, `memorial: slab 1682729 ... placed at 98,89,129`) and Run 16c i3 Sealcertain y390-y406 (`bypass: via door 54,132,137 -> 55,132,137` after the hatch seal on the stair head; `runs/run-16a/FR-BUGS.md`, `runs/run-16c/FR-BUGS.md`; DF runtime folders read only)
Module: `lua/dfllm/care.lua` (`MEM.grid`), `lua/dfllm/readiness.lua` (new `route_tiles`), `dfpilot/cmd.py` (`audit_routes`, new `seal_occupied`), `dfpilot/plan.py` (`audit_gate`)

## Actual
i1: the tile 98,89,129 (the bypass wall, also a corridor next to the crypt) held a memorial Slab care had placed in a free 3x3 (y418). The wall there was refused (`would cut 11-43 off`), the door seal (`close=door`) could not stand on the slab (BUG-565: blocked `occupied`, before it "done" at 100 % with nothing built). `audit_routes` called such a project `pending` (it never finishes) or, when it was done before the audit, `open` again, so `plan propose` and follow drafted the same `seal at=audit` every year. i3: the hatch the seal built on the stair head counts as a door the audit treats as open; the route `via door 54,132,137` stayed and `route_advice` asked for a removal by hand.

## Root cause
1. `care.lua` `MEM.grid`: the memorial search keeps off buildings, zones, entrances and non-free floor, not off the tile the audit's route names, so a slab could take the one tile a seal needs (the occupant is a Passable building: the snapshot reads floor, the audit keeps naming it).
2. `cmd.audit_routes` (the `open_` / `pending` classification): a seal project that finished before the audit and whose tile the audit still names went to `open` (redrafted: `plan.audit_gate`, `plan.propose`, `wake._request_seal`); one blocked `occupied` stayed `pending` for ever; a route over a hatch / door the finished seal built got the BUG-376 advice (take it out by hand) instead of the truth.

## Fix
- `readiness.route_tiles()`: the tiles the last audit's route findings name; care's `MEM.grid` marks them taken (a slab neither on them nor in the 3x3 around them).
- `cmd.audit_routes`: `built` (finished a snapshot lag, `WALL_BUILT_LAG` 1200, before the audit that names the tile again), `jammed` (`seal_occupied`: PROJECT_BLOCKED `occupied` names a building on the tile, cleared by a later PROJECT_DONE of a seal there), `via_built` (a `via door|stair x,y,z` route over a hatch or door of a finished seal). None is `open`: not drafted, not placed by follow. `plan.audit_gate` warns with the cause instead (`seal X finished ... not redrafted`, `holds a Slab: take that building away by hand or accept the route`, `the hatch piece of seal X stands ... the audit counts a door or hatch open (worst case)`).

## Tests
`tests/test_bug577_580_f37.py` (built / within the lag / pending / jammed and cleared / via_built and the old advice kept without a seal), `tests/lua/test_care_ghosts.lua` (no slab on or beside the route tile), `tests/lua/test_readiness.lua` (`route_tiles`).

## Live check
`plan check` prints `audit: ... not redrafted` once instead of an ERROR or a yearly seal; no memorial slab on a route tile; follow's `auto:seal` line stops repeating.
Open: the audit still counts every door and hatch open (worst case, DESIGN), so a seal-built hatch never closes `bypass` by itself; this bug stops the yearly rebuild and says why. A slab already standing on a route tile has to be removed by hand.
