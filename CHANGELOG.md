# CHANGELOG dfpilot

## Gates: call them in first, an occupied footprint is waiting, slow pulls go to the backup lever, BUG-027 (2026-10-16)
- The lockdown's deferred civ alert sounds at once while a bridge it wants up waits for units on its footprint (call the civilians in first; the gate raises
  once the footprint is clear; reflex.lua `alert_due`).
- The `up` deadline does not count the ticks a bridge waited for units on its footprint; such a bridge is GATE_FAIL `blocked` only after 900 ticks of waiting on
  end. A pull under way at the deadline (Run 10: `GATE_FAIL timeout`, lever latency 11-19 s at 30 t/s) goes once to another linked lever and gets max(300, the
  measured lever latency) ticks more, then GATE_FAIL `slow`; the text names the real seconds too.
- siege's BREACH at T+900 skips a bridge `gate.waiting` reports (`blocked`, `pulling`) while no hostile is within 10 tiles of it (Run 10: `BREACH O1 not up at
  T+900` with the pulls under way).
- Tests: three cases in `tests/lua/test_siege.lua`, one in `tests/lua/test_gate_footprint.lua`.

## Bridges are never pulled onto a unit, BUG-027 (2026-10-16)
- Run 10 Handlelock: siege raised B1 (building 17880) onto a recruit and, a season later, a miner with the enemy far away. Every pull (raise and lower, every mode)
  now waits while a living unit that is not hostile (citizens, residents, soldiers and recruits, insane citizens, the fort's tame animals) stands on the footprint
  or next to it; a pending pull of ours is cancelled when one comes that close (re-checked every frame while it is pending) and queued again once clear.
- The old SIEGE/BREACH rule (raise after 300 ticks onto whoever stood there, no margin, no pending re-check) is gone. A raise goes ahead onto units only with a
  visible hostile within `force_near` tiles (config/reflex.json `gate.force_near`, default 3, 0 = never); new class-A event `GATE_FORCED` names them.
- GATE (C) and GATE_FAIL `blocked` name the units (`units`, `pos`; a soldier with his squad's station order).
- Stop-gap `gate.manual` (config/reflex.json): bridge names or building ids that get no automatic pull, e.g. `"gate": {"manual": ["B1"]}` and a kernel reboot.
  It takes the bridge out of the defense (GATE_FAIL `manual`, BREACH at T+900 for an outer/inner one); prefer the fix. Removing `gates` from the reflex
  defaults would not help: siege raises B1 itself.
- Tests: `tests/lua/test_gate_footprint.lua` (new), seven cases in `tests/lua/test_siege.lua` (the 300-ticks case replaced).

## Trade: retry before the caravan leaves, diagnostics, ledger for lost visits, BUG-026 (2026-10-16)
- A retry after `ui_timeout` etc. waits at most `time left - 400` ticks (min 100) instead of a fixed 1200, so it still runs before the caravan leaves.
- `CARAVAN retry/failed` events carry `ph`, `ph_ms` and `left` (phase that timed out, real ms in it, ticks the caravan stays).
- A caravan that reached the depot and left without a ledger entry gets a `TRADE_LEDGER` entry with `left_untraded`.
- Tests: two new cases in `tests/lua/test_trade.lua`.

## Trade follows the depot the merchants use, BUG-025 (2026-10-16)
- `find_depot` prefers the built depot holding the most trader-flagged items (the merchants' goods), then the manifest depot, then the first built one. Before, a second
  hand-built depot made `inspect what=trade` and the visit logic look at an empty building: Catten's caravan ended `nothing_listed` while 49 goods lay in the other depot.
- Test `BUG-025` in `tests/lua/test_trade_ledger.lua`.

## Trade: sale goods once per visit, none for empty caravans, blocked visits are reported, BUG-016 (2026-10-15)
- **Sale items are marked for the depot once per visit** (`v.brought` in the visit record) instead of once per attempt: each `ui_busy`/`ui_timeout` retry
  used to mark another 100 items, which kept ~100 `BringItemToDepot` jobs open and starved planting.
- **A caravan without goods** (`#caravan.goods` and the depot's trader items both 0 for `NOGOODS_WAIT` = 1200 ticks) ends the visit `nothing_listed` and no hauler is sent.
- **`CARAVAN` event `phase=blocked`** (once per visit, with the focus string) when a player screen keeps the trade from starting; the screen itself is still never touched.
- Tests: three new cases in `tests/lua/test_trade.lua` (retry, empty caravan, blocked event); `trade_world` counts `bring` calls.

## Lever pulls under the civ alert, BUG-013/BUG-014 (2026-10-15; commits 055c92f, 413f614, offline, live-untested)
- **BUG-013:** while a pull is pending on levers outside the alert's burrow, the alert lists seal's lever burrow
  `Hebel+` (the linked lever tiles; a confined civilian takes only jobs inside its burrows but walks outside them), not
  in BREACH; the lockdown's alert waits for the pulls (`gate.pulls`), at most 2x the last lever latency (450-1500 ticks,
  900 unmeasured), at once only with a hostile near a citizen; a door waits 450 ticks after the alert called the
  citizens in; texts `gates: 2 of 4 up, 2 pulls blocked (levers outside the alert burrow)`, GATE_FAIL `outside_alert`;
  LOCKDOWN_END turns the alert off before the lowering pulls. Test `tests/lua/test_lockdown_gates.lua`.
  **BUG-014:** the autolabor guard reads the switch back with `autolabor mode` and takes "not enabled in legacy mode"
  as not legacy; a working switch is one kern.log line, only a failed one is AUTOLABOR_LEGACY (A).

## Death causes and death clusters, FR-64 (2026-10-15; commit 31a32cc, offline, live-untested)
- **DEATH says why:** new library `dfllm.deaths` (care): the death incident (`counters.death_id` -> `df.incident`
  `death_cause`, `criminal`), the unit sheet's `counters.death_cause`, the announcement naming the unit
  (`world.status.reports`, continuation lines joined), the thirst/hunger timers; a strange mood first. Categories
  dehydrated, starved, killed (race + unit), drowned, suffocated, bled, mood, old_age, crushed, burned, infection,
  unknown; `citizen 25889 died: dehydrated (incident THIRST; thirst 18879; patient)`. A death still "missing" in the
  unit list gets its cause once found (a second DEATH, `revised`). DEATHS_3PLUS names the causes.
- **DEATH_CLUSTER (B)** for >= 2 deaths of one cause or >= 3 of any within 28 days, **DEATHS_PREVENTABLE (A)** as well for
  dehydration/starvation with the stock days and the next step (`inspect reach`, refuge, hospital water); repeats only
  for a new death (util/cadence). `status`: `deaths (season) dehydrated 2, mood 1` (state `care.died`); `brief`: the
  season's dead per cause. Live check: after a death `dfllm events --type DEATH` shows a cause other than `unknown`
  for a found body, and `dtype` matches the unit list's death reason.

## Arrival lockdown: civ alert and entrance doors, BUG-011/BUG-012 (2026-10-15; commits 4e2b43c, 0faebcc, offline, live-untested)
- **BUG-011:** siege's step and `hold_alert` share one decision (seal picks the burrow) and nothing writes
  `civ_alert(false)` while a lockdown holds the alert; when every burrow fails, a lockdown keeps `Innen+` (painted at
  once if missing); ARRIVAL/LOCKDOWN say what holds (`alert: Innen+ (REFUGE_FAIL Kern+, lockdown fallback)`,
  `alert: none (...)`), whole parts kept within 200 bytes. **BUG-012:** seal's entrance BFS lists each opening's doors
  (on it, first on its route toward the citizens, within 3 steps inside; revealed tiles), `seal.entrance_doors` feeds
  the reflex, the text names openings without a door (`partial lockdown: ... has no door`), the undo opens exactly the
  doors it forbade. Test `tests/lua/test_lockdown.lua`. Live check in `bugs/BUG-011`, `bugs/BUG-012`.
- **Follow-up (0faebcc):** nobody is locked out with the army: an entrance door is forbidden only once no citizen is on
  its outside side (`seal.door_outside`: open sky of its walk group, the porch of its opening, the doorway), at once
  with a visible hostile within 15 tiles, at the latest 450 ticks after the lockdown wanted the doors; texts and
  `status` say `doors 0 forbidden, 1 waiting for 2 citizens outside` (state `alarm.doors/dwait/dout`). seal diffs the
  perimeter after every episode (ALERT, siege, reflex lockdown) once the fort is quiet again, so a wall lost in a
  small ambush is re-queued and PERIMETER_BROKEN fires.

