# BUG-516 'traps 0' although 63/63 traps were built, the plan asked for the trap hall every year
Status: fixed (offline, live-untested)
Severity: medium (wrong report that held the population ceiling and drafted stage 4 again and again)
Found: 2026-11-06, Run 16c i3 Sealcertain y388-y390 (`runs/run-16c/FR-BUGS.md` 'traps 0 trotz 63/63 gebauter Fallen')
Module: `dfpilot/plan.py` (`defense_gaps`), `dfpilot/brief.py` (`line_unready`)

## Actual
brief: `traps 63/63 ways 2/2` but `traps 0 (a bypass skips the hall)`; `plan propose` / `plan check` warned `traps 0: no trap hall (fortcore stage 4) ... add` every year although stage 4 stood twice. The stair bypass 54,132,137 made `bp.topo.audit` count 0 armed traps on the cheapest route (`min_traps` is the count on the route the bypass leaves, 0 when no wall closes it), and BUG-377's `defense_gaps` read that 0 as 'no trap at all'.

## Root cause
`dfpilot/plan.py` `defense_gaps`: `audit.min_traps < TRAPS_HOLE` -> `traps 0`, whatever stands in the fort. With the R0 blocker `bypass` the 0 says the route avoids the hall, not that the hall is missing.

## Fix
- `defense_gaps`: `traps 0` is not a gap while armed traps stand (state `traps.n >= 1`) and the R0 blockers name `bypass`; the bypass is the seal's job (R0 `bypass`, `audit route`). Without a bypass, without armed traps or without the state it is `traps 0` as before. The growth hold, the stage 4 draft and the `plan check` warning follow.
- `brief.line_unready`: with a bypass, `min_traps` 0 and armed traps in state `traps`, the line reads `traps 0 of 63 armed (a bypass skips the hall)`.
- Not changed: the audit itself (the hatch on a stair that counts as a door and keeps the bypass, as the FR notes) and R2's rule on `min_traps`.

## Tests
`tests/test_bug514_517_f32.py` (3: defense_gaps with and without a bypass / traps, `plan.defense_gate` no longer asks for stage 4, status text).

## Live check
`dfllm status`: `traps 0 of N armed (a bypass skips the hall)`; `plan check` without the 'no trap hall' warning while the bypass stands.
