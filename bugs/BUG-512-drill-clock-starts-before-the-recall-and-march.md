# BUG-512 Drills keep failing "up:B1, slow:O1" after the round-31 fix: the drill's clock starts the tick the whole fort walks over B1
Status: fixed (offline, live-untested)
Severity: high (P5 "waits for drill" for years, R2 never reached, 40 more drills pulled everybody into Kern+ for nothing)
Found: 2026-11-06, Run 16d i4 Trumpetrealms y389-y395 (FR-BUGS "Drill scheitert wiederholt an Bruecken: up:B1, slow:O1, worn<90"); runtime `r16d4-trumpetrealms-site97/events.jsonl` DRILL_RESULT #474-#7752 and `kern.log` tick 157624424-157625900 (read only)
Module: `lua/dfllm/drill.lua` (`step`, `settled`, `settle`), `lua/dfllm/siege.lua` (`raise`, `DRILL_MAX`), `tests/lua/wp6_world.lua`

## Actual
79 DRILL_RESULT in i4 (read at tick ~160M), none passed: `up:B1` in 69, `up:O1` in 25, `slow:O1` in 25 (`outer 800-1100`, goal 600); 43 of them came after the round-31 code (tick 155M on), 37 of those with `up:B1` (e.g. #6480, #6752, #7350: `raised -1 ... (up:B1, worn<90)`). The kern.log of the drill at tick 157624424:
`lever pullers dfllm-levers = {26917,21775} (DRILL)` -> `B1 up waits for citizen 26429 walking onto it in 1 steps, soldier 26747 walking onto it in 2 steps (squad 99 stationed 4 tiles from the bridge at 84,104,139), citizen 26274 walking onto it in 7 steps, +1 more` -> `squad 99 (A) holds the raise of B1: soldier 26747 2 tiles from its footprint ... no station clear of it on its inner side (crowd 3 tiles): kept` -> pullers `{26785,26274}, let go 26917:away,21775:away` -> `B1 up still waits for soldier 21561 walking onto it in 13 steps (squad 99 on its way to its station ...)` -> `B1 not up by the drill's T+900: no late raise`; O1, away from the traffic, rose at +553 after the pull was queued.

## Root cause
`drill.lua` started its clock (T+600 goal, T+900 pass, T+1,200 measurement) and `siege.raise` asked for the raise at T0, the very tick the civ alert sends everybody home and the squads to their stations, all of them over B1 (the barracks outside, the stations 4 tiles behind it, the lever room 3 tiles from it). BUG-493 made the walkers 14+ steps out not hold the raise; the ones within 13 steps still do, and the stream lasts the 900 ticks. The drill measured the march, not the bridges.

## Fix
- `drill.lua`: a drill SETTLES first (`st.ts`, persisted): the raise is not asked for and the clock does not run until nobody is outside Kern+ (a census taken after T0) and half of the soldiers that do not stand down on purpose (BUG-510 `kpi.sd`) stand at their stations, at most `SETTLE_MAX` (1,200) ticks after T0 (then the ones still outside are measured as `outside:N`, as before). The settle tick resets gate's KPIs and is the origin of T+600/T+900/T+1,200; kern.log `drill: settled after N ticks (outside Kern+ 0, soldiers on station 3 of 4): the clock starts`; DRILL_RESULT carries `settle` (schema, CONTRACTS). `SETTLE_MAX` 0 = the old clock from T0 (the test worlds whose soldiers never walk: `tests/lua/wp6_world.lua` sets `X.drill_settle_max`, default 0).
- `siege.lua raise`: while `drill.settle` says settling no raise is requested in DRILL; the deadlines count from the drill's origin; `DRILL_MAX` (3,600) is extended by `drill.settle_max`.
- Not changed: the pass rule (worn >= 90 stays: `mech 1` of BUG-493 still carries the gear-only result), the retry back-off.

## Tests
`tests/lua/test_bug512_drill_settle.lua` (3, the REAL drill module on the siege-traffic world, citizens walking in over B1 every 150 ticks for ~900 ticks and a squad marching over it): with the settle phase B1 and O1 rise inside the clock (raised 225, settle 954, no up:/slow:, `mech 1`, nobody crushed, no GATE_FAIL, B1 up after the settle); with `SETTLE_MAX` 0 the same stream gives `up:B1`, `raised -1` (the live result); a citizen who stays outside: the cap ends the settle and `outside:1` is measured. `test_drill`, `test_drill_a3`, `test_drill_home`, `test_drill_restore`, `test_bug493_drill`, `test_bug492_493_traffic` green (settle off in their worlds).

## Live check
A drill in a fort with the lever room next to B1: kern.log `drill: settled after ~900 ticks ...`, DRILL_RESULT `settle` ~900, `raised` < 900, fails only `worn<90` (`mech 1`), `ready.drill_mech_age` set; P5 leaves "waits for drill".

## Open
A drill now takes up to 1,200 ticks longer (the alert holds the fort in Kern+ meanwhile). Whether the real siege should wait for the garrison's march before asking for the raise (as the drill does) is left: a real arrival cannot wait.