## Live-test bugs BUG-003/004/005/008/009/010 (2026-10-15; commits b01bec4, 7006350, 9b9dcdc, 1d9b6a9; offline, live-untested)
- **BUG-009/004/005 (nothing got built, every caravan lost):** economy's daily FR-16 pass unforbids forbidden items on
  the footprints of suspended constructions (new `snapshot.items_at`, revealed tiles; mood reserve, corpses, dead
  dwarves' items skipped) and forbidden loose items of the class a planned building waits for, verifies each resume a
  frame later, counts failed resumes per job, raises DECISION_NEEDED `build_blocked` after 3 and moves a stuck trade
  depot inside the entrance after 5 (`runner.depot_move`, PEACE, no fortcore depot). JOBS_SUSPENDED names the reason and
  repeats only on change; DEPOT_MISSING says "being built" only while the depot progresses. care's mood reserve never
  forbids on a building site.
- **BUG-003:** a body with remains in a coffin is buried; `inspect tombs` shows the acts of the last acting run (`last`)
  and rebuilds a stale index (`fresh`).
- **BUG-008:** new `util/cadence.lua`: standing class-A events repeat only for news and after max(game cadence, 10 min
  wall clock) (GHOSTS, MOOD_RISK, HOSPITAL_DRY, coffin and build decisions); NO_DEPOT once per caravan visit. Open for the
  seal work: SEAL_LEAK and REFUGE_FAIL (seal.lua) still repeat on game time.
- **BUG-010:** baseline switches an enabled legacy autolabor to monitor in its boot step (init), on every full apply
  and on economy's daily engine read; AUTOLABOR_LEGACY (A, new event).
- Live check: the four stuck sites of the Run 9 save get built; DEPOT_MISSING text; `inspect tombs` `last`; one GHOSTS
  per news; `autolabor` mode monitor after a load. Details per bug in `bugs/`.

## Coffin provisioner (2026-10-15, FR-61; commit fcc1f8a, offline, live-untested)
- care keeps free usable coffins >= unburied citizen bodies without a usable tomb + `care.coffin_reserve` (10): rows of
  coffins with aisles inside a free ring in dug space that stands (crypt, core, citizens; roofed, no zone, walk group,
  away from the entrances) through the new `runner.coffins`, ConstructCoffin orders in hard stone, else wood (soft
  stone is refused), `PROJECT_REQUEST tombs why=no_space` / DECISION_NEEDED `coffin_space` or `coffin_material`;
  state `care.coffins`, a `coffins` status line, `inspect what=tombs` `prov`. FR-27: `bp.place` refuses a second
  tomb zone on a tile. Live check: `inspect tombs` on the Run 9 save (want/short/order, the project's tiles in a free
  hall), the ConstructCoffin order's material, the coffins built and zoned, `status` coffins line.

## Kernel cost on a big fort (2026-10-15, FR-62; offline, live-untested)
- Commit 501b08d: `repeat` in perf.csv is DFHack's timing of the whole kernel callback (a cross-check, no longer a
  doctor module); cost owners `k.state/k.io/k.persist/k.inbox/k.events/kern`, persist booked to the key's module, big
  keys written at most every 60 s; pacing by ms share with a PEACE pool (`util/sched.lua`, also in k_mock), economy
  and care cadence x load (≤ 3); demotion hysteresis, KERNEL_SLOW once per module per 6 h; selftest `budget` over the
  last minute against the fort-size budget (35 ms/s for 402 units), naming the top owners; cheaper sense and economy
  per-unit/per-item paths; luahost runs get their own TEMP (the test_kern_perf flakes). Run 9 model: 84 -> 24.5 ms/s.

## Run 9 alarm-to-action (2026-10-15): wake at once, clock governor, arrival lockdown, interrupt channel
Run 9 (14.10.2026): an army with two cave dragons walked in over lowered drawbridges; 39 of 48 citizens died within
76 s of real time at ~400 ticks/s. Commit 22ccd1c, the deferred civ alert in the commit after 2058a1d; offline (k_mock,
luahost, pytest), live-untested. FR status: docs/feature-requests/README.md.
- **Wake at once:** `SIEGE_START` and `INVASION` are class A. `follow` puts them right after BREACH and wakes at once
  (no merge wait, no hourly limit, one per type per 60 s) on BREACH, SIEGE_START, INVASION, LOCKDOWN and every
  interrupt.
- **FR-51 clock governor (arbiter):** the vanilla FPS cap follows the mode (SIEGE/BREACH/DRILL 30, ALERT 100,
  PEACE/RECOVERY the captured original; same restore.json mechanism as the supply brake, the crash heal restores any
  lowered cap); timestream is off whenever it would run above the cap; a reflex lockdown holds the siege cap from the
  arrival announcement until threat 0 for 2 game days. `tempo.lower` lowers the cap too (STATUS §6 gap 10). Knobs in
  the new `config/reflex.json`. State `clock`, `owners.tempo` `clock`; `status`: `clock: held 30 t/s, reason siege`.
- **FR-36/49/52 reflex module (`lua/dfllm/reflex.lua`, critical):** on a threat popup (the arbiter hands it over and
  dismisses it only afterwards), an arrival report, INVASION or the first armed hostile in sight, in the same step:
  every lever-linked drawbridge up (manifest outer/inner and every bridge outside the manifest: works on a fort
  without fortcore), the entrance doors forbidden (new `act.door_forbid`, the door sheet toggle), clock held, and the
  civ alert on Kern+ once the gates are up (at most 450 ticks later: live L3 lost every lever pull to an early alert); ARRIVAL (A) carries the text and what was done. Undone after threat 0 for 2 days (LOCKDOWN_END).
  `sealed_ticks` counts the raised unmanaged bridges, so SIEGE_END no longer says "sealed 0 ticks" without a manifest.
- **FR-53 interrupt channel:** ARRIVAL, INTRUDER, PREDATOR, DEATHS_3PLUS and NO_DEPOT go to `<save>/alarm.txt` at once;
  `dfllm wait --until-interrupt [--timeout S]` returns on them, `dfllm ack` (verb `ack`) records the operator's ack,
  and an interrupt unacked for `ack_timeout_s` (60) gets its lockdown default from the kernel (LOCKDOWN, A).
  `status` line 1 starts with `DEFCON n`.
