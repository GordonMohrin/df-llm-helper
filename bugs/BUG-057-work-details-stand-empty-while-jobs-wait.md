# BUG-057 Planters, Fisherdwarves and Plant gatherers stand at 0 members (or are "reset") while 122-565 PlantSeeds and GatherPlants jobs wait
Status: fixed in eb4d838 (offline, live-untested): the work details follow the demand (M.cover_run: farmers for the
unclaimed reachable PlantSeeds + HarvestPlants jobs above 20, gatherers for GatherPlants above 10, kept apart, never
shrinking while jobs wait), Fisherdwarves gets at least `min` fishers beside a fishing zone with raw fish or Fish jobs,
and every pass audits Planters / Plant gatherers / Fisherdwarves for members that vanished without the kernel
(kern.log `details: ... lost N members the kernel did not take off`, `inspect what=workload key=details`). Not decided
offline: who removed the 22 hand-added entries of note 54 (see below)
Severity: high (wrong decision: 30-70 % of the adults idle for years, food 17-41 days, 12 dwarves starved in a season)
Found: 2026-10-17 .. 2026-10-22, Run 12 (y501-y504), Run 13 (Wheelsblows, y512), Run 14 (y543, y577); notes 33,
35, 36, 46, 54, 63 of `bugs/RUN11-offene-bugs-und-FR.md`, from the game session's live reads
Module: `lua/dfllm/economy.lua` (tools, T.starve, M.gather_low, fish_want), `lua/dfllm/act.lua` (work_detail)

## Actual (live, from the notes)
- Run 12 y501 autumn d54: 122 PlantSeeds + 274 GatherPlants unclaimed, all 56 plots on the citizens' walk group, 819 seeds,
  only 4 dwarves hold PLANT and the kernel had made exactly those four "Plant gatherers" (the food_low detail): nobody
  planted. By hand 10 idle dwarves got `labors[PLANT]`: 34 -> 21 idle of 42 within a minute, the gather backlog went.
- Run 13 y512: `Planters` and `Fisherdwarves` on OnlySelected with 0 members; hand-set PLANT/FISH labors were reset again and
  again (PLANT 13 -> 0); 15 PlantSeeds unclaimed, famine phases.
- Run 14 y543: 421 PlantSeeds unclaimed at 33 of 41 idle; "the kernel sets Planters back to 6 members, my 22 entries
  were removed". y577 (note 63): `labormanager` was not the cause (`managed=0` for every kernel detail); `Fisherdwarves` AND
  `Plant gatherers` stood at 0 members, Planters at 6.

## Cause (proved from the code at f17e2b3)
1. **Nothing staffs Planters except the starvation handler.** `Planters` is no entry of `tools.details`
   (economy.lua:188-198: Miners, Woodcutters, Hunters, Fisherdwarves), so `tools()` (3354) never sizes it. The only code
   that adds to it is `T.starve` (6500): `fd <= starve.days` (0, config) AND a citizen over `starve.hunger` (6505), target
   `starve.planters` 4 (6517), `have = #assigned_units` (a detail holding 6 dead or foreign ids is "full"). At "food 17 d"
   or "food 41 d" it never runs, whatever the PlantSeeds queue says.
2. **Plant gatherers only at food_low.** `M.gather_low` (5363) acts only below `food.pre_days` 30 (or a drink shortage,
   5392-5394) and lets its members go at 60 food days: between 30 and 90 food days, where the notes stand ("food 41 d",
   "food 28 d"), nobody gathers, with 250-565 GatherPlants jobs open. Nothing looks at the HERBALIST holders (note 38:
   HERBALIST 0, PLANT 8).
3. **The gatherers were taken from the farmers.** `M.gather_cand` (5310) excludes only the *sole* holder of a key labor
   (5329): four PLANT holders were four candidates, idle ones first (the same four had nothing to plant because Planters
   stood empty), and the food_low step made them "Plant gatherers" (note 35).
4. **Fisherdwarves follow the food stock only.** `fish_want` (1562) returns 0 at `food_d >= food.want_days` (90, line 1572)
   and without a fishing zone; raw fish in the fort or open Fish jobs do not count. `tools()` then shrinks the kernel's
   members after `shrink_days`. Note 63's "Fisher >= 3 never reached" is this: the target is `ceil(cit/15)` capped at 3 and
   only below 90 food days.
5. **The reset to "6" is not in this code.** Every write to a detail's membership is a `K.act.work_detail` call
   (economy.lua:3403 and 3526 tools, 5378 and 5425 gather_low, 6555 starve) plus `work_detail_prune` (6433: ids of dead
   or non-citizens only). The only removals are: tools() shrinking Miners/Woodcutters/Hunters/Fisherdwarves members it
   added itself (`mine`), gather_low's off step for its own ids, and `act.work_detail` with `opts.only` taking a *Miner*
   out of the everybody-does-this details (act.lua `specialize`). Planters is touched by none of them while it is on
   "only selected". No constant 6 belongs to it (Miners `max` is 6). The comment at economy.lua:2721 already says what
   the game does with the other writer: "Lua writes to assigned_units alone set no labor". Leading hypothesis (not provable
   offline): the game reconciles a detail's members with the labor flags, so ids written into `assigned_units` by hand
   without `status.labors[PLANT]` vanish (note 54: 22 entries removed, 6 kept = the ones with the labor), and hand-set
   labors on a unit outside every selected detail are reset by the game (note 46: PLANT 13 -> 0).

