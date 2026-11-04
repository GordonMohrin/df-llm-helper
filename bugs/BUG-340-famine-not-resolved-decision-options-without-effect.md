# BUG-340 famine: the kernel does not resolve it, the DECISION options have no effect
Status: partly fixed (offline, live-untested): follow's farms placement, caravan food/seeds, runnable options, the famine
crew (food specialists beside thousands of unclaimed jobs); open: no farm soil and no surface site at all, a quern, gathered
plants that are no food (tree leaves), an automatic slaughter policy
Severity: critical
Found: 2026-11-04, Run 15c (Inkintense, i1) and Run 15d (Drillchamber, i4), `runs/run-15c-inkintense/FR-BUGS.md`
(y378 "Hunger ... 4417 unclaimed Jobs", "Hungersnot y378 Winter"), `runs/run-15d-drillchamber/FR-BUGS.md` (y379-y381
"only 0 free site(s) for farms", famine options), kernel main b35af6d
Module: `dfpilot/wake.py` (follow `_place`, `_place_farms`, `farm_tries`, `food_hint`), `lua/dfllm/economy.lua` (`food_block`,
`food_more`, `food_q`, `fd_wants`; round 2: `fcrew_run`, `fcrew_want`, `FOOD_CMD.farms_room`), `lua/dfllm/act.lua`
(`TOOL_DETAILS` cooks/brewers), `dfpilot/schema.py` (DECISION_NEEDED `cmds`), `dfpilot/fairplay.py` (`famine_crew`)

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

## Round 2 (review r15_famine_verdict): labor in a famine
- Cause (Inkintense y378-y383, i1 kern.log/events): `inspect workload` 2 of 39 idle, 4417 unclaimed jobs, FarmPlot 86,87,133
  `not suspended, no builder has taken it` (a FarmPlot wants the PLANT labor, M.BUILD_LABOR), kern.log `details: Planters ...
  mode EverybodyDoesThis`, `gather: Plant gatherers is everybody-does-this (the jobs wait for another reason)`, `labor: 4283
  of 4283 starving postings are stale (oldest Gather Plants)`, engine monitor (labormanager assigns nothing). Every dwarf held
  every everybody-does-this labor, the busy ones hauled, built and cleaned; nothing made the food anybody's job:
  economy.lua `gather_low` returns at an everybody-does-this detail, `cover_plan` sets `row.why` and adds nobody, T.starve
  (food_d <= 0) adds plain members (no effect on an everybody detail), `famine` only queues `labormanager allow-hunting /
  allow-fishing` (modern mode only).
- Fix: `M.fcrew_run` (T.fcrew, daily, after cover): in a famine (food below famine_days) or below famine_days of drink, not in
  modern labormanager, the kernel names a food crew of specialists through `act.work_detail(opts.only, keep = FCREW_KEEP)`:
  they keep PLANT, HERBALIST, COOK, BREWER, FISH, CLEAN_FISH, DISSECT_FISH, PROCESSPLANT, MILLER, BUTCHER, HAUL_FOOD and give
  up the everybody-does-this labors, so the food jobs are theirs. Specs (config `economy.famine_crew`): `farmers` 3 of
  Planters while a farm plot stands or is placed (they build it and plant), `cooks` 1 (a COOK detail, kitchen and
  ingredients), `brewers` 1 (a BREWER detail, still and brewable plants, drink below gather.drink_d), `gatherers` 2 only while
  the gathering detail is everybody-does-this (gather_low staffs it otherwise). Candidates as the gatherers' (never a soldier,
  noble, doctor, mood, tool member or sole key-labor holder, no patient; idle, then skill). Safety: new members only in
  PEACE/RECOVERY (a gatherer or a surface planter walks outside: never toward hostiles); a crew that stands keeps working in
  any mode (life-critical work is not parked); at most `share` 25 % of the adults, `step` 2 a day. Food and drink back at
  `off_days` 30: each goes back to every labor (off with opts.only; one who was a member before, or of an everybody detail,
  rejoins plainly). WORK_DETAIL why `famine_crew` / `famine_crew over`, kern.log `famine crew: ...`, the food decisions name it
  in `auto` (`food crew N (Planters 3, ...)`). act.work_detail accepts the details Cooks/Cooking/Cook/Brewers/... too.
- Fishing and hunting were already the kernel's in a famine (fish_want 'famine' with the zone the kernel paints, hunt_want);
  gathering is now the crew's where gather_low stops; brewing from gathered plants comes through the brewer spec (gathered
  brewable plants count as brew_g, the BUG-042 brew orders take them).
- Surface farm option (review): `bp.place farms surface:1` only in PEACE; otherwise the option is a farm room
  (`FOOD_CMD.farms_room`), economy.lua food_block.
- Test gap (review): tests/test_bug340_farms_emit_e2e.py runs follow's `_place_farms` with the real `cmd.send` / `emit_bp` on
  the BUG-316 live-shaped snapshot: no room site at plots 2 or 1, the PEACE surface farm is placed with plots 1; in ALERT
  nothing is written and the first error stands.

## Open
- A fort with no soil underground and no free surface soil (Drillchamber before y379): nothing to place; muddying stone
  needs water (never dug near water without Gordon).
- A quern / millstone (`Mill plants` 2183 d old) is not placed by the kernel.
- Inkintense's gathered plants are tree leaves (`493 inedible GINKGO:LEAF`, `cookable 0`): gathering does not feed that fort;
  its food must come from farms, fishing, hunting or trade. The crew farms; whether the FarmPlot is then built is live-untested.
- An automatic slaughter policy (butcher.mark stays the player's option).
- Whether DF keeps a specialist's dropped everybody-does-this labors off is taken from the Run 10 miners fix (opts.only);
  live-untested for Planters.

## Tests (fail on b35af6d)
- tests/lua/test_economy_fishing.lua: `BUG-340: food_low asks the caravans for food and seeds itself; each option carries
  a runnable command` (every cmd parses as `dfllm cmd <verb> '<json>'`), the food_low/BUG-258 tests (opts, cmds, d <= 1,024
  bytes encoded); test_economy.lua, test_economy_gather.lua (auto `trade`).
- tests/test_bug340_341_famine_mood.py (5): farm_tries, follow places on the first try with a site / raises the first
  error (no surface outside PEACE), the schema of `cmds` and each command's args, food_hint, famine urgent.
- Round 2: tests/lua/test_economy_fcrew.lua (3: a crew of farmers + gatherers on everybody details, the kept labors, guards,
  cap, back when food is back; gatherers only on an everybody detail; none in SIEGE / modern / without famine or farm plot);
  tests/lua/test_economy_fishing.lua `BUG-341 review: the farms option is a surface farm only in PEACE`;
  tests/test_bug340_farms_emit_e2e.py (2).

## Live check
Drillchamber/Inkintense after a reload and a follow restart: a farms PROJECT_REQUEST without a room site -> cli.log
`auto:farms BUG-340 ... placed with {'plots': 1}` or `{'surface': 1}` instead of AUTO_FAIL; `dfllm events --cls A` famine
lines carry `cmds`, each sent as it stands is accepted; `inspect what=trade` lists `food`, `seeds` while food < 30 d.
Round 2: Inkintense in a famine after a kernel reload: kern.log `famine crew: food N days ...: +k food specialists`,
WORK_DETAIL `Planters + <name> (famine crew farm ...)`, the FarmPlot taken by a builder, famine `auto` lists `crew`; once food
and drink stand at 30 days `famine crew ... back to every labor`.