- **FR-55:** decision D-14 `peace_gates` (`down` default, justified in DECISIONS.md: caravan wagons, migrants and the
  fort's outdoor work need the way; `up` keeps the gates up outside caravan/migrant windows); `lever_latency_s` and
  pending pulls in `status` (state `lever`).
- **FR-58:** `status` shows an ETA from the nearest visible invader to the nearest entrance.
- `tools/run_guard.*` (superseded) and `tools/run_rescue.*` (partly superseded) carry notes; nothing deleted.

## Burial, ghosts, hospital water, doctors, moods (2026-10-15, Run 9 FRs; offline, live-untested)
Runs 7-9 were lost largely to unburied dead and ghosts and to patients dying of thirst next to full drink stores.
- **Tombs (FR-04/26/27/41/42/45, care):** a tomb phase each care run indexes coffins, tomb zones, Bedroom zones and
  piles. Outside SIEGE/BREACH (config `care.tomb_repair`, default on; verb `tombs.repair` forces one run in any mode)
  it keeps one zone per coffin tile (stacked 1x1 zones removed; the zone of the body inside or of an unburied body
  kept; a living citizen's reserved tomb never), removes 1x1 zones without a coffin (not while a tombs project is
  pending), frees zones of bodiless or elsewhere-buried dead and of unburied dead over an unusable coffin (none,
  taken, shared, inside a Bedroom zone), opens free zones to citizens and assigns every unburied citizen without a
  usable zone a free one (new act `tomb_zone`, the zone sheet). Then DFHack `entomb --unit <id> --haul-now`
  (allowlisted in that form only) per unburied body with a usable zone and no job, inside Kern+ or at clean-up
  time; PlaceItemInTomb jobs are counted, a body still without a job after 2 days is `no_job` (3 tries, then
  `tombs.repair`). A free tomb now means a usable one (built empty coffin, one active zone, no other zone).
- **GHOSTS (A):** as soon as a citizen ghost exists or a citizen body lies unburied longer than 3 days
  (`corpse_old`), with the causes per body (no_coffin, no_zone, coffin_taken, zone_shared, bedroom, zone_owner,
  unflagged, unreachable, in_stockpile, undiscovered, no_job; no_body for a ghost without remains); again when the
  set grows, else weekly. `inspect what=tombs` (care) lists coffins, zones, unburied bodies, ghosts and repair acts.
- **Doctors (FR-48, care):** at least `care.doctors` (4) living adult civilians with DIAGNOSE/SURGERY/BONE_SETTING
  (new act `medic`; partial doctors first, then medical skill; never soldiers, moody dwarves, children or patients);
  hospital posts that are vacant or held by the dead are filled with doctors without another post (new act
  `hospital_post`).
- **Hospital water truth (FR-31/33a/34/47, water):** accepted water is a built well with water down its shaft or an
  active Water Source zone with water >= 4/7 on its own level (`water.zone_below` for a brook bed, off); 1/7 seepage no
  longer counts. HOSPITAL_DRY (A) replaces DECISION_NEEDED `hospital_water`: a hospital location (or a pending
  hospital project with no accepted water anywhere) without an accepted source within 30 tiles, at the start of the
  dry episode, then weekly with patients, else monthly, with a one-line recipe. `patient_thirst` now fires at 30,000
  (was 40,000) with the recipe ("delete the hospital zone or carry water"), the caregivers with
  FEED_WATER_CIVILIANS and the buckets. `inspect what=water_sources` (water) scans revealed water >= 4/7 around the
  hospital (else the citizens), 30 tiles wide and 3 levels up and down, through the new `snapshot.liquids`, and
  lists per water body an accepted zone or well, a bank the citizens reach, else the shortest dig through revealed
  natural wall; the first HOSPITAL_DRY waits for that scan (a few frames).
- **Moods (FR-44, care):** MOOD_RISK (A) when a strange mood's needs are first known and any is missing (the
  classes), and when the moody dwarf passes thirst 30,000 or hunger 50,000 (every 2 days). Decision: the mood job is
  never cancelled; DF's UI has no cancel for it, act has no job removal, and a removed job crashed DF in Run 9.
- **Contract:** events GHOSTS (care), HOSPITAL_DRY (water), MOOD_RISK (care), all class A; verb `tombs.repair`;
  `inspect what=tombs|water_sources` routed by kern (and k_mock) to `care.inspect` / `water.inspect`; acts
  `tomb_zone`, `medic`, `hospital_post` (care); `snapshot.liquids`; lint lets only `act.medic` and
  `act.work_detail` write labors. `follow` names a next step for the three new events; RULES §6/§7 list them.
- **tools/run_release.lua:** the blocks these replace carry a "superseded by kernel" note (kept, not deleted).
- **Tests:** tests/lua/test_care_fr.lua, test_water_fr.lua, care_fr_scenario.lua (real kernel), tests/test_care_fr_files.py.
- **Live checks:** `entomb --unit <id> --haul-now` keeps an assigned tomb and posts PlaceItemInTomb jobs; `entomb` is
  not armok-tagged (kern.log would say "armok commands removed"); setOwner on a dead unit's tomb zone; a Water Source
  zone on a brook top (zone_below); hospital posts and `unit.occupations`; labormanager in monitor mode keeps the
  doctor labors.

## Feature requests: orders, jobs, food, trade, loot, follow watchdog (2026-10-15, branch fr-econ)
Offline (k_mock + pytest), live-untested. Details and statuses: docs/feature-requests/README.md.
- **FR-39 crash guard:** `act.workorder`, the new inbox verb `order.add` and `schema.validate_args` refuse
  MakeArmor/Pants/Shoes/Gloves/Helm/Weapon/Ammo/Shield (and TrapComponent/Tool/Toy) orders without
  `item_subtype` (DF 53.16 crashes when a dwarf takes such a job); economy removes existing ones every run
  (`act.order_remove`, ORDER_BAD class A); state `orders.bad`, `status` UNSAFE, `doctor` problem.
- **FR-01/FR-10 order sanity and pruner:** daily check of every open order (built workshop, input on the citizens'
  walkable group, a worker with the labor; `lua/dfllm/orderlib.lua`), ORDER_STUCK (B) after 3 days, orders with
  10 "Needs ..." cancels in 7 days removed (supply orders kept); `inspect what=orders`; state `orders.n/stuck`.
- **FR-16/FR-40:** suspended ConstructBuilding jobs nobody keeps suspended are resumed (`act.job_resume`), the rest
  reported by reason (JOBS_SUSPENDED); verb `jobs.release {all?, preventblocking?}`, preventblocking a persisted
  fort decision (baseline never sets it); `act.work_detail_prune` drops dead citizens' ids from every work detail;
  `inspect what=workload` (idle adults, unclaimed jobs by type, top cancel reasons, free picks/axes).
- **FR-17:** every empty season slot of every built farm plot gets a crop (`act.farm_crop`), underground all year.
- **FR-23/FR-50:** drink, food and seeds in a forbidden container of any item type count as forbidden
  (`seeds_ok`/`seeds_forb`); containers, seeds and seed bags are unforbidden on revealed, reachable tiles.
- **FR-25 starvation handler:** gather designations on reachable visible edible shrubs (`act.plant_gather`),
  planters and plant gatherers, forbidden food unforbidden, DECISION_NEEDED starvation naming who is cut off.
- **FR-46:** military unforbids the invaders' forbidden metal gear for the armory; state `mil.free`, `status`
  prints free metal by category.
- **FR-43:** `runner.depot_keep` holds a `depot` project (5x5 at manifest.depot or the last depot seen);
  DEPOT_MISSING (class A) when a caravan finds no depot.
- **FR-32/FR-18:** TRADE_LEDGER (B) per visit (sold, bought, unmet wants and why), persist `m.trade.ledger`;
  `inspect what=trade` lists the merchant goods at the open depot with their want tokens.
- **FR-29:** `dfllm follow` beats into `<save>/.follow.hb`; `status` prints `follow: OFF (last heartbeat ...)`,
  `doctor` warns.
- Kernel: an `inspect` target kern does not answer goes to the module with `M.inspect[what]`; `item_flag` now also
  for economy and military. Contracts (CONTRACTS §5-§13, appendix), RULES and DESIGN updated; the replaced blocks
  of `tools/run_release.lua` carry "superseded by kernel" notes. Changed kernel files: act, kern, economy,
  military, trade, runner, util/contract and the new library dfllm.orderlib (`dfhack-run dfllm reload` loads them).

## Reach, seal, perimeter and refuge audits; embark metal/stone rule (2026-10-15)
- New kernel module `lua/dfllm/seal.lua` (WP7, after snapshot; revealed tiles only, citizens from the census). It checks
  the Run 9 failures without a full-map BFS: walk groups give the verdict, a bounded BFS from the citizens gives the
  first leak and the number of independent routes.
- **FR-22/54:** `inspect what=reach` reports the walk groups of citizens, food, drink, seeds, farm plots, wells, beds,
  the depot and the map exit, plus stairs without a counterpart. A class outside the citizens' group raises `CUTOFF`
  (A), naming the closing tile (a fresh wall/door/bridge, then a bounded walk). Closing cells from `runner` (build
  stages) and every construction or door/bridge change trigger a re-check. A bridge the gate raised outside PEACE is
  `SEAL`, not `CUTOFF`. `inspect what=entrances` gives the first leak (tile, building, wall/door state) and the routes.
  It runs after each siege and 40 ticks after each lever pull: `SEAL_LEAK` (A) or `SEAL` (B).
- **FR-56:** perimeter manifest of walls, fortifications, doors, hatches, floodgates, grates, bars and killbox tiles,
  learned in PEACE. Pieces already gone at siege start are retired; after the siege the diff re-queues the destroyed
  pieces (`runner.repair`, class defense) and raises `PERIMETER_BROKEN` (A). `inspect what=perimeter`.