## Fix
- **Demand rule** (`M.cover_run`, daily task `cover` after `tools`; PEACE/RECOVERY, not labormanager modern; config
  `economy.cover`): reachable unclaimed PlantSeeds + HarvestPlants above `min_jobs` 20 -> Planters gets `ceil(n / farm_per 10)`
  members (`farm_min` 2 .. `farm_max` 12); GatherPlants above `gather_jobs` 10 -> Plant gatherers `ceil(n / gather_per 25)`
  (2 .. 8). "Reachable" = the first 200/400 open job positions against the citizens' walk groups (snapshot.groups, as
  `inspect workload`). All cover details together hold at most `share` 50 % of the adults, `step` 4 added a day. Candidates:
  idle first, PLANT holders first for the farmers, never a soldier, doctor, noble, mood dwarf, tool-detail member or the sole
  holder of another key labor; a farmer is never taken from the gatherers and the other way round, the PLANT holders are
  not made gatherers while farm jobs above the line wait. A detail on "nobody does this" is set to "only selected"
  (`opts.select`); an everybody-does-this one is left alone (the jobs wait for another reason, `inspect` says so).
- **Never shrinks while jobs wait.** Members the kernel added (persist `m.economy.cover.mine`) leave only after `idle_days` 7
  daily passes with no unclaimed job of the kind, down to the minimum; the player's members stay and count. A member
  without the detail's labor gets it again through the detail every `tools.repair_days`.
- **Fishers.** `fish_want` adds a floor: with a fishing zone and at least `fish.min` 5 raw fish in the fort or an open Fish job, at least
  `min` 3 fishers (one per `min_per` 6 citizens, at least one: a fort of 8 gets 1) whatever the food stock says; the
  Fisherdwarves spec's detail is set to "only selected" with its first member. PEACE only, as before.
- **Audit** (`M.cv_audit`, every pass, also for Fisherdwarves): members that were in the detail at the last pass, are not
  now, were not taken off by the kernel (`M.cv_off` at every kernel removal), are alive citizens and in no squad ->
  `details: Planters lost 22 members the kernel did not take off (6 left, mode OnlySelectedDoesThis, 0 of them still hold
  PLANT): ids`; a mode change of the detail the same way; counted in `inspect workload key=details`
  (`details[].lost`, `mine`, `mode`, the last cover rows: unclaimed / reachable / holders / members / target / why not).
- **Gather zone and withdrawal** (FR-72, DECISIONS 10): `act.plant_ungather` withdraws GatherPlants designations seen off the
  citizens' walk group in two daily passes in a row (not while a gate bridge is not down, not outside PEACE/RECOVERY) and every
  sampled one when no GatherPlants job had a worker for `stale_days` 30 (not below the food pre-alarm line), at most
  `unmark_max` 200 a day; the runner's temporary `dfllm-gather` zone is cut to rectangles on the walk group (BUG-074, package C4 replaced the shrink-by-`snapshot.far` first built here).
- Contracts and docs: CONTRACTS §7 (`inspect` key, `runner.lost`, `snapshot.plot_under`, `act.plant_ungather`), §9.17
  (`economy.cover`, `economy.farms`), WORK_DETAIL `why` `cover` / `cover idle`.

## Not decided offline (the read-only live data that decides it)
- Who removed the 22 hand-added Planters entries. Since this fix kern.log says it on the next pass: `details: Planters lost N
  members the kernel did not take off (... K of them still hold PLANT)`. K = 0 for all N confirms the hypothesis (the game
  drops a member without the labor); K = N means a member list rewritten with the labors kept (a plugin, the player).
  By hand: read `unit.status.labors.PLANT` of a hand-added id and the detail's `assigned_units` every few seconds.
- Whether the game puts "Planters" back to EverybodyDoesThis after a load: the same log line (`changed its mode`).
- The real `Planters` / `Plant gatherers` labor grants of DF 53.16 (`allowed_labors`): `inspect key=details` prints the rows
  the cover pass found (`detail`, `why`: "no work detail grants PLANT").

## Tests
`tests/lua/test_economy_cover.lua` (farmers follow PlantSeeds, gatherers GatherPlants, kept apart, "nobody does this"
detail, everybody-does-this, SIEGE, no shrink while jobs wait / shrink after idle_days / the player's member stays,
unreachable jobs, fishers with raw fish or Fish jobs and a fort of 8, vanished members named, the kernel's own removals not),
`tests/lua/test_economy_gather.lua` (BUG-038 unchanged, `cover.on = false` there); each new test fails on f17e2b3.

Related: BUG-038 (gather at food_low, kept), FR-25 (starvation handler, kept), FR-72, notes 34/54 (timestream and civ_alert
after a gremlin alarm are package C1, not here).
