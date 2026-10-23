# BUG-081 The wall + door that replaces a lost bridge: the door is refused beside planned walls, a stuck door keeps the fort open for ever, the rebuild policy pauses it, and care's drink nook has no kind
Status: fixed in the I2 commit (offline, live-untested): `runner.repair` `opts.closure` (walls stage, then door stage, prio 1,
`params.cl`), the closure keeps the seal clock (SEAL_STUCK with the cause, the BUG-044 wall fallback) and pauses nobody, kind
`repair` for the rebuild policy; `mood_drink` is kind `mood` (never paused by an open seal, runs in the rebuild policy);
`KP.standing` counts a wall on the door tile as closed
Severity: critical (an open way in that nothing closes: the combination of A1 and A2; Run 11 lost 60 citizens through one
unbuilt door)
Found: 2026-10-23, integration audit I2 (nobody had read A1, A2, B3 and the older seal-first / rebuild-policy rules together)
Module: `lua/dfllm/runner.lua` (`M.repair`, `kind_of`, `REBUILD_RUNS`, `focus`, `Q.stuck_walls`, `Q.closure`),
`lua/dfllm/seal.lua` (`KP.close`, `KP.standing`)

## Actual (proved from the code at 9bcb14f, each with a test that fails there)
1. **The closure's door is refused and the project ends `build_lost`.** `KP.cells` gives walls `Cw` on the sides and the
   door `d` in the middle of the footprint's first row, and `runner.repair` put all of them into one chunk. quickfort places a
   door only where an orthogonal neighbour is a standing WALL or FORTIFICATION; a planned wall beside it does not count (the
   rule behind `door_walls`, Run 11), and the door's other neighbours are the footprint's own walls and the tunnel floor. The
   first apply refuses the door (`build_unsuitable`), the unconditional first re-apply (`measure_build`, `R.ra`) runs while
   the walls are still planned and refuses it again; once the walls are built `pend == 0`, `lost * 100 > total * lost_pct` and
   the stage is `build_lost`. `door_walls` converts a refused door to a wall for `seal` only (a closure door must stay a
   door), so the door waits for the retry of a season (`retry_every`), up to 8 times. Test: "(a)" in
   `tests/lua/test_i2_closure.lua`.
2. **A stuck closure door had no SEAL_STUCK cause and no wall fallback.** Every A1 piece is keyed on `SEALS[P.tpl]` /
   `P.tpl == 'seal'`: the stuck clock (`focus`), SEAL_STUCK `wait`, `Q.stuck_walls`, the door-order bypass. A closure is a
   `repair` project: it waits for the same door item behind the same suspended job and keeps the same way in open for ever
   (the keeper re-queues it after 60 days as a second project with the same cells). The order bypass does not apply (a repair
   stage has no quickfort orders; economy's `T.jmake` orders the door item, as for every planned building).
3. **The rebuild policy paused the closure.** `kind_of` called every `params.peace = 1` repair `defense`, and `defense` is not
   in `REBUILD_RUNS`: in a fallen fort below `rebuild.pop` (a fort that lost its citizens to the siege that took the
   bridge) the wall + door that closes the perimeter waited until the pop was back at `rebuild.off`, with FR-70 escalating
   `PERIMETER OPEN` all the time.
4. **care's drink nook (`mood_drink`, B3) had no kind.** `kind_of` fell through to `work`: an open seal paused it in PEACE, the
   rebuild policy paused it in a fallen fort, and the nook exists for a dwarf who dies of thirst while his mood job waits.
5. **The keeper counts the closure as standing only with a built door** (`KP.standing`): a door the fallback of 2 replaced by a
   wall would never count, the closure would be queued again every 60 days.

## Fix
- `runner.repair(cells, why, {peace = true, closure = true})`: `params = {peace = 1, cl = 1}`, prio 1 (sorts before the plan's
  prio-4 projects), the walls in stage `s1.walls`, the door in stage `s2.door` (one stage when there is only a door or only
  walls). Every other repair is unchanged (one stage, prio 2, a bridge rebuild is `defense`, paused by the rebuild policy
  as before: after 60 days the keeper turns it into the closure).
- `Q.closure(P, d)`; `focus` keeps the stuck clock (`m.runner sf`) of a closure like a seal's but adds it to neither the
  leading seal nor the stuck list, so it pauses nobody and `sched` shows nothing for it; SEAL_STUCK (tpl `repair`) names the
  cause (`wait`); `Q.stuck_walls` replaces a door unbuilt `stuck_days + wall_days` (3 + 2) by a wall under A1's rules
  (PEACE, no lockdown, nobody building it, a fresh entrance check showing another closable opening); SEAL_WALLED names
  `closure`.
- `kind_of`: a closure is `repair` (never paused by the seal, runs in the rebuild policy); `mood_drink` is `mood` (the same).
- `KP.standing`: a WALL or FORTIFICATION on the door tile closes the footprint too.

## Not decided offline
- Whether quickfort in DF 53.16 really refuses a door beside planned walls only at the footprint (the Run 11 live finding says
  so; `dfpilot/bp/defense.py` states the rule and its uncertainty). If it accepts it, the two stages only cost a re-measure.
- A closure project queued by an older kernel (single stage, no `cl`) is not converted; none can exist in a live fort (A2 is
  offline-only), and the keeper queues a new closure after 60 days anyway.
- A footprint over open space (a wall cannot stand there) still never finishes; it is reported as before.

## Tests
`tests/lua/test_i2_closure.lua` (walls first and the door in a stage of its own with slow builders; SEAL_STUCK `wait` and the
wall after 5 days, once; not at the only way, not outside PEACE; the rebuild policy runs the closure and the nook, pauses the
bridge rebuild; the mixed scenario of an open seal, a closure, a build_lost farms project, a refuge drink store and a nook on
3 slots, a siege freezes the closure), `tests/lua/test_perimeter_keeper.lua` (the keeper asks for a closure, a walled
door tile is closed). Each fails on 9bcb14f.

## Related
BUG-044, BUG-048, BUG-037, BUG-063, FR-70, DECISIONS 3