- **FR-24:** `inspect what=defense` shows each bridge's real gate_flags, walking through it and each lever's link.
- **FR-33/37/57:** large predators count for the civ alert only within 25 tiles of an entrance (or inside).
  `seal.alert_burrow` (called by siege) checks the burrow for drink, food and beds. If they are short, it falls back to
  Kern+ (from the refuge), then to the interior burrow `Innen+` (painted by `act.burrow_tiles`), then to no
  confinement, and raises `REFUGE_FAIL` (A). In BREACH it uses the refuge only if its audit passes; it returns to
  Kern+ after 3 days without a visible hostile. `status` prints `alert <burrow> <n>t <m> in`. `inspect what=refuge`.
- **FR-08 embark:** the gate requires a metal ore (iron passes; bronze only or other metals warn) and a stone layer
  (fails on the 'no stone' popup or deep soil), both read from the embark panel's layer lines.
  `--accept <criterion> --reason "..."` lets a failed criterion pass and logs it to `accept.log`.
- **Run 9 live findings (FR-59/60/63, seal part of FR-62; 017411c, offline, live-untested):** stored drink, food and
  seeds (barrels, bins, bags) count for reach, the refuge audit and CUTOFF; a flagged stair is read again before it is
  reported (cause: a scan days old); without a manifest, the walls, doors, gates and bridges of an opening found sealed
  become perimeter pieces, and the new verb `perimeter.record` records the citizens' boundary; seal's work is capped
  per real second (`seal.CFG.rate`), and the item census, map edge, scan and PEACE entrance search skip unchanged inputs.

## Rename (2026-10-15): df-llm-helper -> dfpilot
- Project renamed back to **dfpilot**; Python package `df_llm_helper` -> `dfpilot` (`python -m dfpilot ...`), the
  PreToolUse hook runs `python -m dfpilot.hook`.
- `df_llm_helper/` stays as a forwarding package (its module path is `dfpilot/`), so running setups and hooks that call
  `python -m df_llm_helper ...` keep working; the fair-play hook accepts both names.
- Unchanged on purpose: the in-game kernel `lua/dfllm`, the shorthand `dfllm` for the CLI, `<DF>/dfllm-runtime/`, the
  save marker and the `dfllm/` blueprints (renaming them would orphan adopted saves). The GitHub URL stays
  `GordonMohrin/df-llm-helper` until the repository itself is renamed (GitHub then redirects the old URL).

## v2 (branch `v2`, 2026-10-10 to 2026-10-11)
- **New design** (docs/v2/DESIGN.md, CONTRACTS.md, DECISIONS.md, DOCTRINE.md): an in-game kernel `lua/dfllm` (17 modules:
  sense, threat, siege FSM, gate, military, readiness, drill, runner, economy, care, trade, snapshot, ...) defends and
  runs the fort itself; it writes files only (state a/b, events, outbox, snapshots, perf.csv) and takes closed inbox
  verbs. All writes go through `act.lua` (UI-equivalent actions, `config/allowlist.json`); reads see visible units and
  revealed tiles only. Opt-in per save (`dfllm adopt`), runtime settings restored on unload.
- **Python** `df_llm_helper` (stdlib, 0 DF calls): `status`, `brief`, `follow` (wake lines), `events`, `plan
  propose|check|apply`, `cmd`, `bp list|preview|sites` (templates, topo audit, site ranking), `doctor`, `supervise`,
  `lint` and the PreToolUse hook (`.claude/settings.json`). Gordon's answers live in `config/decisions.yaml`.
- **Tools:** `tools/luahost.py` (Lua tests on DF's `lua53.dll`), `tools/migrate_v2.py`, `tools/embark/`, `tools/win/`.
- **Live** on Castlerisen (slots L0-L5, docs/v2/STATUS.md §0): embark, baseline, fortcore stages 1-3, squads, levers,
  drills, trade, moods, burial, food follows the population.
- **v1 removed from `v2`** (2026-10-11): the v1 helper modules, `lua/claude`, `lua/pilot_*.lua`, v1 tests and fixtures,
  `data/`, `Bugs/`, `Features/`, `scenarios/`, `examples/`, the v1 docs and `config.yaml.example`. They stay in tag
  `v1-final`; docs/v2/V1-LEGACY.md lists them. `lint` and `fairplay` no longer forward v1 names. `pytest tests` is the
  plain v2 gate (1237 passed); the fixture runtime `tests/fixtures/v2/runtime` is tracked now.
- **Fresh-user check** (2026-10-11, docs/v2/STATUS.md §5): `tools/luahost.py` finds `lua53.dll` via `DFLLM_DF` too and
  prints suite/test totals; `dfllm supervise --help` passes through to supervise (`--dry-run`); `bp list|preview` work
  before `adopt`; `df_llm_helper.lint --help` exits 0; README/QUICKSTART/DESIGN/embark README corrected. 1241 passed.
- Everything below this entry is **v1** history; its code is in tag `v1-final`.

## Guard deadman: extra liveness signals (2026-10-08)
- `guard.liveness_globs` (default `[]` = old behaviour): the deadman uses the YOUNGEST of `heartbeat.txt` and all files matching
  these globs (`~`/env vars expanded, `**` recursive). Prefix `birth:` uses the creation time instead of the mtime, for output files of
  long-running background loops that keep being written while the orchestrator hangs. Example: Claude Code transcripts incl.
  subagents and `birth:%TEMP%/claude/<slug>/*/tasks/*.output`. Stops false deadman alarms while the orchestrator waits on subagents.
- `ToolsDir.liveness_age_min(patterns)`, `ToolsDir.alive_age_min(patterns)`; tests `tests/test_liveness.py`.

## Permanent watchers (2026-10-04)
- `wake` gamelog rules (`df_llm_helper/wakerules.py`): hard alarms (siege/ambush/beast/megabeast/forgotten beast), deaths/tantrum/berserk/mood
  with the dwarf's name, caravan (first `caravan from` message), ghosts. Incremental, rotation-safe gamelog reader, rate limit and
  `(+N suppressed)` per category, tunable via `wake.gamelog_rules` in config.yaml. `pause.hold` is a wake flag (`WAKE pause`).
  Replaces the four inline Claude shell monitors; `wake --loop` is the event source for the Monitor tool.
- Lua watchers made generic and added to `lua/claude/`: `stresswacht`, `hospitalwacht`, `geisterwacht`, `aemterwacht`, `binwacht`,
  `schmelzwacht`, starter `wachen` (`start|status|load`). Paths via `util.home()`, values in `config.lua` (`WACHEN_LIST`, `STRESS_WACHT`, ...).
- Tests: `tests/test_wakerules.py`, fixture `fixtures/wake/gamelog_sample.txt`. README section "Permanent watchers".

## Refuge check and loop registry (2026-10-03)
- FEATURE-005: `python -m df_llm_helper refuge check [--json]` checks that the refuge burrow contains reachable water
  (well/water tile), drink, food and the hospital: BFS from the anchor (hospital zone, else `ZUFLUCHT.probe`) over burrow
  tiles only, OK/UNREACHABLE/MISSING per category with coordinates. `refuge repair [--apply]` extends the burrow along
  a BFS path from the refuge core (hospital first) to the nearest missing targets plus their rects (dry run by default).
  New `lua/pilot_refuge.lua` (`info`, `add`). `claude/mil refuge check` and `gefahr.refuge_supply()` judge
  reachability (`status`, `where`, `anchor`, `lines`); supplies that are in the burrow but unreachable now count as
  `ZUFLUCHT OHNE WASSER/ESSEN`, so `REFUGE_REQUIRE_WATER = true` also blocks the alert for them. `check` reports an
  unsupplied refuge every 15 min (critical without reachable water and drink -> wake); the digest names the problem.
- FEATURE-006: `python -m df_llm_helper loops list|stop|clean|wrap`. The helper's loops (`waechter`, `wake`,
  `autopilot`, `guard`, `caravan`, `siege`, `camera watch`) take a lockfile `tools/loops/<name>.lock` with heartbeat;
  a second start is refused (or warned with `loops.on_duplicate: warn`); `check`, `digest` and `wake` report
  DUPLICATE and STALE loops. PID liveness without psutil on Windows and Linux.
