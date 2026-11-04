# BUG-340 famine: the kernel does not resolve it, the DECISION options have no effect
Status: partly fixed (offline, live-untested): follow's farms placement, caravan food/seeds, runnable options; open: idle
labor with thousands of unclaimed jobs (Inkintense), no farm soil and no surface site at all, brewing from gathered plants
Severity: critical
Found: 2026-11-04, Run 15c (Inkintense, i1) and Run 15d (Drillchamber, i4), `runs/run-15c-inkintense/FR-BUGS.md`
(y378 "Hunger ... 4417 unclaimed Jobs", "Hungersnot y378 Winter"), `runs/run-15d-drillchamber/FR-BUGS.md` (y379-y381
"only 0 free site(s) for farms", famine options), kernel main b35af6d
Module: `dfpilot/wake.py` (follow `_place`, `_place_farms`, `farm_tries`, `food_hint`), `lua/dfllm/economy.lua` (`food_block`,
`food_more`, `food_q`, `fd_wants`), `dfpilot/schema.py` (DECISION_NEEDED `cmds`)

## Actual
- Drillchamber y379-y382 (i4 cli.log): 220 AUTO_FAIL `farms: site S1: only 0 free site(s) for farms plots=2 on snapshot ...
  (0 ranked)` while kern.log said `farms: 105 of 153 tiles for 51 citizens, food 1 days and falling: request 2 plots` and
  `famine: 3 food days ...`. The only farms that ever came were the plans' surface farms (bp/y379s0b3, y380s0b0, y381s0b0:
  `{"plots": 1, "surface": 1}`, done), one a year. Root cause wake.py:734 (b35af6d): economy's PROJECT_REQUEST farms is placed
  as a farms room at the request's plots only, wake.py:1095 sends it once; no smaller room, no surface farm (BUG-302/316 do
  that for plans and `bp.place` surface only).
- Famine decisions (Inkintense #2552-#2623, #2727/#2748; Drillchamber #2867/#2877/#2883): `opts` named `gather` (no verb),
  `trade.want food` (the verb takes `{"want":[...]}` and replaces the plan's whole want list; the text form was `bad args`),
  `butcher.mark` (`no animal to mark`) and `popcap.lower` without arguments. Root cause economy.lua:7625 (b35af6d)
  `M.FOOD_MORE`, appended to every food_low/famine decision as words, never as commands.

## Fix
- follow: a farms placement (`_place_farms`) tries `farm_tries(p, mode)`: the request's room plots, the same room with fewer
  plots down to 1, and in PEACE a surface farm on soil floor (`surface: 1`; cmd.place falls back to fewer surface plots
  itself, BUG-316). The first that places is sent (cli.log `auto:farms BUG-340: no farms site for ...: placed with ...`);
  none: the first error as before (and `_waive_farms`).
- economy `fd_wants`: below `food.pre_days` (or in a famine) the caravans are asked for `food` (30) and `seeds` (10, unless
  the seedless rule asks 20 already) by the kernel itself (trade puts economy's wants before the plan's); the food
  decisions name it in `auto` (`trade: caravans asked for food, seeds`).
- economy `food_q`: an option is offered only with its command line; `d.cmds` holds them in `d.opts` order (at most 420
  bytes, d stays under kern's 1,024): kitchen / fishery / bowyer / butcher = `dfllm cmd bp.place '{"tpl":"workshops",
  "site":"S1","p":{"only":"<shop>"}}'`, farms = `bp.place` farms `surface:1`, `butcher.mark '{"n":2}'` only while tame
  animals stand, `popcap.lower '{"cap":<citizens>,"until":"food"}'`. `gather` and `trade.want food` are gone (the kernel's).
  The fishing zone and hunting have no player command (the kernel paints the zone; the blocker names why).
- wake: `food_hint` (famine/food_low with `cmds`): what the kernel does, the first command in full, the others by name;
  `famine` is an urgent decision (BUG-240 limit), as `food_low` was. Schema DECISION_NEEDED `cmds` (<= 8 lines, 200 bytes).

## Open
- Inkintense y378: 2 of 39 idle, 4417 unclaimed jobs, the FarmPlot job `not suspended, no builder has taken it` and
  `Plant gatherers is everybody-does-this (the jobs wait for another reason)`: a labor/priority problem the fix does not touch.
- A fort with no soil underground and no free surface soil (Drillchamber before y379): nothing to place; muddying stone
  needs water (never dug near water without Gordon).
- Brewing from gathered plants and a quern (`Mill plants` 2183 d old) are not in this fix.

## Tests (fail on b35af6d)
- tests/lua/test_economy_fishing.lua: `BUG-340: food_low asks the caravans for food and seeds itself; each option carries
  a runnable command` (every cmd parses as `dfllm cmd <verb> '<json>'`), the food_low/BUG-258 tests (opts, cmds, d <= 1,024
  bytes encoded); test_economy.lua, test_economy_gather.lua (auto `trade`).
- tests/test_bug340_341_famine_mood.py (5): farm_tries, follow places on the first try with a site / raises the first
  error (no surface outside PEACE), the schema of `cmds` and each command's args, food_hint, famine urgent.

## Live check
Drillchamber/Inkintense after a reload and a follow restart: a farms PROJECT_REQUEST without a room site -> cli.log
`auto:farms BUG-340 ... placed with {'plots': 1}` or `{'surface': 1}` instead of AUTO_FAIL; `dfllm events --cls A` famine
lines carry `cmds`, each sent as it stands is accepted; `inspect what=trade` lists `food`, `seeds` while food < 30 d.
