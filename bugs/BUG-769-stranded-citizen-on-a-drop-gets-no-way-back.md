# BUG-769 a citizen stranded on a one-level drop gets no rescue: no ramp, no delivery
Status: fixed (offline, live-untested)
Severity: high
Found: 2026-11-11, Run 16d i4 Pagedsculpture y407 (summer d36-d46): STRANDED #6508/#6517 'no rescue (no raised bridge leads to drink and food)', citizen 26275 on walk group 1778 at 119,109,143 over a drop to 118,108,142, thirst 39,960 -> 51,860, hunger 51,220 -> 63,120; `bp sites cistern --near 119,109,143 --within 999`: every site lies on the group the cut-off group cannot reach
Module: `lua/dfllm/seal.lua` (`M.rescue_dig`, `M.ramp_pick`, `M.ramp_unsafe`, `M.edge_blame`), `lua/dfllm/siege.lua` (`rescue_step`), `lua/dfllm/act.lua` (`I.rescue_ramp`)

## Actual
A walkable pocket one level over the fort's floor (a wall top, a ledge, a hole's edge) has no walk path down. A citizen who steps or falls into it is a STRANDED case; the kernel's rescue lowers bridges only, so with no raised bridge on the way it said 'no rescue' every round and dug nothing. A hauler cannot cross the drop, so no drink or food reaches him either.

## Root cause
`lua/dfllm/siege.lua` `rescue_step`, the `if why then` branch (the refusal): after the BUG-751 separator it only emitted STRANDED / `dry_decision`. Nothing in the kernel opened a way between two walk groups.

## Fix
`seal.rescue_dig(K, pos, calm)` (called from the refusal, quiet PEACE only): `edge_blame` now also returns the target tile of the drop (fields 6..8); for a drop of exactly one level the planner looks, within 2 tiles of the stranded tile, for a natural wall tile W (rock, soil or mineral; no building, not designated, revealed) one level down whose orthogonal neighbour is on a group with drink and food (the ramp's foot) and under whose eight neighbours one level up lies a tile of the stranded group (the head). W is dug as ONE ramp (`act.rescue_ramp`, quickfort dig key `r`, priority 2; seal only). Safety, never relaxed: no revealed liquid tile within 3 tiles of W (one level below to two above) and no level the manifest knows as aquifer (`aquifer_levels`; the tile flag itself is hidden knowledge and not read), no open shaft (empty over empty) within 3 tiles on W's level or the one under it, every tile beside W (up, down, four sides) revealed, never under open sky, never on a constructed or tree tile; not in a threat mode (a way in is a way out) and not when the stranded tile is outside. Nothing is dug when no W passes: the answer names the most telling reason ('no safe ramp: water at x,y,z', 'the aquifer level zN', 'an open shaft at', 'no wall tile joins the two groups', ...). One ramp per drop: a designated ramp is waited for (it names 'waiting for a Miner'), at most 3 ramps per stranded tile, again after 2 days. STRANDED (d.ramp, d.ramp_state dug / waiting / none / refused, d.ramp_at) says what was done and ends with 'nothing is carried across the drop' (a hauler cannot cross, so no food or drink is delivered).

## Open
A drop deeper than one level gets no ramp ('the drop is N levels deep'); the economy boost raises the untaken dig job (BUG-747), a Miner must still come; the ramp is not dug through a constructed wall; the walk-group reading after the dig is DF's. Not run live.

## Tests
`tests/lua/test_bug769_rescue_ramp.lua` (7: the ramp once, water / aquifer / open shaft / unrevealed neighbours refuse, not in PEACE, the finished ramp ends the case; real siege + seal on seal_world, the three bridges down), `tests/lua/test_act_supply.lua` (`rescue_ramp`).

## Live check
Next STRANDED on a one-level drop in PEACE: the event carries `ramp` and `ramp_at`, a ramp designation appears at that tile, the groups join after a Miner digs it.
