# BUG-478 The O1 bridge could not be pulled in the fight: no lever inside the refuge the civilians were confined to
Status: fixed (offline, live-untested); open: the retrofit command needs mechanisms and stone, a soil fort without them still waits for the caravans
Severity: critical (Castletongs fell: Pop 100 -> 7)
Found: 2026-11-05, Run 16c i3 Castletongs y403 spring d6-d13 (`runs/run-16c/FR-BUGS.md` "Belagerung y403", events #5487, #5523, #5561, #5619)
Module: `lua/dfllm/gate.lua` (`resolve`, `refuge_gaps`), `lua/dfllm/readiness.lua` (`check`, `ask_reflevers`), `lua/dfllm/siege.lua`

## Actual (the failure chain, kern.log / events.jsonl of r16c3-castletongs-site97)
1. tick 162496539: popup "A vile force of darkness has arrived! ... With them come monstrous siege engineers!" (ARRIVAL #5447): the lockdown puts the civ alert on **Kern+**; 11 citizens outside, `gates: 0 of 1 up, O1`.
2. +9 ticks: sense counts five trolls (`SIEGE_DEEP` #5451, "5 building destroyers in sight, 101 tiles from O1"); seal moves the alert to **Tiefe+** (`REFUGE_SWITCH`), reflex: "83 citizens not in Tiefe+ now". 83 citizens walk down the civilians' stair across B2's landing and the B1/B2 footprints.
3. O1's raise is held again and again: `O1 up pull cancelled: soldier 26277 2 tiles from it and walking toward it` (x6, squads 99/100 coming in to their station, citizens 26273/26274/26573 "walking onto it"), `B2 up waits for citizen ... +15 more`. At T+900 `BREACH breach: O1 not up` (#5487, MODE SIEGE>BREACH gate_fail).
4. The BREACH alert burrow is Tiefe+; the O1 pull is a lever pull job, and a confined civilian takes only jobs on a tile of his burrows. `gate: lever pullers dfllm-levers = {} (BREACH)`; #5523 `GATE_FAIL O1 not up after 1150 ticks (no worker: its levers lie outside the alert burrow Tiefe+)`, `LEVER pull O1 up` queued 40 more times and never taken (#5561 "5 pull(s) not taken in 200 ticks; lever pullers dfllm-levers 0 of 2 at the levers"). O1 stayed down for the rest of the fight.
5. The manifest lists three levers per bridge (`O1: 118,118,125 / 118,119,125 / 126,126,119`), the third inside the refuge. commands.log shows its link `[17829,17772] ok` at tick 150596979 after 6 refusals ("needs 2 free reachable mechanisms, 0 found": the soil fort had no mechanisms for months). `gate.resolve` looked for levers linked to the bridge **only while none was known** (`not any_linked(r)`): with the two Kern+ levers linked, a refuge lever that stands beside its manifest tile (or a link made later than the first resolve) was never put into the bridge's lever list, so `lever_in(r, alert burrows)` stayed false and the pull was classed `outside_alert` at the first no-worker cancel.
Note: the log cannot tell which of the two (a displaced lever tile, or the 6000-tick resolve cache) kept the refuge lever out; both are closed below, and the check names the bridge either way.

## Root cause
- `lua/dfllm/gate.lua:resolve` (the stale-position scan only when `not any_linked(r)`): a bridge with some linked levers never re-looked for one inside the refuge.
- Nothing checked, in PEACE, that every bridge has a linked lever inside the refuge burrow (readiness counted only `levers:<B>` < 2 linked anywhere), so a fort could live for years with levers only where nobody confined can pull.

## Fix
- `gate.resolve`: while no known linked lever of the bridge lies in the refuge burrow, the lever scan (`buildings.other.TRAP`, links to this bridge) runs at most every `M.RESOLVE_REF` (1200) ticks even if other levers are linked.
- `gate.refuge_gaps(K)` (public): the managed bridges with a linked lever and none inside the refuge burrow.
- readiness: `ready.rg` in PEACE (SIEGE_UNREADY "no refuge lever: B1,B2,O1"); deliberately NOT an R0 blocker (R0 stops the automatic drills, and a soil fort without mechanisms could never build the levers) and `DECISION_NEEDED refuge_levers` (A, every `DEF.ask_days` = 30 days) with `cmds = ['bp.place tpl=fortcore site=same stage=3 retrofit=2']` (the fortcore retrofit that builds the refuge levers; their links are gate's jobs, the mechanisms the economy's).
- Placement already existed (fortcore stage 3 `REFUGE_LEVERS`); this is the check and the repair for forts that lack them.
- A lever pull does not depend on someone walking outside in a BREACH when a refuge lever exists: `gate.order` ranks a lever inside the alert burrow first (BUG-013, Run 11 y432); the fix makes sure it is in the list.

## Tests
`tests/lua/test_bug478_481_defense_ready.lua` (refuge_gaps; a lever built beside its manifest tile is found; `ready.rg`, the one DECISION with the command, SIEGE_UNREADY text), `tests/lua/test_bug478_481_siege_traffic.lua` (the siege traffic test, see BUG-480), the gate/traffic suites unchanged (test_bug342_gate_workers, test_bug380_siege_traffic, test_gate_crush, test_merge15_gate_review, test_kern_load, test_bug462_*).

## Live check
`status` of a fort without refuge levers: `ready.rg` lists the bridges and one DECISION `refuge_levers`; after the retrofit and the links `gate.refuge_gaps` is empty, no `outside_alert` GATE_FAIL in a deep defense.