## Offices and hospital watch (FEATURE-001, FEATURE-004, 2026-10-03)
- FEATURE-001: `python -m df_llm_helper offices [--plan|--apply [--replace-unfit]] [--file F] [--json]` and
  `offices watch`: required offices (manager, bookkeeper, broker, captain of the guard, militia commander, chief medical
  dwarf; mayor when present) are `ok`, `empty`, `dead` (assignment on a dead unit/histfig) or `unfit` (mood, child,
  prisoner, wounded, stress, depot unreachable, not a soldier); one distinct successor per problem by a pure score
  (skills, stress, wounds, squad, pickaxe, caretaker). `--apply` uses `claude/aemter vacate` + `assign` and needs the
  new register consent action `OFFICES`. `check` writes one warning per state change (crit for dead/empty = one wake
  line). The trade automaton (`trade step`, `caravan`) fails at IDLE with the offices message when the broker is dead
  or unusable, without pausing or writing `pause.hold`. New Lua `lua/pilot_offices.lua` (read only).
- FEATURE-004: `python -m df_llm_helper hospital [staff [--apply]|plan] [--file F] [--json]`: hospital staff posts
  (location occupations; without a filled post the game creates no care jobs; a post on a dead unit counts as
  unfilled), care labors, patients waiting without a care job, zone furniture, water reachable from the hospital and in
  the refuge burrow (BUG-423 `refuge_supply`), supplies (forbidden apart), orphaned locations; one warning per state
  change. `hospital staff --apply` fills posts like the location menu and sets the care labors (register consent action
  `HOSPITAL`). New planner `planners/medical.py`: no plaster-powder order without gypsum/alabaster/selenite/satinspar
  (`plaster powder impossible: ...`). `care.py` got the pure post/staff functions. New Lua `lua/pilot_hospital.lua`;
  `claude/ueberwacher` names the watch in its `HOSPITAL/REST` hint.
- `exception add` also accepts the consent actions `OFFICES` and `HOSPITAL` (`fairplay.CONSENT_ACTIONS`).
## Item flow budget and forbidden supplies (2026-10-03, FEATURE-002, FEATURE-003)
- FEATURE-003: new `python -m df_llm_helper forbid-watch [--json]` (read only, new Lua `claude/pilot_forbid status`):
  forbidden own items by class, drinks/food blocked by forbidden containers, a cause per item (dump zone, own/other dead,
  used ammo, foreign-made loot, dense area, unknown), where they lie, the standing orders `forbid_*`, `claude/*` script
  logs that mention forbidding, and the game log's `cancels ...: Forbidden area` over the last `forbid_watch.log_minutes`
  (`FORBID: 1043 own items forbidden (drinks 475 = 100 %), 37 Forbidden-area cancels in 10 min -> drinking blocked`;
  without forbidden items: `Forbidden-area cancels without forbidden items (burrow/zone?)`). `forbid-watch fix
  [--classes ...] [--apply]` clears the forbid flag of own drink/food/container (and on request material) items: dry run
  by default, siege loot and foreign/trader goods never, ids logged. In `check`: `Forbidden own items: N (drinks D/T,
  food F/T)` when drinks/food blocked > 20 % or Forbidden-area cancels > 10; one wake line + digest line per change into
  a warning state. Falls back to `claude/pilot_hygiene forbid` without the new script; hygiene's own forbidden-supply
  warning defers to it.
- FEATURE-002: `hygiene flow [--hours 24] [--caps]` (inflow/sink per item group from flow snapshots in state.db table
  `item_flow`, reachable vs unreachable loose stacks, free stockpile tiles, state per group), `hygiene caps` (manager-order
  cap audit incl. `cap above sale capacity`, config `hygiene.flow.sale_capacity` 800), `hygiene bins [--pile ID]
  [--apply]` (bins needed, wood cost, max_bins vs existing bins; `--apply` = one one-off ConstructBin order + raised
  max_bins, only with the new register rule FP14), `hygiene mark --unforbid [--apply]` (legacy forbidden non-dwarf
  corpses: forbid off + dump on), garbage bridge state/landing in `hygiene zones`. KPIs and the digest line count
  reachable stacks only (`unreachable N ignored`). Wake lines only on a state change (crafts growing, bridge landing
  > 300). `claude/muell dump` keeps bones/skulls/shells/horns/teeth/hides (craft material).
- Lua: new `lua/pilot_forbid.lua`; `lua/pilot_hygiene.lua` (status flow fields, report bridges/standing orders, piles,
  caps, mark --unforbid, bins_order, max_bins); `lua/claude/muell.lua` (bone filter). Reinstall with
  `python -m df_llm_helper install-lua --apply`.

## Military and alarm fixes from the live siege (2026-10-03)
- BUG-423: `claude/alert off` now holds (`config.ALERT_MANUAL_HOLD_S`, default 15 min) against the watchdog and `gefahr`
  unless the enemies near the fort grow by more than `ALERT_MANUAL_GROW` or a new major threat appears (flag
  `tools/alert-manual-off.flag`). Prisoners (caged, chained, held in a cage item: `config.is_captive`) never count as
  threats. The refuge burrow is checked for drink/water and food (`claude/mil refuge check`, `gefahr` selftest
  `ZUFLUCHT OHNE WASSER`/`ZUFLUCHT OHNE ESSEN`, `refuge.supply` in `gefahr status`); with
  `config.REFUGE_REQUIRE_WATER = true` automation does not lock citizens into a refuge without drink or water (warning in
  `notfall.flag`); the default `false` still calls them in during a siege and warns. The supervisor
  names the real cause instead of recommending a command the watchdog undid.
- BUG-425: `claude/mil add` picks an explicit free slot (leader slot last) and always reports `slot` or `reason`
  (`squad full`, `unit already in squad N`, `addToSquad refused ...`); `mil create` always returns `squad_id`
  (plus a warning if a later step fails) and lists empty squads to reuse; new `mil rename`. Squads cannot be deleted
  through DFHack: reuse empty ones.
- BUG-426: no kill orders on caged/chained units (`killorder`, `mil kill`, `mil guard`, `pilot_siege`, siege flow);
  existing kill orders are scrubbed of such targets; squads with a thirsty/hungry member lose their kill order so
  they can eat and drink.

## install-lua (2026-10-02)
- `python -m df_llm_helper install-lua [--apply] [--df <folder>]`: installs the bundled Lua scripts into the game,
  merges `config.lua` with the live values, keeps `stages.lua`, follows `dfhack-config/script-paths.txt`, backs up first.

## Retest fixes (2026-10-02)
- BUG-221: the trade automaton runs the game while the broker walks and the haulers carry, and waits in MARK until
  the depot has no `BringItemToDepot` job left (at most 600 s, then it opens with what is there).
- BUG-222: without an immediate approval the trade window is closed and the game runs on (new state WAIT);
  `trade approve` works in REVIEW and WAIT and reopens the window.
- BUG-211: `defense stats` counts only invasion announcements, no combat lines with "siege engineer"/"goblin thief".
- BUG-331: `kb import` reports each file once.

## Decisions the player delegated (2026-10-02)
- BUG-104: opening the live `state.db` removes the snapshot/kpi rows old `--mock` runs wrote into it. Marker: the
  fixture identity (`data/mock_fingerprints.json`, kept in sync with `fixtures/run5` by a test) AND a contradiction with
  the game's time line (another snapshot of the same game several game years away, stored minutes apart). Real rows,
  the isolated mock db and `--mock` runs are never touched; idempotent (`df_llm_helper/mockrows.py`).
- BUG-220: `mood reserve` uses the `minimum` of `claude/mood status` (authoritative) and falls back to `mood.reserves`;
  config defaults follow mood.lua (rough gems 12, cut gems 10, wood 14, bone 5, leather 3, metal 3, cloth 3, stone 5,
  silk 2). `bottleneck`: `mechanism` from `claude/pilot_defense status` (`stock.mechanisms`), `blocks` from
  `claude/muell status` (`typen` BLOCKS=N, a lower bound) via the new `sources` list in `data/graphs/produktion.yaml`;
  `claude/material status` `stock.mechanism`/`stock.blocks` win once the Lua side reports them.
- BUG-319: `deathcause` and `gaydar` are read-only and no longer refused (L25, FP07). `createitem` in pure message text
  (print/qerror/dfhack.printerr/util.emit/say/log ...) is not reported; as a command it stays an L01 error.
- BUG-418: lint honours consents of the local register `data/exceptions.local.jsonl` and maps `L07`<->`FP09`,
  `L06`<->`FP08`; `exception add --local` writes there; the L07 message says how. The shipped L07 finding stays.
