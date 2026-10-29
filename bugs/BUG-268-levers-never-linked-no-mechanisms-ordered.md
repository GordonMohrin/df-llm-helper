# BUG-268 Levers B2/O1 never linked: nobody counts or orders mechanisms
Status: fixed (offline, live-untested)
Severity: high (no lever: the gate cannot close, the STRANDED rescue through O1 cannot run, drills are held)
Found: 2026-10-29, Run 15 Earthboat and Guildcleans (FR-BUGS.md), fix6-econ-supply
Module: `lua/dfllm/economy.lua` (`M.mech_need`, `M.mech_free`, `M.plan_mech`, `M.supply_wants`, `M.rock_dig`), `lua/dfllm/trade.lua`

## Actual
Earthboat event #1051 ACT_FAIL 'needs 2 free reachable mechanisms, 1 found'; status 'R0 levers:B1,B2,O1'. Guildcleans 'Levers bei
B2 und O1 not linked' with stone free 0. act.link_lever needs two mechanisms; gate only retries the link; economy never ordered one
and its stone dig did not count mechanism stone.

## Fix
Per pass (in the gear plan): need = 2 per manifest lever that `gate.linked` does not count as linked; free = mechanisms the lever
sheet may take (not forbidden, in a job or building, owned, ...); the short is ordered as ConstructMechanisms in stone at a
Mechanic's workshop (tag `dfllm:mech`, at most 4, not twice while open). No Mechanic's workshop: PROJECT_REQUEST workshops
why=gear types [Mechanics]. No free stone: the short counts as rock need (bedrooms stone dig) and `economy.supply_wants` asks the
caravans for `mechanism` (new trade token, TRAPPARTS). Traps are not counted (no read of a planned trap's state).

## Tests
`tests/lua/test_economy_supply6.lua` BUG-268 x2 and the trade token test (fail on 2b9c009).

## Live check
Earthboat: `dfllm cmd inspect '{"what":"orders"}'` lists a `dfllm:mech` ConstructMechanisms order; once made, gate's link job
runs (LEVER 'link B2'), status no longer lists levers:B2; in a fort without stone `inspect what=trade` wants `mechanism`.
