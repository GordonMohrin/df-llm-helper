# Feature requests (tools I missed while playing)

Each entry: what was missing, what it cost, what the tool should do. Written during the Paddletribes run
(site 94, fallen spring y382). Keep adding to this list whenever play hits a gap (RULES §1.7: no new tooling in
play, so a gap becomes a note here, not a script in the running game).

| # | Tool | Why (cost in Paddletribes) |
|---|------|-----------------------------|
| FR-01 | Order sanity check | A PrepareMeal order stood valid for months with no Kitchen; 133 orders without material cancelled endlessly |
| FR-02 | Stuck-construction watch | Kitchen, still, bridges, traps stayed at stage 0 or vanished; nobody noticed for weeks |
| FR-03 | Reachable-stock report | Food in cut-off caves counted as stock (fixed in economy.lua); report stock per walkable group for water, wood, stone too |
| FR-04 | Burial/ghost monitor | Loose corpses 70-120 and ghosts 30-41 grew for a year; alarms only at the end |
| FR-05 | Job-pickup diagnostic | 22 ConstructBuilding jobs unworked while 6 masons idle; no way to see why a job is not taken |
| FR-06 | suspendmanager control verb | It re-suspended construction; baseline re-enables it; `set preventblocking` is allowlisted but no verb |
| FR-07 | Hostile-visibility explainer | Which unit holds the fort in ALERT/BREACH? Needed ad-hoc Lua twice (underworld demons, cave crocodile) |
| FR-08 | Embark site finder with waiver | Helper rejects every site it finds; no way to accept a known trade-off (old_sites, scarce trees) |
| FR-09 | Embark: Prepare carefully | Still not drivable; points stay unspent, player must do it by hand |
| FR-10 | Orders without material pruner | EngraveSlab/web/silk orders spam cancels; kernel should drop orders that cannot start |
| FR-11 | Early-warning dashboard | Population fell 55 -> 46 -> 0 over a year; a trend line "pop, food, drink, stress, corpses" per season |
| FR-12 | Rebuild-lost-buildings helper | Traps 31 -> 0 and bridges lost; no verb to re-place a list of lost buildings |

| FR-13 | Plan check before the fort manifest exists | `plan check` rejects every plan with room templates (farms, cistern, ...) until fortcore is placed; even the default draft is rejected on a fresh fort. Workaround: place fortcore with `bp.place`, then propose/check/apply |

## Details
**FR-01 Order sanity check.** `dfllm cmd orders.check`: for each manager order, verify the workshop type exists
and is built, the material exists on the reachable walkable group, and a worker with the labor exists; report
orders that cannot run for N days and drop or pause them.
**FR-02 Stuck-construction watch.** Per planned building: stage, days since placement, held item, worker. Alert
class A if a building is at stage 0 for more than 30 days or disappears.
**FR-03 Reachable-stock.** `inspect what=census` split by walkable group; mark items in other groups as
`unreachable`.
**FR-04 Burial/ghost monitor.** Goals-style thresholds in the kernel: loose corpses > 20 or ghosts > 5 raises a
class A event and an automatic coffin/tomb project.
**FR-05 Job-pickup diagnostic.** For one job id: labor needed, units who could take it, why each does not
(labor off, no path, burrow, busy). Read only.
**FR-06 suspendmanager verb.** `dfllm cmd suspendmanager preventblocking=false` through the allowlist, and a
baseline option that stops forcing it on.
**FR-07 Hostile explainer.** `dfllm cmd inspect what=threat` listing the units counted as hostile, with race, z,
walkable group and why.
**FR-08 Embark waiver.** Allow `--accept <criterion>` for failed (not only unshown) criteria with a logged
reason, and a "relax old_sites" rule when the old fort is ruined.
**FR-09 Prepare carefully.** Drive the skill rows (known blocker: clicks ignored, see embark README).
**FR-10 Pruner.** Kernel drops manager orders that cancelled more than N times for "Needs ..." reasons.
**FR-11 Trend dashboard.** Season-by-season table in `dfllm brief`.
**FR-12 Rebuild helper.** Keep a manifest of placed buildings; `bp.restore` re-places the missing ones.

**FR-13 Plan check without manifest.** Accept room templates after a fortcore stage in the same plan (dry-run the manifest), or have `plan propose` emit a first plan with fortcore only and a note to re-propose after placement.