- BUG-421: every dfhack-run call > 3 s goes to `tools/out/stall.log` (rotated at 1 MB); `perf status` shows the stall
  period (median interval between stalls). The watcher counts a failure only after 2 consecutive timeouts.

## Neutral map config, embark scripts (2026-10-02)
- `lua/claude/config.lua` and `lua/claude/stages.lua` ship neutral (nil/empty; defaults come from the loaded map). The real
  Run-5 values moved to `examples/windrings/` (reference only).
- `tools/embark/probe.sh` and `scan2.sh` added (were referenced but missing); generic paths via `DF_DIR`/`EMBARK_DIR`;
  the embark automation stays marked experimental.

## Rename (2026-10-02): dfpilot -> df-llm-helper
- Project renamed to **df-llm-helper**; Python package `dfpilot` -> `df_llm_helper` (`python -m df_llm_helper ...`).
- Environment variable `DF_LLM_HELPER_HOME` (Python and `lua/claude/util.lua`); `DFPILOT_HOME` is still read as fallback.
- Watcher process check now looks for `df_llm_helper waechter` (config `guard.guard_process`).
- Agent prompt marker `[df-llm-helper-brief v1]`; internal pseudo-commands/tags `HELPER ...` (was `DFPILOT ...`).
- Unchanged on purpose: DFHack command names `claude/pilot_*` and `claude/*` (installed scripts keep working), JSON keys, kv/config keys.
- Older entries below still say "dfpilot".

