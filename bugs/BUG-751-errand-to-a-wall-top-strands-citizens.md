# BUG-751 a job whose target lies on a walk group with no way back sends citizens to die of thirst; CUTOFF / STRANDED name neither the tile nor the job
Status: fixed (offline, live-untested)
Severity: high (7+ citizens lost in one fort)
Found: 2026-11-11, Run 16c i3 Doorwings y388-y391 (`runs/run-16c/FR-BUGS.md` "Teil-Walkgroups 2715/1339", "Ursache gefunden: HuntVermin zieht Buerger auf die Wandkrone z149"): the Chief Medical Dwarf 26431, the Planters 28228 / 28229 / 28231 / 26519 / 26432 and the bookkeeper 26276 died of thirst at 87-97,112-116,z149 on walk groups 2715 / 1339, the walkable tops (z149) of the unfinished bedroom block y379s0b0 over its z148 walls. kern.log: "CUTOFF held for an audit a day later ... cause not found (citizen 28229 at 89,116,149 on group 2715)"; 26276 stood there on a HuntVermin job; STRANDED "no raised bridge leads to drink and food; fix: zone 17701 ... open a walk path".
Module: `lua/dfllm/seal.lua`, `lua/dfllm/siege.lua`, `lua/dfllm/act.lua`

## Actual
Nothing looked at where a job led. A HuntVermin (or gathering, hauling) job whose target is on the wall tops took the citizen onto a group that no tile joins to the water and food (a one-way drop). Then (a) `seal.M.trip` excused him as "on a job outside" for as long as the job lasted, so CUTOFF never came for 26276; (b) for the others the blame search found no closer ("cause not found"), because the cut is no wall or door but a drop; (c) STRANDED named a zone 13-66 tiles off and a fix nobody could run, not the tile and not the job.

## Root cause
`seal.lua` `blame` (searches closers and raised bridges only) and `M.cut_confirm` (a trip job excuses a citizen without limit); no check of a job's target group; `siege.lua` STRANDED 'refused' text without the separating tile or the job.

## Fix
- `seal.M.edge_blame` (new): a bounded walk (CFG.blame_max) over the cut group; the first tile with a neighbour one to three levels down on a group that holds drink or food is the separator: kind `wall top` (constructed wall under it), `rock top`, `drop`, plus `drop to x,y,z`. `cut_confirm` uses it when `blame` finds no closer, so CUTOFF names it at once (`d.why`, `d.pos`, text "wall top at 13,9,6 (drop to 12,8,5)") and the cut citizen's job (`d.job`, text " job HuntVermin").
- `cut_confirm`: a trip job excuses a citizen for `CFG.trip_max` (2 days) only; after that he is cut off whatever his job (`mem.tripped`).
- `seal.M.separator(K, pos, unit_id)` (public) and `siege.lua` STRANDED 'refused': "; cut off by wall top at x,y,z (drop to ...), job HuntVermin" before the fix text, `d.sep`, `d.job`.
- New seal job `stray` (every `CFG.stray_every` 600 ticks): a citizen on a group with drink and food whose errand (`M.STRAY_JOBS`: HuntVermin, Hunt, GatherPlants, FellTree, Fish, Collect*, GatherHoney, PlantSeeds, StoreItemIn*) targets a tile (`job.pos`) on a group without both is cancelled with the new `act.cancel_stray_job(unit_id)` (owner seal; worker released, job removed; any other job refused). At most 3 a look, the same unit once a day, kern.log "seal: HuntVermin of citizen N cancelled: its target ... lies on walk group G ...".
- Lint: `removeJob` is also allowed inside `act.cancel_stray_job`; ACT table / contract / DESIGN / CONTRACTS list it.

## Open
The kernel does not roof or remove the walkable tops of an unfinished surface block (`rooms.py` surface rooms have open tops by design); it stops the errands, names the tile and reports (CUTOFF / STRANDED / MISSING). A citizen already on the top is still not rescued (no path may be dug near water; the separator now tells where a ramp or stair would join). A job is judged by `job.pos` only (the position of a hunted vermin changes while the job runs). Not run live.

## Tests
`tests/lua/test_bug751_752_strays.lua`: CUTOFF names wall top / rock top and the drop; a trip excuses for two days then CUTOFF names the job; `seal.separator`; the errand to the top is cancelled and the one inside stays; `act.cancel_stray_job` on the real act.lua. No bridge, gate, refuge, lockdown or seal-closing behaviour changed, so no siege traffic case.

## Live check
After a reload: no HuntVermin / gather job on a wall top (kern.log "cancelled: its target"); a CUTOFF names `wall top at ... (drop to ...)`.
