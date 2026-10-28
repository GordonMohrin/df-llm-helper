# BUG-110 `drill` and its automatic retry run without an outer and an inner bridge: 320 drills "failed: raised -1", each calling everybody into Kern+ and clamping the FPS
Status: fixed in the M2 commit (offline, live-untested): drill.start (verb, auto start) refuses with `no lever-linked bridge: build fortcore stage 2/3 first` before it touches the mode; the refusals are counted
Severity: medium (a year of lost work time; harmless to the walls)
Found: 2026-10-28, Run 14 (Trussroads y707), game session note 87 and the post-mortem
Module: `lua/dfllm/drill.lua` (`M.gap`, `M.start`, `check`), `lua/dfllm/readiness.lua` (`ready.dref`), `dfpilot/brief.py`

## Actual
O1 and B1 were missing (readiness `no_outer`, `no_inner`). 320 manual drills plus about 5 automatic retries a year all ended `drill failed:
raised -1`; each one set mode DRILL (civ alert Kern+, everybody called in) and the FPS cap 30.

## Cause (proven from the code at 32994bb)
1. `drill.start` (drill.lua:171-189) checks only a running drill, danger and the trade screen, then `K.set_mode('DRILL')`. A manual start
   (`M.verbs.drill`, drill.lua:407) and `M.step`'s automatic start both come through it; nothing asks for a bridge.
2. The automatic gate `check` (drill.lua:321) wants `#gate_bridges(man) > 0`: one outer OR inner bridge in the manifest is enough, and
   `measure` (drill.lua:202) fails `no_bridges` / `up:<B>` (raised -1) whenever a bridge is not up or the fort has none. A bridge that
   seal replaced by wall + door stays in the manifest and counts as a gate there.
3. The retry after a failure (`retry_wait`, one month doubling to a season) has no structural reason for it (`structural` knows `no_kern` and
   `no_uniform` only), so the fort kept retrying.

## Fix
- `drill.gap()` names the roles the manifest lacks as a standing bridge (`no_outer`, `no_inner`; a bridge in `seal.replaced` is none). `drill.start`
  refuses first with the fixed sentence `no lever-linked bridge: build fortcore stage 2/3 first` (+ `{gap, refused}`), before any mode change: no
  civ alert, no recall, no FPS change. The inbox verb `drill` and the automatic start use it; `check` holds with `no_outer` / `no_inner`
  (`drill.hold()`, `ready.dhold`).
- Every refusal is counted (`m.drill` `ref`); `drill.refused()` and `ready.dref` move at most once a game day and a minute of wall clock (util/cadence), so does the kern.log line
  (`drill: refused (no_inner): ...`); `status` shows `[N refused: build fortcore stage 2/3 first]` after `drill never`.
- A fort with both roles drills as before; an older state without the counters works.

## Not decided offline
- Whether a fort with a `lever-linked` bridge in the manifest but without a lever pair (readiness `levers:<B>`) should be refused too: it is not
  (readiness shows it as an R0 blocker, the drill's own KPI fails it).

## Tests
`tests/lua/test_m2_drill.lua` (5: no inner bridge: start, the inbox verb, the automatic start, hold; both missing; a replaced bridge; the
counter once a day with state and log; a full fort drills). All fail on 32994bb; `test_drill.lua` "no automatic drill without soldiers or without
outer/inner bridges" now expects the refusal where it expected a drill that fails with `no_bridges`.
