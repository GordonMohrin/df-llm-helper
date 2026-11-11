# BUG-754 citizens at extreme stress pull levers and carry the doctor labors, and a bridge a tantrum toppled waits 14-20 days
Status: fixed (offline, live-untested)
Severity: high (open perimeter, patients and a soldier smothered)
Found: 2026-11-11, Run 16b i2 Whirledrampart y436-y440 (`runs/run-16b/FR-BUGS.md` "Tantrum-Zwerge toeten Patienten, zerstoeren B1"): 9-12 citizens at stress >= 80000; 28961, 29501 and the soldier 29122 smothered "by dwarf 29522/29299/29650 (patient)"; B1 "toppled by Tholtig, Farmer" (BRIDGE_DESTROYED, y440), O1 and B2 before; kern.log: O1 lost at tick 176472389, stood again 176497242 (about 20 days), B1 lost 177544181, stood 177563484 (about 16 days)
Module: `lua/dfllm/care.lua` (`xs_look`, `xs_step`), `lua/dfllm/gate.lua` (`unfit`, `fill`), `lua/dfllm/seal.lua` (`gates_pass`), `lua/dfllm/runner.lua` (`M.repair`)

## Actual
The extreme-stress set (BUG-728) named only the first six citizens (`M.XS.ids`), so `care.stress_ids` (used to take citizens off the Orderlies detail and out of the water carriers) missed the other three to six. Gate picked lever pullers by distance only, so a citizen at stress 80000 or more stood beside the levers and the bridges in every lockdown. A bridge lost without a destroyer in sight was rebuilt as a `repair` project of priority 2, behind the plan's own projects.

## Root cause
`care.lua` `xs_look`: `a.xs` is capped at `M.XS.ids` (6) for the DECISION text and `st.xs_set` was built from it. `gate.lua` `unfit` had no stress rule. `seal.lua` `gates_pass` called `runner.repair` with `{peace = true}` only, and `runner.repair` registered every repair at priority 2.

## Fix
`st.xs_set` holds every citizen at stress >= `M.XS.stress` (`a.xset`); `gate.unfit(u, xs)` returns 'stress' for one of them (not a lever puller, may serve again once calm, no permanent skip); `runner.repair` takes `opts.prio` (1..7, default 2, a closure stays 1) and seal queues a lost bridge's repair with `prio = 1`.

## Open
DF has no movement confinement for a citizen without a civ alert (a burrow limits his jobs and holds him only during an alert), so no burrow keeps a tantrum citizen out of the hospital here: he is taken off the Orderlies detail, the water carriers, the doctors (BUG-756) and the lever pullers. Stress relief (temple, tavern, bedrooms) stays with the DECISION `stress_extreme` and plan propose. The builder time of the rebuild (Stone 0, "no builder took it") is not changed.

## Tests
`tests/lua/test_bug511_pullers.lua` ("BUG-754": a stressed citizen is no puller, the next nearest one is), `tests/lua/test_bug754_repair_prio.lua` (opts.prio), `tests/lua/test_perimeter_keeper.lua` ("BUG-754": the lost bridge's repair is queued with prio 1), `tests/lua/test_bug756_doctors.lua` (the full set excludes 8 stressed citizens, not only 6). Siege traffic: `test_bug511_pullers.lua` runs the real gate with pullers, drill and a lockdown (bridges up in time, nobody crushed); its older cases pass unchanged.

## Live check
`inspect what=defense` after a toppled bridge: the repair project has prio 1 and stands within a few days; the puller list (`burrow_units dfllm-levers`) never holds a citizen named by `stress_extreme`.