## Report / knowledge / fair-play review against the live game (2026-10-02)
- Hostiles far away (forgotten beasts in the caverns: `feinde_auf_karte` 3, `feinde_nah` 0) were a permanent "!! enemies on map" and a standing `tempo off` blocker (the guard would have slowed the game for good). `Snapshot.danger` now needs the alarm, enemies near the fort, named threats, or an enemy count with unknown distance; far hostiles give one quiet info line (never "still open"). Synthetic test enemies stand at the fort (`make_fixtures`, `s09_gefahr` regenerated).
- `--mock` / `--replay-file` without `--config` run in `runtime/mock/` (own state.db, tools folder, gamelog). Before, fixture warnings (mood 5891, perimeter, reach) and fixture snapshots landed in the live `state.db` and showed up in the live report, and live flags/gamelog leaked into mock runs.
- `check`: standing feature lines (hygiene, reach, tools, ...) are reported when their text changes or every 2 h, not on every check (a "No change" check cost ~250 tokens of repeated lines). Hunger/thirst lines no longer repeat each time the id list shuffles. "No change" no longer cuts the open list mid-word.
- `tempo status` (display only: time lapse, fps, guard blockers); `tempo off --dry-run` really is a dry run now (it used to switch the time lapse off).
- `journal`: `ingest` derives the date of the first log line from the file mtime and the day changes (all events carried today's date); game date only from a snapshot within 30 min; combat aftermath (`NOT_STUNNED`, `REGAIN_CONSCIOUSNESS`, `UNIT_PROJECTILE_SLAM`, `LOSE_EMOTION`) and animal births are no chronicle events or wake-ups; `lessons` finds repeated death causes (15 dehydration deaths in one day were invisible).
- `memory compact`: an archive is never overwritten (same-second runs destroyed the original, `restore` then returned the compacted file); an already compact file is left alone (>= 5 % gain needed); `all` skips `handel-regeln.md`/`REGISTRY.md`. `shorten()` no longer cuts at dates/times ("von bau, 01.10." was a whole briefing inbox line) and briefings drop the double bullet "- - ".
- `kb search`: entry ids are searchable (`wasser_quelle`), German water words map to the English entries.
- `exception add` rejects unknown rule ids (`XX99`), bad `expires`, `max_uses < 1`. Lint: `L08` no longer flags the target position of a squad order (`o.pos.x = ...` after `squad_order_*:new()`); `lua -f` with a Windows path is linted (shlex ate the backslashes, so the file was never checked).
- `agents cost` caps the "stuck?" lines at 5 (58 lines in a long project); dashboard lists critical warnings first; `forecast` says `confidence n/a` before the first calibration.
- Lua `claude/units`: `injured` = `unit.health.flags.needs_healthcare` instead of `#wounds > 0` (healed scars made 144 of 176 citizens "injured" and fed `rb08_hospital`/`rb15` diagnoses). The live toolkit copy still has the old line.
- Tests: `tests/test_report_fixes.py`.

## v3 live test (2026-10-02)
- `reach`: a point on a building tile that blocks walking (the well) was reported "UNREACHABLE". `pilot_reach check` now tests the tiles around the building (`via` in the answer, `x,y,z+` forces it), `dump` marks such tiles `W`, the grid logic (`measure`, cause search, what-if) reaches a `W`/`adjacent` point from its neighbours; `reach.yaml` field `adjacent`.
- `perimeter`: obstacle buildings (well/statue) are walls for the scan; documented why the scan finds `(108,92,z132)` that `claude/zugaenge` hides (it treats workshops as walls, DF does not).
- `remote`: names in the status/rescue lines drop the nickname instead of cutting it mid-word.
- Tests with the Lua grid mock for the well and for a blocking building in the perimeter scan.

## v3 (2026-10-01) – eleven features from Run 5 (`docs/specs-v3/`, manual `docs/manual-v3/`)
- New plug-in mechanism `df_llm_helper/features/` (KEY, DEFAULTS, register, check_hook): features add commands, config and check lines without touching cli/config.
- `perimeter` (01), `digcheck` (02), `reach` (11): access guard with clustering, allow-list, seal CSV (stairs rule, what-if before sealing), dig rules R1–R6 in blocks, reachability with cutting-construction search and gamelog correlation; Lua `pilot_perimeter/digcheck/reach.lua`; grid fixtures reproduce the Run-5 situations.
- `perf` (03) and standstill/window guard (04, `freeze_guard.py` in the watcher): latency sampling with period estimate, safe bisect with protected services and crash recovery, perf.flag; closes Info/Help/MessageBox when game time stands still (grace period, never during a live trade), trade aftercare (pause.hold/caravan.flag).
- `tools` (05) and `remote` (06): pick balance via pick fix (only with FP08), more miners, forge proposal; remote-worker rescue (cancel job, take labor, give back on recovery), long-job labor pool.
- `hygiene` (07), `defense` (08), `settings` (09), `camera` (10): dump marking ≤ 300/cycle never boulders or dwarf corpses, dump-zone diagnosis; deterministic kill-box design (lane, traps, materials, Quickfort CSV, ASCII) and trap reload status; safe `d_init.txt` edits with backup/pending/verify/revert; camera profiles (ambient, combat, build, events, calm) via a small hook in `schau.lua`.
- Ported from the live game: watcher time-standstill basics, trade button candidate choice, trade recordings (`fixtures/run5_live/trade*`), updated Lua toolkit (gefahr, material, muell, orders, pickfix, raster, schau, stages, zugaenge); fixed a syntax error in `orders.lua` (goblet entry).
- Exception register: optional local file `data/exceptions.local.jsonl` (git-ignored) for installation-specific consents.
- All v3 fixtures are synthetic (labelled); fixture gaps and live checks: `docs/INTEGRATION.md`.

## Public version (2026-10-01)
- Standalone folder without private data: neutral paths (`runtime/`), empty exception register (example only), KB curated only (no imported learning journals), docs under `docs/`, English README, `COMPANION.md` (expected `claude/*` companion scripts with reference responses). Tests that needed the private repo now check the bundled files or are skipped.
- Translation pass: all user-facing output (digest, guard, watcher, wake, CLI, self-test, planners) is English. Interfaces to the Lua companion scripts stay unchanged (JSON keys, flag texts, `pause.hold` texts, `metrics.csv` columns). The watcher/guard now write `CRITICAL` in `events.log`; `KRITISCH` is still read (wake filter, journal). Digest status line: `Status Y<year> ...`.
- Renamed the runbook key to `needs_player_approval` and the exception-register field to `player_consent`; the previous names are still accepted as aliases when loading.

## v2-12 Chronicle and lessons writer (`python -m df_llm_helper journal`, spec 12)
- `df_llm_helper/journal.py` (table `events`, import from watcher log + critical warnings, noise filter, CP437 repair, chronicle draft in clusters, lessons with repetition threshold and dedupe, KB draft after approval, monthly metrics, post-mortem skeleton incl. exception register), CLI `journal ingest|chronik|lessons|metrics|postmortem` with write boundary. `moods.py` names the last gaps when a mood fails (cause for lessons).
- Real fixture: `fixtures/run5_live/events_run3.log` (= `tools/out/events-run3.log`, 3015 lines; Run 5 has only a 12-line excerpt).
- Tests: recall 100 % of KRITISCH events without noise (target ≥ 90 %), 2× "mood failed, wood" → exactly one suggestion, header = `metrics.csv` Run 5, post-mortem only from state.db, write boundary.

## v2-11 Dashboard (`python -m df_llm_helper dashboard`, spec 11)
- `df_llm_helper/dashboard.py` (static HTML from state.db, sparklines as inline SVG, light/dark CSS tokens, phone width, own HTML structure check, write only on change), CLI `dashboard [build|map|unmap]`, `check` updates the page. The digest state now stores `level`/`text` per warning (consistency dashboard = situation report); `bottleneck` stores line and stock in kv; the forecast band ±0 is dropped.
- After live report: the build plan counts hospital/temple/tavern/library/guildhall as locations (`abstract_building_type`, read command `LOCATIONS_CMD`), not as zones.
- Tests: valid/offline/< 200 KB (also with 800 events), no placeholders, missing sources → section omitted, warnings = digest, map = `fixtures/run5/area_z130.txt` (instead of tunnel end: no tunnel fixture exists), build plan from real building counts, hash.

## v2-10 Enforce subagent briefing, measure costs (`python -m df_llm_helper agents`, spec 10)
- `df_llm_helper/agents.py`: prompt generator ≤ 1500 tokens with mandatory blocks and marker, report linter (5 mandatory fields, ≤ 12 lines, shorten + archive), cost measurement from transcripts (dedupe per requestId, estimated output from block lengths), comparison briefing vs. old, task dedupe 10 min. CLI `agents prompt|lint-report|cost`. `AGENT-PROMPT.md`: the generator is mandatory.
- Fixtures `fixtures/subagents/agent-anon{1,2}.jsonl` (+ meta): anonymized from real subagent runs of this development session, only timestamps, requestId, usage and block lengths.
- Findings: transcripts log every API response per content block (90 lines = 47 requests); naive sums are ~2x too high. `usage.output_tokens` is the value at stream start (2..8) → output estimated from block lengths.
- Tests: all 12 scopes ≤ 1500 tokens with mandatory blocks, report linter positive/negative/shortening, costs = independent manual measurement (exact), comparison mechanics, dedupe.
- Open: acceptance 4 (≥ 30 % less output over 3 real agent runs) needs live runs with the new prompt.

## v2-09 Restart and load runbook (`python -m df_llm_helper reboot`, spec 09)
- `data/services.yaml` (16 services + precondition config, dependencies; tempo, kohle, schau, watchdog_alert deliberately manual), `df_llm_helper/reboot.py` (wait for map, load detection via frame_counter/report ID, idempotent start in dependency order, pause until all are running, warning in the situation report), CLI `reboot [run|validate|load]`, `check` starts services after a detected load. `client.register_read` for generated read commands.
- Tests: all stopped → all running (config before services, watchdog before ueberwacher), running ones not started twice, waiting for `isMapLoaded`, every line with a check command, broken service → paused + critical, precondition missing.
- After live report: `kohle` and `schau` no longer automatic (9 s freeze or not active live), `watchdog_alert` added as check key; tempo.schedule services are visible via repeat-util (confirmed).
- Title-menu load helper only with `reboot.auto_load` (the player's wish), live-untested. Fixture gap: real repeat-util response right after loading.

## v2-08 Water and flood watcher (`python -m df_llm_helper water`, spec 08)
- `lua/pilot_water.lua` (scan/near, discovered tiles only, live-untested), `df_llm_helper/water.py` (pre-check incl. diagonals, watcher with emergency-wall suggestion, wasser.flag), lint rule L31 `lint_dig` (forbidden boxes `water.forbid_dig`, active in the RealClient), runbook `rb21_flut`, KB `wasser_diagonal`, blueprint `blueprints/r5_notwand.csv`, wake call `WAKE flut`, `check` reports water in the fort. Read commands `pilot_water scan/near`, `pilot_mood need` no longer count as write commands.
- After live report: forbidden box tunnel end/shore (x181..189, y42..49, z127..128) added; emergency wall and other boxes confirmed.
- Lua mock: tiles via `MOCK_TILES`, `claude/config` via `MOCK_FORT_X/Y`.
- Tests: diagonal access F=(184,43,128) → forbidden despite rock orthogonally, flood replay 40 tiles → critical + emergency wall (128,99,128), L31 positive/negative incl. register, Lua scan baseline 0/tunnel 40 with front.
- Fixture gap: real `pilot_water` responses; tiles recreated from LAYOUT-run5.md section 11.

## v2-07 Bottleneck watcher (`python -m df_llm_helper bottleneck`, spec 07)
- `data/graphs/produktion.yaml` (17 nodes, 4 goals: pickaxes, well, beds, mood reserve wood; chains from `tools/scopes/material.md`), `df_llm_helper/bottleneck.py` (validation, first empty node per goal, line ≤ 160 characters, starter budget via wood reserve, escalation after 20 game days, shopping list kv `trade.boost_bottleneck`), CLI `bottleneck [check|validate]`; `caravan.py` reads both boosts.
- Tests: wood 0/coke 0/coal 26 → bottleneck wood with chain starter → coke → forge, wood 40/coke 0 → burn at most 28 wood, graph without cycles/unknown nodes, property test (80), escalation, backtest.
- Backtest (acceptance 5): Run 5 has no wood/coke time series. Reconstructed timeline from `chronik.md`/`material.md` (`fixtures/run5_live/engpass_timeline.yaml`, sources per entry): report 45 min (only entries with known coke, 10:45) or 125 min (09:25, coke unknown) before the manual diagnosis (11:30). Not a measured backtest.
- After live report: coal reserve 20 (player); with alternatives the truly empty node is reported before "below reserve"; `material status` returns `coal`/`coke` (533/29) live as assumed.
- Fixture gap: real `claude/material status` response; stock counters for chains/buckets/mechanisms/blocks are missing in material.lua.

## v2-06 Workload control (`python -m df_llm_helper workload`, spec 06)
- `df_llm_helper/workload.py` (decision tree A "jobs not executable" / B "no work", maintenance automatic: `raster start|next`, `orders/arbeit start` (`kohle` never automatic after a live finding: 9 s freeze); rest as suggestion; 10 min lock per measure, max. 2 per run, effect measurement idle before/after), CLI `workload`, configuration `workload:`.
- Tests: dig queue 0/idle 68 % → dig stage first, 208 jobs/54 idle/11 picks → picks/fuel, coke 0 + wood 0 → spec 07, effect `ok erledigt`/`ohne Wirkung` (done/no effect), no repetition within 10 min, observation from real fixtures (`auslastung status`, gamelog).
- Fixture gaps: real responses of `claude/pickfix` (dry run), `claude/raster status`, `claude/kohle status`, `claude/material status`.

## v2-05 Famine forecast (`python -m df_llm_helper forecast`, spec 05)
- `df_llm_helper/forecast.py` (time series in kv, per-capita eating rate from falling intervals, production from increases, band, self-calibration with error log and confidence, warning only when crossing), CLI `forecast [show|backtest]`, `check` updates the series, configuration `forecast:`.
- Real fixture: `fixtures/run5_live/metrics_run5.csv` (copy of `metrics.csv`, Run 5).
- Tests: synthetic 100/10/2 → 12.5 days, harvest jump ≠ negative consumption, growth shortens, line ≤ 120 characters, warning once when crossing, property test (40 series), backtest.
- **Deviation from acceptance 5:** Run 5 backtest (horizon 3 days, window 5): drinks 20 % (target ≤ 30 % met), food **33 %** (target missed; "stock stays the same" scores 25 %). Cause: cooking bursts and measurement points several days apart; `metrics.csv` has no fish/meat columns. Not optimized away (damping toward persistence lowers the number but makes the forecast useless). A test secures ≤ 40 % as the regression limit.

## v2-04 Hunger and hospital watcher (`python -m df_llm_helper care`, spec 04)
- `df_llm_helper/care.py` (rules care_labors/care_duplicate_hospital/care_floor_zone, escalation hints water source/meals, top-5 critical patients), `lua/pilot_care.lua` (status/labors, live-untested; refuses soldiers and pickaxe carriers), CLI `care`, configuration `care:`.
- Tests: 0 doctors/5 injured → 5 assignments with reason, 3 doctors → no action, duplicate hospital → warning only, 100× "Give water: No water source" (real gamelog lines) → hint, property test (120 cases): soldiers/miners with a pick never chosen.
- After live report 2026-10-01: hospital via location HOSPITAL instead of zone type, report orphaned hospital locations, patient no longer via `#wounds` alone (scars).
- Fixture gap: real `claude/pilot_care status` response.

## v2-03 Mood manager (`python -m df_llm_helper mood`, spec 03)
- `df_llm_helper/moods.py` (demand from job elements, NONE decoding via flags, sum per type, CutGems release with loop protection, wood 0 → `trade.boost` + charcoal block, "will fail" warning, aftercare, reserves from pop 20), `lua/pilot_mood.lua` (need/release-cutgems, live-untested), CLI `mood [check|reserve]`, configuration `mood:`.
- Caravan: `caravan.boost_wants` reads kv `trade.boost` (wood first and as a must-have good).
- Real fixture: `fixtures/run5_live/mood_log_sample.txt` (Etur, Logem, Stâkud, Åblel, Îton from `tools/out/mood.log`).
- Tests: rough gems 6/4 bound/demand 3 → release, wood 0 → shopping list without charcoal, NONE property test (60 cases), timeout < travel time, report ≤ 6 lines, aftercare, reserves against real `mood status`.
- Fixture gap: real `claude/pilot_mood need` responses (synthetic in the tests, modeled on the demand lists from mood.log).

## v2-02 Caravan autopilot (`python -m df_llm_helper caravan`, spec 02)
- `df_llm_helper/caravan.py` (trade/skip decision from the real offer + `data/trade/wants.yaml`, approval only with a must-have good and ratio ≥ 2.0, skip without pause, stuck merchants only with register FP09), `lua/pilot_caravan.lua` (live-untested), CLI `caravan`.
- Real fixtures from `tools/out/handel.log`: `fixtures/run5_live/handel_*.json` (offer of 170 items, own goods, dry run, Leaving, AtDepot).
- Tests: planner buys wood + food at "Catten small" (ratio ≥ 2.0), skip without a must-have good, abort with quicksave hint, release only after `stuck_ticks` and only with register, Lua property test (only merchants receive `left`).
- Register FP09 entered (the player's standing permission, 2026-10-01: send stuck merchants home via `flags1.left`).
- Deviation: the quicksave rollback does not load automatically (DFHack cannot load without the title menu) – clean abort + hint.

## v2-01 Siege autopilot (`python -m df_llm_helper siege`, spec 01)
- `df_llm_helper/siege.py` (state machine IDLE→ASSESS→PREPARE→ENGAGE→DONE/ABORT, runner with guaranteed clearing of commands), `lua/pilot_siege.lua` (status/kill/move/clear, live-untested), CLI `siege`, configuration `siege:`.
- Tests: replay "Elves 31" (end state: commands cleared, alert off, flags gone, `advance run`), retreat at blood < 60 %, fleeing enemies not pursued, berserk citizens only reported, loop protection, dry run, error clears commands.
- Linter L11: no more false alarm on reading `#eq.work_weapons` (pickfix.lua).
- Fixture gaps: real `pilot_siege status` responses during an attack, `claude/advance clock` with `paused`.

## M3 (2026-10-01) – P2: F14, F15, F16 + polish
- Done: trend anomalies (robust median/MAD on the snapshot history, with KB cause in the digest) and abort loops (top 3 in the real gamelog), trade automaton `trade` (16 states, rollback on "caravan leaves", "window not open", "broker loses job", timeouts), status display `overlay` (≤ 3 × 120 characters, no repetition within 10 min). Also `check` (orchestrator check in one call), bus messages in the digest, `AGENT-PROMPT.md`, `INTEGRATION.md` complete.
- Tests: 1339 green (12.5 s; self-test with coverage ~33 s). False alarms on stable synthetic series: ≤ 3 in 3 × 1000 points. Trade automaton: 200 random sequences without a command in the wrong state.
- Open: all Lua and Windows parts are live-untested (see `docs/INTEGRATION.md`, "Live acceptance").

## M2 (2026-10-01) – P1: F6, F7, F9, F10, F11, F13
- Done: compactor `memory compact/restore` (archive byte-identical), event bus `bus post/read/ack/import` (SQLite WAL, dedupe, priorities), linter `lint` (30 rules, positive/negative case per rule, exceptions via the register, RealClient refuses lint errors), batching (`pilot_batch.lua`, 10 commands = 1 process, partial errors isolated, fallback to single calls), planners `plan trade|dig|armor|supply|blueprint`, metrics `budget`/`metrics` (CSV like metrics.csv).
- Coverage: bus 96 %, lint 100 %, transport 97 %, planners 100 % (trade: 300 property cases = brute-force optimal).
- Existing Lua: 6 lint findings (5 warnings L10, 1 false alarm L08), documented in `LINT-BEFUNDE.md`, not repaired.
- Planner assumptions (bars per piece, consumption per capita, zone `a` = archery range): `docs/PLANNERS.md`, verify live.

## M1 (2026-10-01) – core P0: F1, F2, F3, F4, F5, F8, F12 + self-test
- Done: Real/Mock/Replay/Recording client, clock (real time and game time separate), tolerant snapshot parser (repairs, among others, the broken JSON `"fps": 250,0` from `gefahr status`), digest, autopilot (13 rules), 18 runbooks, KB (39 curated + 102 imported), briefings (12 scopes), guard, 10 scenarios, wake filter `wake`, compactor (F6 pulled forward).
- Tests: 451 green, `python -m df_llm_helper.selftest --cov` in ~23 s. Coverage: digest 97 %, rules 94 %, runbooks 98 %, kb 99 %, brief 98 %, guard 97 % (coverage; a separate settrace counter confirms the values).
- Tokens (len/3): digest fixtures/run5 355 (target ≤ 600; raw data status+report+inbox ≈ 8800), "no change" 26 (≤ 30), briefing max 579 without or ~1100 with memory (≤ 1500), KB response max 327 (≤ 400), memory militaer 16.7 → 5.7 KB, wirtschaft 11.7 → 3.1 KB (≤ 6 KB).
- Taken over from the orchestrator session (Run 5): wake filter against 42 wake calls in 41 min, abort-loop detector (top 3 in the gamelog: Make bed 314x, Give water 61x, Plant seeds 9x), runbooks for coke/fuel, manager without office, finished-goods storage, services after loading.
- Finding: `claude/arbeit status` and `claude/ueberwacher status` are not status commands, they trigger a work round. df-llm-helper therefore queries running jobs side-effect-free via `repeat-util.isScheduled`.

### Open fixture gaps (please supply locally with `--record`)
- `SERVICES_CMD` (repeat-util query) and `MAX_REPORT_ID_CMD`: outputs are synthetic, verify locally.
- `claude/watchdog status`, `claude/material status`, `claude/orders status` with unvalidated orders, `claude/mood status` with an active mood (field format known only from the transcript), `handel status` with `AtDepot`, gamelog lines "cancels Eat: Could not find path".
- `claude/advance clock` (field `paused` for the trade automaton), `claude/pilot_batch` response, `claude/pilot_wd` response, output of `claude/schau say`.

### Decisions (2026-10-01, the player, or Claude at the player's request) – details `docs/MANUAL.md` section 8
1. Start agents itself: no, not for now (Claude). 2. Protective actions without asking: yes (player). 3. Daily budget: none, `daily_token_budget: 0` (player).
4. E18 release of equipment data: stays manual (Claude). 5. Deadman df-llm-helper only, `python -m df_llm_helper waechter` replaces `unpause-guard.ps1` (player; live-untested).
6. Time-lapse on: orchestrator via `python -m df_llm_helper tempo on`, refuses on guard blockers (Claude). 7. Zone key `a`: stays allowed (Claude).
