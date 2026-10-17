# BUG-038 No fishery after the sieges destroyed it; 450 GatherPlants jobs nobody takes at food_low
Status: fixed in ef88f66 (offline, live-untested): the fishery request keeps its clock when a fishery is seen, `queued` holds only
for a moving fishery project, follow places the fishery although the fort manifest lists a destroyed one, plant
gatherers join at food_low with unclaimed GatherPlants jobs and leave when food is back, the food decisions name what
the kernel did itself (`auto`)
Severity: high (wrong decision: food fell from 51 to 22 days beside 138 raw fish)
Found: 2026-10-17, Run 11 fort Kilrudrabed (site98), y451 summer d40-d45, dfpilot main d782dfa, pop ~26 adults after
several sieges, from the game session's report (`inspect workload`, kern.log, events)
Module: `lua/dfllm/economy.lua` (M.fishery_request, the food decisions, T.starve), `dfpilot/cmd.py` (place),
`dfpilot/wake.py` (follow's fishery placement), `lua/dfllm/act.lua` (work_detail)

## Actual
- DECISION_NEEDED food_low (26 days), options fishery / trade.want food / butcher / gather; fisheries 0, 138 FISH_RAW.
  The game session placed a fishery by hand (quickfort, 121,115,139).
- kern.log: `fishery: none built, 128 raw fish, fishers at work, food 51 days: request` again and again down to `food
  22 days`; one PROJECT_REQUEST workshops why=fishery was seen (#18323, y451 summer d40, food 22 d); no workshops
  project was ever open, follow placed nothing.
- `inspect workload`: `unclaimed: GatherPlants 450, FellTree 7, PlantSeeds 5, MakeTool 1`, `unreachable GatherPlants 46`;
  only 4 of 26 idle.

## Causes (from the code, d782dfa)
1. **The request clock was cleared by any fishery seen** (economy.lua:4653 `p.fishery_req = nil` whenever the facts
   counted a built Fishery). A fishery built from a request and destroyed in the next siege was asked for again at once,
   each time; a fishery that flickers in the facts restarts the period. Within one kernel boot this is the only way two
   `request` lines can come closer than `food.request_days` (14): the line is logged and emitted back to back
   (4664-4667, one caller T.fishz 4871 once per full run), `p` is the cached persist table (persist.lua:36-52) and
   K.emit has no dedupe, rate limit or class-B suppression (kern.lua:160-182; `emit_once` is only for the kernel's own
   A events). So log lines and events are 1:1 within a boot; see "Not decided offline".
2. **`queued` held for any workshops project** (4660-4661): `runner.pending('workshops') > 0` silenced the request for
   up to 4 periods (56 days), also for a project of moodable shops without a fishery or one the runner never starts
   (BUG-037's stuck queue).
3. **follow could not place a fishery the fort manifest still lists** (dfpilot/cmd.py:873-880): `place()` drops an
   `add` type that `workshops_missing()` finds in the fort manifest, which merges every bp/*.json fragment and the
   kernel manifest built or not (cmd.py:143-166): fortcore stage 1 lists a Fishery (dfpilot/bp/fortcore.py:54, since
   2752e67), and so does a workshops project that built the fishery before the siege destroyed it. With `add` gone and
   every moodable type skipped the template raises (bp/rooms.py:202-203; with the real templates: `BpError
   bp.sites.rank(workshops): workshops: nothing left to build`): follow's `_place` turns it into an AUTO_FAIL wake and
   no project is queued (tests/test_cli_wake.py reproduces the dropped `add`).
4. **Nobody staffs the plant gatherers before a starvation.** FR-25 (T.starve, economy.lua:5906) adds gatherers only at
   `food_d <= starve.days` (0) with hungry citizens. The GatherPlants jobs come from the runner's temporary
   `dfllm-gather` zone (runner.lua:2607-2681: below 30 food days in spring-autumn, up to 800 tiles around the fortcore
   anchor, removed above 120 days) and from FR-25's marks (up to `plants_max` 200 reachable shrubs a run, only in a
   starvation); the game session drew no zone. Who holds the plant gathering labor was never checked at food_low.
5. The food_low/famine text listed the fishery as the player's decision although the kernel asks for it itself.

## Fix
- **Fishery request** (M.fishery_request, M.fishery_proj): a fishery seen standing leaves the clock alone (a fishery
  destroyed within the period waits for it; one destroyed long after its request is asked at once). `queued` holds only
  while a pending `workshops` project whose doc's manifest lists a Fishery (runner's `projects` list and `bp.<id>` doc,
  read-only; fortcore is left out: its stage 1 fishery may be long built and gone) is not halted (`blocked` '' or
  'stalled') and moved (stage or pct, `p.fishery_q`) within `food.request_days`, at most 4 periods; else the request goes
  out again. kern.log names why: `request (first request)`, `(16 days since the last request)`, `(project w2 has not
  moved for 14 days)`, `(project w2 build_lost)`.
- **follow** (wake.py, cmd.py): the fishery request's placement carries `need=["Fishery"]` through `send`/`emit_bp` to
  `place()`, which keeps a needed `add` type although the manifest lists it; every other placement keeps the dedupe
  (never a second still).
- **Plant gatherers at food_low** (M.gather_low, task `gather` before the food decisions): below `food.pre_days` (30,
  the food_low line; famine included), in PEACE/RECOVERY, not in labormanager's modern mode, with >= `gather.min_jobs`
  (10) unclaimed GatherPlants jobs in the tool details' daily job census (tool_jobs counts GatherPlants now; no scan of
  its own): the plant gathering detail (`starve.details.gatherers` by name, else the one granting HERBALIST) gets
  members up to `gather.n` (4): idle first, then HERBALISM, then id; never a soldier, noble, mood, doctor (DIAGNOSE,
  SURGERY, BONE_SETTING), the only holder of a key labor or a tool detail's member. A detail on "nobody does this" is
  set to "only selected" (act.work_detail `opts.select`, the work details screen's toggle). The members economy added
  (`p.gather`) leave at `gather.off_days` (60) food days; nothing changes in between. One kern.log line per change
  (`gather: food 13 days, 450 unclaimed GatherPlants jobs: Plant gatherers +4 (...), 4 of 4`), WORK_DETAIL (B) why
  `food_low` / `food_low over` per member.
- **Decisions:** food_low/famine name what the kernel does itself in `q` (`...; auto: fishery asked (138 raw fish), 4
  gatherers added (450 gather jobs). Also: ...`), the line (`...: no kitchen; auto: fishery, gather`) and `d.auto`
  (`fishery`, `gather`); the fishery is no blocker, no option and no cadence news while its request is out or queued.
  A gatherer step that cannot act is a blocker `gather: no plant gathering detail` / `... is everybody-does-this` /
  `no free citizen`.
- The 46 unreachable GatherPlants jobs: left alone (no citizen can take them, they block nothing; `inspect workload`
  reports them). The runner's gather zone around the fortcore anchor reaches outside the walls; changing it is a
  runner matter (not touched here).

## Live confirmed (Run 11, y452 winter d20, read-only, before the reload to ba45a2a)
- The cadence held: consecutive `fishery: none built` lines at game ticks 181900330, 181933241 (+32911), 181962051
  (+28810), 181991352 (+29301); the gaps of 115-400 were the 1st column (real seconds). Causes 1/2 did not fire here.
- Cause 3 is the live cause: `<save>/cli.log` shows `AUTO_FAIL {} workshops: bp.sites.rank(workshops): workshops:
  nothing left to build` right after each request (epoch 1792219335, 1792219534, 1792219730 after the kern.log
  requests at 1792219316/515/711); no `no sites snapshot`.
- Still open: the gatherers at food_low (food was at 700+ days after the reload) and the follow placement with
  `need=["Fishery"]` at the next request.

## Not decided offline (the read-only live data that decides it)
- The repeated `request` lines with one event: the 2nd column (game tick) of consecutive `fishery: none built` lines in
  kern.log/kern.1.log. >= 16,800 ticks apart: the cadence held and the gaps of 115-400 were the 1st column (real
  seconds); then `dfllm events --type PROJECT_REQUEST --limit 0` (the default shows the newest 30 of every tpl) counts
  the fishery requests. Closer: a fishery was counted as built in between (cause 1; the new code keeps the clock) or
  the kernel booted between them.
- Why follow placed nothing after #18323: `<save>/cli.log` lines of `follow` around it (`auto:fishery`, `AUTO_FAIL
  workshops: ...nothing left to build` = cause 3, `no sites snapshot`, a refused bp.place), whether follow ran without
  `--no-auto`, and `grep -l Fishery <save>/bp/*.json <save>/manifest.json`.
- Who designated the 450 GatherPlants jobs: kern.log `food N days: gather zone WxH at x,y on z ...` (runner) or
  `starvation: ... N shrubs marked for gathering` (FR-25).
- Whether DF 53 has a plant gathering work detail by default and in which mode: the `gather:` kern.log line or the
  decision's `gather: no plant gathering detail`.
- A fishery-only workshops project is runner kind `supply`: while a seal is open in PEACE it pauses unless food is below
  `seal_first.food_d` (30) (CONTRACTS §9 class). At food 51 d with Run 11's open seal it would have waited.

## Tests
`tests/lua/test_economy_fishing.lua` (the clock after a fishery seen and destroyed; queued only for a moving fishery
project; a halted one; the player's own fishery project; food_low with the fishery in `auto`),
`tests/lua/test_economy_gather.lua` (gatherers at food_low: who joins, the decision text, the band, off when food is
back, a "nobody does this" detail, too few jobs, modern mode, SIEGE, no detail), `tests/lua/test_act_supply.lua`
(opts.select), `tests/lua/test_economy.lua`, `tests/lua/test_economy_food.lua`, `tests/test_cli_wake.py` (the fishery
placed although the manifest lists one; a hand placement keeps the dedupe); each new test fails on d782dfa.

Related: BUG-037 (the project queue), FR-25 (starvation), Run 11 fishery (2752e67).
