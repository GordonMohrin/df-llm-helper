# BUG-116 The hospital project waits behind expansion projects for 60 game years, and TOOL_BLOCKED (miners find no pick, 109 picks in chests) tells the player nothing to do
Status: fixed in the M6 commit (offline, live-untested): care first (the hospital leads the runner's slots while hospital_out is set or patients lie in the fort) and TOOL_BLOCKED carries `tell` and `care`
Severity: high (Run 14: `hospital_out` from y526 to the end, seven placements, patients died of thirst and bleeding outside the refuge)
Found: 2026-10-28, Run 14 Auswertung (note 89)
Module: `lua/dfllm/runner.lua` (`Q.care_lead`, `sorted`, `paused`, `focus`), `lua/dfllm/economy.lua` (`M.tool_tell`, `tool_check`), `dfpilot/brief.py`, `dfpilot/wake.py`

## Actual
The hospital was placed seven times; the last placement stood at "dig 0 %, slot yielded": the Miners found no pick (TOOL_BLOCKED, 109 picks
in chests) and expansion projects held the slots. The player was told nothing he could do in the game.

## Cause (proved from the code at 32994bb)
1. **Only a seal is ever first.** `runner.lua:2469` `sorted()` orders seals first (`SEALS[a.tpl] and 0 or 1`), then prio, then age;
   `runner.lua:2983` `paused()` pauses `work`/`beds`/`supply` only for an open seal (`SEAL_PAUSES`, `runner.lua:2501`) and for the rebuild
   policy. `kind_of` (`runner.lua:2524`) gives a `hospital` project the kind `work` (class `living`): it competes by prio and age with
   bedrooms, halls and workshops for `M.CFG.active` (3) slots, and a project without progress for `queue.yield_days` (7) yields its slot
   (`runner.lua:4056` `second`). A hospital that waits for the miners' pick therefore yields to the projects behind it.
2. **Nothing connects the hospital need to the runner.** water.lua publishes `hosp_out` and `patients` (`water.lua:1398-1403`), readiness turns
   `hosp_out` into R0 `hospital_out` (`readiness.lua`); the runner reads neither.
3. **TOOL_BLOCKED is class A already** (`economy.lua:3666`, `contract.lua:100`). Its `d` names causes in the kernel's words (`bk`, `blk`,
   `picks`, `units`) and `hint` ends "the player may toggle the detail in the work details screen (untested)"; no field says what to do in
   the game (unforbid the pick, put it in a free chest, ...), and nothing says which project waits for the tool.

## Fix
- **Care first** (`runner.lua` `Q.care_lead`, state `m.runner cf`): in PEACE, while water's `hosp_out` > 0 or `patients` >= `care_first.patients` (1),
  the first live hospital project that is not halted leads: `sorted()` ranks it right after the seals, `second()` never makes it yield, and
  `paused()` pauses the `work` and `beds` kinds (`Q.CARE_PAUSES`) with the reason `care <id>`. Never paused: seals and plugs (they stay ahead), tombs, the
  depot, repairs and wall closures, defense, mood nooks, supply (farms, cisterns, stockrooms, food/drink shops), explore. The seal-first pause still
  holds for the hospital itself (kind `work`): an open way in is worse than a hospital outside the refuge.
- **A stuck hospital stops pausing**: no change of stage, chunk, percent or progress for `care_first.stuck_days` (10) game days latches
  `st = 1` (kern.log warns once, state `sched.care {stuck 1, days}`); the others run again and the hospital leads again when it moves. The clock
  waits while the mode is not PEACE. A halted (blocked for good) or parked hospital project leads nobody.
- State `sched.care {proj, paused, why, stuck?, days?}`, status line `care first: <id> (hospital_out 1) runs first, 3 paused` /
  `care stuck 10 d: ...`, kern.log `care first: <id> with hospital_out 1 runs first; paused: ...`. Config `runner.care_first {on (true),
  stuck_days (10), patients (1)}` (`fairplay.RUNNER_LIM`, baseline.json, `lint --config`); `on` false keeps the old scheduling.
- **TOOL_BLOCKED**: `d.tell` (<= 200 bytes) is one sentence for the player in the game's words, from the diagnosis keys and the counts
  (`economy.tool_tell`): labor missing, a second tool labor, all forbidden ("unforbid them (the items screen, flag forbid) or put them in a free
  chest"), reserved by squad uniforms, lying in chests ("dwarves need the pick unforbidden or in a free chest of a tool stockpile they can reach"),
  another walk group, alert/burrow, else a generic check list. `d.care` names the hospital project that leads and needs the miners while care first leads
  (`runner.care_first`, public, read-only). The wake hint says "tell Gordon what d.tell says". No verb moves or unforbids a tool for a member
  (fair play); the kernel's own repairs stay as they were.

## Not decided offline
- Whether the miners fetch a pick from a chest at all: DF hands a work tool out from the free equipment lists (`items_unassigned`), the
  chest case is the note's observation; `tell` repeats the player's rule of thumb, `inspect workload key=tools` has the records.
- Whether care first lifts the stall of the Run 14 fort: if the picks are the cause (no progress), the pause lifts after `stuck_days` by design;
  live data: `kern.log` lines `care first:` and the TOOL_BLOCKED `d.care`.

## Tests
`tests/lua/test_m6_care_first.lua` (8: no need, hospital_out, patients, exceptions, `on` false, stuck latch, halted, seal ahead; the four that need care first fail on 32994bb, the other four guard unchanged behaviour),
`tests/lua/test_economy_tools_a3.lua` (2: `tell` for chests, forbidden, labor; `care`), `tests/test_m6_orders.py` (config validation).
