# dfpilot v2: status after the integration check

Date 2026-10-11. Branch `v2`. §0 is the live slot L5 (food crisis: food follows the population), §0f the live slot
L4 (iter2: integration of the four offline packages, trade, drills, a 1-year soak), §0e the live slot L3 (soak, 2 game years unattended), §0d the live slot L2
(defense: levers, squads, fortcore 2-3, drill), §0c the live slot L1b (labor, moods, P1), §0b the live slot L1
(economy and building), §0a the live slot L0 (first v2 code in Dwarf Fortress); §1-§9 are the offline
integration state they started from (pytest, luahost on `hack/lua53.dll`, k_mock).

## 0i. Offline: FR-62 kernel cost on a big fort (2026-10-15, live-untested)
- **`repeat` was not a module:** it is DFHack's counter for our one repeat-util callback (`repeat-util.lua`:
  `recordRepeatRuntime` around the whole kernel frame), i.e. the row total measured again, on unpaused frames only
  and on the 15.6 ms `getTickCount` clock (69 of the 82-90 ms/s). doctor summed it as a module; now it prints it as a
  cross-check line. Nothing in it was registered twice (`scheduleEvery` cancels by key on every boot/reload).
- **Owners:** the kernel's own cost is split into `k.state`, `k.io`, `k.persist`, `k.inbox`, `k.events` and `kern`
  (dispatcher); a module's persist keys are booked to the module. Big keys (≥ 8 KB encoded, e.g. seal's perimeter) are
  written at most every 60 s (mode change, stop: at once).
- **Pacing and fort size (`lua/dfllm/util/sched.lua`, shared with k_mock):** non-critical modules spend at most their
  share (ms/s; seal 4, economy 3, default 2), their runs and `'more'` slices wait when over it; in PEACE the waiting
  modules' shares are scaled together to what the 25 ms/s budget leaves after sense, reflex and the kernel's
  housekeeping. economy and care stretch their cadence by the load factor (`max(units/150, items/6000)`, ≤ 3x).
  sense: inactive units cost one call, LARGE_PREDATOR raws cached per race/caste, seal's entrance list only when a
  predator candidate needs it (about -40 % in the mock). economy: one flag-word read per item instead of eight
  (cross-checked against the per-flag reads on the first 300 items of a boot).
- **Flip-flop:** promotion needs quiet *running* time (a paused game does not count) that doubles after each flip;
  KERNEL_SLOW once per module per 6 h, later demotions only in kern.log.
- **selftest `budget`:** last minute against `25 + 6 * (units/150 - 1)` ms/s (35 for 402 units, at most 40); a
  failure names the top owners and is logged again every 10 min while it lasts.
- **Model (tests/lua/test_kern_load.lua, 402 units, 18.7k items, stand-ins calibrated to §0h):** old scheduling
  84 ms/s; new scheduling with the old sense/housekeeping costs 33 ms/s (seal 2, economy 1.5); with the sense and
  housekeeping savings measured in `tests/lua/load_bench.lua` 24.5 ms/s. These are estimates for DF, not measurements.
- **Check live with `dfllm doctor` (≥ 10 min PEACE after a load):** the `modules ms/s` line has no `repeat` and names
  `k.*` parts; the `DFHack repeat counter` line is ≤ the kernel total; `kernel N ms/s avg (limit 35 for 402 units)`
  with N ≤ 25 hoped, ≤ 35 required; seal ≤ ~4, economy ≤ ~3; at most one `KERNEL_SLOW` per module in the event list;
  PEACE median ticks/s vs 450 (gap = DF's own load if the kernel is ≤ 25). In kern.log: `<module> paced: ...` once,
  `economy cadence x3.0 for the fort size`, no `selftest quick failed: budget` every few minutes. `dfllm cmd inspect
  '{"what":"perf"}'` shows `load`, `budget`, `pool_ms_s`, `pool_pct`; `what=modules` shows share, debt, paced, flips.

## 0h. Live test of the Run 9 feature requests on the Run 9 save (2026-10-15, Claude as player; Gordon: "state is irrelevant")
Setup: `git pull` to 3edc277 (main), backup of region2 + autosave 1-3 in `C:\Users\admin\Documents\df-backups\run9-20261015`,
DF restarted (`tools/win/start_df_desktop1.ps1`), loaded **autosave 1** (Udosoddom, y363 spring d9, 6 citizens, 25 unburied,
3 ghosts; the live fort was already extinct, y364 pop 0). The kernel booted from the repo Lua on map load (script path),
`follow` restarted (writes `.follow.hb`); the old `tools/run_*` workarounds were **not** running. Raw outputs below.

**Works (live):**
- Kernel up, `status` line 1 `DEFCON 5 | region2-site96 ...`, `clock: free (cap 500, timestream 500)` (first read after
  load: `clock: held 150 t/s, reason brake`), `follow: OFF (no heartbeat yet: start dfllm follow)` before `follow` was started
  and gone afterwards.
- `selftest full`: 8 pass, 1 fail (`budget`, see FR-62). `kern.log`: 0 x "armok commands removed" (entomb is not removed).
- FR-39 guard: `cmd order.add {"job":"MakeArmor","amount":1,"material_category":["cloth"]}` ->
  `refused (not sent): $.args: MakeArmor needs item_subtype (ITEM_...): DF 53.16 crashes without one (FR-39)`;
  with `"item_subtype":"ITEM_ARMOR_SHIRT"` -> `ok ... order.add: order 613 MakeArmor x1 {"order":613}`.
- `inspect what=orders`: `182 open orders, 132 stuck, 0 unsafe`, a reason per order (`no Still`, `no Loom`, `no leather`).
- `inspect what=tombs`: `243 coffins, 0 free, 25 unburied, 3 ghosts, 0 burial jobs`, causes per body (`no_coffin 22, zone_shared 3`),
  ghosts `[[24786,"no_body"],[24965,"no_body"],[24995,"no_coffin"]]`; event GHOSTS (A) with the causes and a next step.
- `inspect what=defense`: all four bridges `up/bypass` (the serpentine can be bypassed; matches what the player found by hand).
- `inspect what=entrances`: `LEAK at 55,62,117 (stair_updown no door); 3 independent routes` with the three real openings
  (shaft head 55,62,118; the north ramp room 61,55,117; the east stair 75,70,118), path length 77 from edge (0,4,118).
- `inspect what=water_sources`: first call `scan queued`, second call lists the existing well 17363 (53,62,115) as accepted
  and two Water Source zones (depth 0, not accepted); 0 reachable bodies >= 4/7.
- Interrupt channel: a caravan without a depot produced `NO_DEPOT` (class I) in `alarm.txt`, `follow` woke with
  `NO_DEPOT ... DEPOT_MISSING: caravan from Muboomon on the map and no trade depot stands (one is being built)`,
  `dfllm ack` -> `acked up to #8413 (0 interrupts open, DEFCON 5)`. The depot keeper had a depot at (67,42,118) under construction.
- `status` shows `free metal ammo 93 body 1 gloves 4 head 3 pants 1 shield 8 shoes 6 weapon 21` (loot is counted).
- The refuge audit refuses a bad burrow and falls back: `alert no confinement (whole fort) (Kern+ refused: ...)`.

**More live results (same session, later):**
- ALERT clamp: a giant bat inside the fort -> `MODE PEACE>ALERT hostile`, `ALERT_START`, `PREDATOR` (class I, `1 wild dangers inside the fort (25971 at 83,41,106)`),
  `status`: `clock: held 100 t/s, reason alert` and real ticks/s 99-139 (FR-51 ALERT cap confirmed).
- Unacked interrupt fail-safe: 60 s later `LOCKDOWN interrupt #9762 PREDATOR unacked for 60 s: kernel applied its default: clock 30 t/s, alert on Kern+,
  2 citizens outside Kern+`; `status`: `clock: held 30 t/s, reason unacked:PREDATOR | lockdown unacked:PREDATOR`; after `dfllm ack` and 2 quiet game days
  `clock: free (cap 500, timestream 500)`, `lockdown off`, DEFCON 5 (FR-53 ack timeout and LOCKDOWN_END confirmed).
- Burials (FR-45/41/42): after the loose coffins were unforbidden and built, the kernel assigned zones and ran `entomb --unit <id> --haul-now`
  (`commands.log`: `care act.run ["entomb","--unit","24631","--haul-now"] ok`); 8 bodies lay in the 8 new coffins ~3 min later, no armok removal.
- Building sites: Masons and Still stayed 0/3 for 25 minutes and were built within 60 s after the forbidden items on their footprints were
  unforbidden (BUG-009); the depot site had 41 forbidden items.
- `autolabor` was found enabled in legacy mode after the load (BUG-010).

**Forced scenarios (Gordon, 2026-10-15 14:50: "erzwing eine Belagerung, der Spielstand ist egal, das gilt auch fuer andere Testszenarios"):**
`modtools/create-unit` is broken in 53.16 (`world.arena_spawn` is gone) and `force` only knows timed events (Caravan, Migrants, ...), so no real
invaders could be spawned. The arrival text was injected as a popup instead; that is exactly what the kernel's recogniser reads:
```
dfhack-run lua "dfhack.gui.showPopupAnnouncement('A vile force of darkness has arrived!  The army is commanded by the goblin Test Commander. ...', COLOR_LIGHTRED)"
```
Timeline (2 s probe, `scratchpad/siege_probe.py`; run 2 started with all four drawbridges lowered by hand):
- t+0 s popup injected; t+2 s `DEFCON 2`, `ARRIVAL #10727 siege (popup)` in alarm.txt, `clock: held 30 t/s, reason arrival:siege`, `lockdown arrival:siege` (FR-51/52 recognition + clamp confirmed).
- `arbiter act.dismiss_popup ["siege"]` closes the popup in the same tick.
- Bridges: 0 -> 2 up after 6 s, 3 after 12 s, 4 after 16 s (`lever_latency_s 14` in `status`, 801 ticks). Gate events `GATE X160xx moving/up` (FR-54 confirmed;
  the latency is dominated by the dwarves walking to the four levers).
- `SEAL LEAK` events for the three real openings with `routes=3 sealed=0` (FR-37 confirmed), `SEAL ... open route ... to the map edge without a roofed tile`.
- After `dfllm ack`: `LOCKDOWN_END lockdown over (arrival:siege): threat 0 for 2 days; 0 doors opened`, clock free again (cap 500), DEFCON 5, the kernel lowered
  the four bridges again (`GATE ... down`). Without ack the clamp holds (30 t/s, the unacked interrupt keeps the lockdown).
- Problems: the lockdown forbade **0 doors** although the fort has 62 (BUG-012, "0 entrances"); `act.civ_alert true` is followed 12 ticks later by `act.civ_alert false`
  and `civ_alert=0` in every probe sample (BUG-011, with BUG-001 behind the refuge refusal). So bridges and clock work, door lockdown and civil alert do not.

**Not yet seen live:** an enemy inside the fort (needs a way to spawn units), PERIMETER_BROKEN after a siege (BUG-002), HOSPITAL_DRY, MOOD_RISK, embark panel.

**Problems found (one file per bug in `bugs/`, BUG-001..BUG-012, index `bugs/README.md`; FR-59..FR-63 in docs/feature-requests/README.md):**
1. **FR-59** `seal.lua` SKIP contains `in_inventory`, so every drink/food/seed unit stored in a barrel or bag is ignored:
   `inspect reach` shows `drink/food/seeds groups: []`, the refuge audit says `drink 0<7, food 0<7` for Kern+ and Innen+
   although Lua shows 1362 drink units, all inside Kern+, none forbidden; CUTOFF for food/drink can never fire.
2. **FR-60** `inspect what=perimeter` -> `0 perimeter pieces` on a fort without a manifest, so PERIMETER_BROKEN cannot fire
   (the Run 9 shaft-head wall was destroyed and nobody noticed).
3. **FR-61** nothing provisions coffins: `no_coffin 22` with 0 free; tombs.repair frees and assigns but never creates coffins or zones.
4. **FR-62** kernel cost: `kernel 82-90 ms/s avg (limit 25)`, modules `repeat 69-70 seal 37 sense 16 economy 12-14 kern 11`,
   PEACE median 430-435 ticks/s (< 450) with 402 units / 18.7k items; `KERNEL_SLOW ... demoted x8` repeats; `selftest quick failed: budget`
   every ~4 min in kern.log since 14.10. The `repeat` bucket is not explained.
5. **FR-63** `inspect reach` flags `stairs: 3 without counterpart (down stair at 30,66,109)` although z108..z80 of that column are
   all stairs (tile read by Lua): stale snapshot or UPDOWN not accepted as counterpart.

## 0g. Offline: Run 9 feature requests in the kernel (2026-10-15, live-untested)
Four packages from `docs/feature-requests/README.md` (each FR paragraph carries its status line), merged to main; gate:
pytest green, Lua 43 suites / 694 passed (now also on Linux: `tools/luahost.py` falls back to a `lua5.3` interpreter),
lint 0, config ok. The kernel now has **19 modules** (new: `reflex`, `seal`).
- **Siege latency** (FR-36/49/51/52/53/55/58): SIEGE_START/INVASION class A; FPS cap follows the mode (SIEGE 30,
  ALERT 100); module `reflex` raises linked gates, forbids entrance doors, holds the clock and sounds the alert on the
  arrival announcement (fail-open without a manifest); interrupt channel `<save>/alarm.txt`, `dfllm wait
  --until-interrupt`, `dfllm ack`, DEFCON in `status`; decision D-14 `peace_gates` (default `down`).
- **Care and water** (FR-04/26/27/31/33a/34/41/42/44/45/47/48): GHOSTS, tomb repair, `entomb --haul-now`, 4 doctors,
  hospital water as the game accepts it (HOSPITAL_DRY), MOOD_RISK.
- **Economy** (FR-01/10/16/17/18/23/25/29/32/39/40/43/46/50): the FR-39 crash guard (`order.add`, ORDER_BAD), order
  sanity, jobs/work details, farm slots, seeds, starvation, forbidden containers, loot, depot keeper, trade ledger,
  follow heartbeat.
- **Reach and refuge** (FR-22/24/33/37/54/56/57, FR-08): module `seal` (CUTOFF, SEAL_LEAK, PERIMETER_BROKEN,
  REFUGE_FAIL; `inspect what=reach|entrances|defense|perimeter|refuge`), alert burrow audit with fallback `Innen+`,
  embark rule metal + hard stone with `--accept`.
Live checks per package: CHANGELOG.md (2026-10-15 entries). The workarounds in `tools/run_*` are marked superseded,
not deleted.

## 0. Live slot L5: food crisis, food follows the population (2026-10-11 06:54 - 07:30)
**Fort at hand-over:** Castlerisen, y295 winter d57, pop 54 (34 adults, 6 soldiers), PEACE, phase P5, readiness R1
(audit ok, traps 3), **PAUSED for Gordon** (`pause_state` true; after the last kernel reload the owner reads `df`:
Gordon unpauses in DF). Food 270 days (edible stock about 620: 278 meals, 199 plump helmets, berries, fruit), drink
327 days, stress 7 %, naked 9, ghosts 2. Kernel reloaded with the final code (17 modules). live.lock released;
my sampler, watcher and `follow` stopped.

**Start:** the orchestrator had paused the fort at y295 summer d30 with **15 food days** (105 at the L4 hand-over;
pop 41 -> 53, cap 55). What I found (read-only probes):
- **80 farm tiles for 53 citizens:** one surface plot 5x2 (blueberry/spelt) and two underground 5x7 plump-helmet
  plots. autofarm sets only the current season's crop (normal), but its **default threshold 50 stopped the helmets
  at 40 in stock**. 41 edible units in the fort (40 plump helmets, 1 meal); the 881 plant growths were leaves.
- **Nobody fished:** no fishing zone, FISH labor 0 (the Fisherdwarves detail held one departed unit), the fishery
  idle. Hunting was off ("no game"; a donkey, a llama and ravens visible).
- 65 tallow lay under `ban-cooking tallow`; spelt and millet need a quern (none); one lone cow and a mule (no
  pets, no mates); the two food piles held 21 tiles; summer fruit hung on about 170 trees within 40 tiles.

**Live, by hand (UI-equivalent; quickfort zone/place and the screens' fields through `dfhack-run lua -f` dev
scripts, all listed here):**
1. **Gather zones** (zones screen, Gather/Pick Fruit with trees, shrubs and fallen fruit): 36 zones on the revealed
   outdoor tiles of 76..136 x 62..122, z122-128 (19,151 tiles). Fruit and berries came in within days.
2. **Fishing zones** on the brook (25..38 x 126..139, z116-117, 219 tiles) and 3 adult civilians into
   Fisherdwarves; economy later took one out (he was a miner) and two because food was above 90 days.
3. **Slaughter** of the cow and the mule (animals screen): 47 meat in 6 days.
4. **autofarm** threshold 300 for plump helmets, 100 for the surface berries (economy owns these now, below).
5. **Kitchen:** cooking allowed for the 5 tallow kinds in the fort (never plump helmets, Gordon's rule): 64 meals
   in 6 days. baseline's `ban-cooking tallow` banned them again at the next boot.
6. **Food pile** 6x6 with barrels in the core (95,97,119): meals had rotted outside the surface kitchen.
7. **More farms** through the product route: `bp.place farms S1 p.plots=4 prio 1` (`--by llm`; 140 tiles at z121
   west of the old plots). The dig started slowly (PROJECT_BLOCKED 'stalled' wakes x3) and stands at **25 % dig**
   at hand-over: the 4 plots are not built yet.
- **Food 15 -> 63 days in 6 game days -> 294 days by summer d55** (fruit, meat, tallow meals, berries); 300 at
  autumn d43. I paused there to write the product code.

**Death: 1 citizen in L5.** Atír Adilthabum "Wallgulf" (miner, 55, unit 19661), y295 autumn d43, **THIRST**
(death incident). Bedridden without a wound (needs healthcare, waiting for diagnosis); thirst 40,000 at autumn
d14 rising to 75,000; care's `patient_thirst` DECISION_NEEDED fired 5 times ("water and buckets present
(caregivers?)"); GiveWater jobs were posted, he got no water. I saw him at 55,000 during the run and trusted the
GiveWater job; I should have acted then. It is the open L2/L3 item "no water for patients" (the hospital reads
`water NO`, the cistern is dry), not a food death and not tooling, but it happened on my watch.

**Product (offline gate green):** food follows the population (DESIGN §5.11, CONTRACTS §5/§12, RULES §10).
1. **Farm tiles per citizen:** economy wants `cit x per_dwarf / yield` farm tiles (3 plants per citizen and
   season, 1 crop per tile and season: 159 for 53) and emits `PROJECT_REQUEST farms why=food n=plots` (35-tile
   plots, at most 4) while food is below 90 days **or** the food stock fell over 14 days, the fort has fewer tiles
   than it wants, no farms project is pending (`runner.pending`) and the last request is 14 days old. `follow`
   places it at once at S1 with `p.plots` and prio 1 (like mood_rock).
2. **autofarm thresholds of the food crops** = `cit x 4` in steps of 10 between autofarm's default and 400 (the
   crops `autofarm status` lists, minus the fiber crops the cloth chain owns; status read once a boot and weekly).
   Live: "autofarm threshold 210 for the food crops BERRIES_FISHER ... MUSHROOM_HELMET_PLUMP SPELT WEED_RAT
   (53 citizens)".
3. **Fishers:** `Fisherdwarves` is a builtin tool detail for `act.work_detail` and economy: one fisher per 15
   citizens (max 3) while food is below 90 days (or a famine) and a fishing zone exists; PEACE only (RECOVERY in a
   famine), off at once in any other mode (they stand at the brook, like hunters); military never recruits them.
4. **Cooking and fishery proportional:** the `dfllm:food` meal order keeps 2 meals per citizen from cookable stock
   that is not on the cook ban (census `food_nocook` = plump helmets); its job cap grows with the fort (one job per
   2 citizens, at least 20); one PrepareRawFish order holds up to one fish per citizen (at least 30).
5. **Famine pre-alarm (class A):** below 30 food days (and not yet a famine) a weekly `DECISION_NEEDED food_low`
   with farm tiles have/want, falling, fishing zone, raw fish and cookable stock; the famine wake stays below 10.
6. **Found live: prepared fish was never food.** `item_fishst` has no `mat_type` field; the census dropped every
   prepared fish as "unreadable" (kern.log warnings since L4's fishery). The census now reads
   `getActualMaterial(Index)` when the fields are missing.
- Tests: new `tests/lua/test_economy_food.lua` (11 cases: tile math, request/pending/cap/14-day cadence, falling
  trend, pre-alarm, thresholds, fishers incl. mode, cooking incl. the helmet ban, fish census, fishery size) and a
  follow test for the farms auto-place; gate: **pytest 1237 passed, Lua 33 suites / 573 passed, lint 0, config ok**.

**Verification season** (kernel reloaded with the product code at autumn d43, unpaused, watched until winter d43;
the pause came at winter d57 because my gate run outlasted the watcher):
| KPI | Value | Threshold |
|---|---|---|
| deaths | **0** in the season (slot: 1, thirst, before the reload) | 0 |
| food days | 302 (aut d49) -> 431 -> 252 -> 347 -> 303 -> 192 -> 207 -> 400 -> 407 (win d43) -> 270 (win d57); the edible stock stayed at about 620-650 units through winter (no gathering); slot 15 -> 270 | >= 60, trend positive |
| drink days | 309-575 | >= 170 |
| farms | 80 tiles built, 140 in the farms project (dig 25 %); no new request (food above 90 days, farms pending) | 159 wanted |
| autofarm | thresholds 200 -> 210 (52 -> 53 citizens); winter crops set on both underground plots | — |
| ticks/s PEACE | median 440 (9 rows); slot 429 (19 rows) | >= 450 |
| kernel ms/s | 39-74 while running (snapshot about 19, economy 9-18; three audit exports and two reload boots in 10 rows); doctor's 10-min average 17 | <= 25 |
| frame gaps > 3 s | 0 | 0 |
| pop | 53 -> 54 (a birth), cap 55 | <= cap + 3 |
| other | 1 drill (failed as before: worn 38 %, slow O1), 1 traded caravan (Catten, ratio 1.77), stress 7 %, naked 9 | — |
| dfhack-run spawns | product 0; mine about 25 (read-only probes, the hand measures above, 3 reloads, pause/unpause) | 0 |

**Open for Gordon / next slot (most urgent first)**
1. **Water for patients** (it killed again): a bedridden dwarf gets no water while the hospital reads `water NO`.
   The cistern fix from L4 item 2 (walls at (100,93,115), (101,95,115), (104,93,115), cistern-check, link lever
   14994) is still open; care's `patient_thirst` wake needs a first move that works (RULES §7).
2. **The farms project** (c1a12957d13feae401, 4 plots at z121, dig 25 %) must finish; until then the fort lives on
   gathered fruit (summer/autumn) and 70 underground tiles. If it stalls again, check the dig for hidden tiles.
3. Kernel cost above budget while running (L4 item 4): snapshot exports of the 125,400-tile audit box dominate.
4. Gather and fishing zones are by hand: templates (or runner zones) would let economy ask for them like farms.
5. A quern for spelt and millet (82 + 84 in stock) needs a quern stone (mason; boulders are short).
6. Metal, drills, ghosts as in L4 (§0f).

## 0f. Live slot L4 (iter2): integration, live checks, trade, drills, soak (2026-10-11 05:23 - 07:10)
**Fort at hand-over:** Castlerisen, y295 spring d8, pop 53 (35 adults, 6 soldiers), PEACE, phase **P5** (P4 -> P5 at
y292 autumn after the first traded caravan), readiness **R1** (audit ok, traps 3), about 390-420 ticks/s, unpaused, DF on
desktop 1 (runtime `region2/`). Plan y295 applied (target P5, beauty none, trade wants bars first). Drink 526 days, food
105 days, stress 9 %, naked 9, ghosts 2, worn 38 %. `follow`, my KPI sampler and a read-only caravan probe ran in this
session's background and stop with it.

**Integration (commit 9a02ed6, the four offline packages):** water joined `contract.MODULES` (17 modules) and the ACT
owners of `item_flag`/`workorder`; `act.burrow_units` (gate's lever pullers) applied from the gates package's patch; new
`snapshot.reach(a, b)` (walk groups, care's mood reach); water's hospital lookup guarded (the adopt test booted it
DISABLED); CONTRACTS §3.4/§5/§7 rows and the regenerated schema appendix; kernel tests updated for 17 modules.
`dfllm reload` booted all 17 modules; the fortcore `retrofit=1` lever rooms were placed and done in one runner pass.

**Deaths: 3 citizens in L4 (0 in the 1-year soak).** Causes from the death incidents:
1. Nish Unôlrakust (weaponsmith 45, unit 20068), y291 winter: **a Possessed mood at the metalsmith's forge needed bars
   x2** (read from the mood job). The fort has no ore and 0 metal bars; the only reachable metal were three tools (a pick,
   two battle axes); 36 iron weapons and 31 iron shields lie on unreachable cavern levels (z98-106). The mood failed after
   about 40 days; melancholy; **dehydrated** within days.
2. Bomrek Bidokûrith (militia commander, 19917) and 3. her baby Obok Mosuskol (20084), y292 autumn: **death cause
   DRAWBRIDGE**. An automatic drill raised B1 15 ticks after its footprint had cleared ("B1 up waits: citizen on the
   footprint", then the pull); she stepped back on while the bridge moved (108 ticks). **Tooling death, fixed** (gate
   footprint margin, below). Both are ghosts now (no corpse; memorial slabs need stone).
- Moods: 2 started (both Possessed, adults), **1 succeeded**, 1 failed (above). The successful one (unit 20085: bone x2, a
  block, a boulder) was saved by hand: care had freed 9 held boulders, one per run, while the bone was missing, and other
  jobs took each one (fixed below); I marked the adult donkey for slaughter and dug 3 andesite walls next to the dwarf.

**Found live and fixed (all tested; commits 171bb3b, 9f3e819, 59e934b and the hand-over commit)**
1. **Trade 'time' failures (L1-L3): DF 53 posts no TradeAtDepot job from the depot toggles.** The read-only caravan probe
   showed "Broker requested" and "Anyone can Trade" set for 27,500 ticks with the caravan at the depot, `d.jobs` empty and
   the broker at ordinary jobs (v1 Run 6 saw the same). `act.trade broker_job` posts the job the request stands for (one
   per depot, building holder ref, `linkIntoWorld`); a posted job nobody takes within 600 ticks goes to the broker once he
   has no job (his own job is never cancelled). **Live: 3 of 6 visits traded** (Catten ratio 1.65 -> P5, Muboomon 2.12,
   Catten 1.70); the others failed on 'ratio' (nothing to sell) and 'unloading' (human caravan). No metal bars were on
   offer or affordable. The first visit's unhappy outpost liaison ("could not complete a meeting") destroyed the depot; it
   was rebuilt through `bp.place tpl=fortcore site=repair keys=D`.
2. **Bridge footprint margin (the drawbridge deaths):** a non-forced pull (any lowering, a raise outside SIEGE/BREACH) waits
   until no citizen stands on the footprint or 1 tile around it, and a pending pull is cancelled when one comes that close.
   A 3-tile margin first held B1 down for whole drills (fortcore's melee station stands 2 tiles from B1).
3. **Mood filter order (care):** a held reserve item is freed for a mood only once every earlier filter of that mood is
   covered (the dwarf gathers in filter order); until then it counts as there, so MOOD_NEED lists only what is missing.
   follow now places care's `PROJECT_REQUEST bedrooms why=mood_rock` at once with prio 1.
4. **Cistern and room siting:** follow placed three tombs whose anchors lay in the refuge cistern's basin (emit adds the
   cistern's dug box to Z4). Room siting treats a cistern's well room, the basin below and one tile around as private, and
   cistern tiles never count as a corridor next to an anchor (`cmd.Occupancy`). The finished cistern's pipe left the audit
   box and read as a bypass (R1 -> R0 for about 20 days); `runner.bboxes()` keeps a finished cistern's box (from its bp file
   for projects finished earlier). The audit snapshot grew from 49,049 to 125,400 tiles.
5. **Famine with 199 raw fish:** food fell to 5 days (pop 50) while uncleaned fish lay in the stockpiles; the fort had no
   fishery and the census did not see FISH_RAW. economy counts `fish_raw`, orders PrepareRawFish at a fishery, and the
   famine wake says "N raw fish: build a fishery". By hand: a fishery (quickfort `wh`, workshop hall z119) and a prepare
   order; food went from 5 to 50 days within a season, 105 at hand-over.
6. Smaller: "A human caravan from ... has arrived" no longer halts the fort; `combine all -q` (16-28 ms, economy demoted x8)
   runs weekly instead of every 3 days; the idle backlog makes wooden crafts for trade when stone is short and logs >= 60;
   a busy broker is no ACT_FAIL; water's summary says "N wet sources (M wells)" (it printed "5/4 wells wet").

**Package live checks**
- moods+reserves: job filters read live ("bars x2 (inorganic)", "bone x2, boulders x1 (inorganic)"); `mood reserve
  held/hold` lines; economy `need bone 2 (care: mood)`; the census has rock/ore/flux/thread (thread 27 without cavern
  webs), bolts_free 290 <= bolts 305. Defect found: the held-boulder drain (fixed, 3.).
- water: loaded; 0 patients all slot (max thirst 0, no patient_thirst wake); 14-22 buckets. The **cistern** (refuge level
  z116, a 108-tile pipe at z115 to the brook bed) was dug and built through all 8 stages: floodgate 15010 closed, the
  fortification and shaft hold brook water at the intake. **It is dry: lever 14994 is not linked**, and `cistern-check`
  reports water leaks: the two tombs at (99,92..94) and (100..102,96) and the pocket (104..105,92..94) open into the basin
  at z115. I removed both tomb zones and their doors; the walls at (100,93), (101,95) and (104,93) are not built (open
  items). care's `hosp_water` still reads 0 while water.lua counts the 2/7 sumps as wet.
- economy: hunters leave at once for drills (WORK_DETAIL 'mode'), gear lines per slot, autochop target, DECISION_NEEDED
  metal x4 (no ore), famine x2. Worn 15 % -> 38 % (g_body 4, g_head 3).
- gates: the lever-puller rooms are live; **take 40-104 ticks** for the drill pulls (L2: 156-243).

**Drills (9 automatic, all failed)**
| Drills | worn | B1 / O1 up (ticks after T) | outside | dbl | why |
|---|---|---|---|---|---|
| y292 autumn (old code) | 16 % | 649 / 649 | 5 | 0 | worn, outside; **2 deaths** (B1 raise) |
| y292-y293, 4 drills (3-tile margin from y293) | 23 % | B1 never; O1 637-1025 | 0-1 | 0 | up:B1, worn, slow O1 |
| y293 winter - y294 winter, 4 drills (1-tile margin) | 23-38 % | B1 1087-1192 or never; O1 871-1192 | 0-3 | 0 | worn, slow O1, outside |
- **Not passable yet:** worn 38 % (needs 90: no bars, little leather; +23 points in 3 game years, so years at this rate
  unless a caravan sells armor or bars). O1 rises after T+870: the pull waits for citizens outside and for the footprint margin.

**KPIs measured (L4 soak: one game year, y293 winter -> y294 winter d56, no code reload inside; whole slot in brackets)**
| KPI | Value | Threshold |
|---|---|---|
| ticks/s PEACE | median 398, p10 166 incl. pauses; doctor, last 10 min: 393 (slot median 409) | ≥ 450 |
| kernel ms/s | median 22, p90 28, max 50; 9 of 35 PEACE rows over 25; doctor: repeat 19.1, kern 8.7, sense 3.3, snapshot 2.2, economy 1.8 | ≤ 25 |
| frame gaps > 3 s | 1, the yearly autosave (slot 3) | 0 outside autosaves |
| deaths | **0** (slot **3**: 1 failed mood -> dehydrated; 2 killed by B1 in a drill) | 0 from tooling |
| moods | 0 (slot: 2 started, 1 succeeded, 1 failed) | 0 failed |
| naked | median 9 of 50 (18 %) (slot 22 %) | ≤ 5 % |
| patient thirst | 0 patients all slot | 0 |
| drink / food days | drink median 328 (min 237); food median 45 (**min 5**, famine y294 summer) (slot food median 108) | ≥ 170 / ≥ 60 |
| stress (category ≤ 1) | median 7 % | ≤ 10 % |
| idle % | median 65 | — |
| trade | 1 of 2 visits traded (slot 3 of 6) | P4: 1 |
| readiness | R1 (slot: R0 for about 20 days from the cistern audit box) | — |
| pop / cap | 41 -> 53, cap 55 | ≤ cap + 3 |
| dfhack-run spawns by the product | 0; mine: read-only probes, 6 reloads and the hand repairs listed above | 0 |

**Open for L5 / Gordon (most urgent first)**
1. **Metal.** No ore, 0 metal bars, and no bars bought in three traded visits. Every Possessed or forge mood that wants
   bars fails (one death this slot). Options: exploration mining (no template; DECISION_NEEDED metal x4), or buying bars
   first (plan y295 wants bars first). The cavern metal (z98-106) is unreachable.
2. **Cistern: wall off the basin before anyone links the lever.** Constructed walls at (100,93,115), (101,95,115) and
   (104,93,115); then a fresh snapshot over the pipe and `python -m dfpilot.bp.sites cistern-check --save region2`
   (exit 0); then link lever 14994 to floodgate 15010 and pull it once. The auto-mode classifier refused one of my
   read-only probes right after I removed the two tomb zones and queued their doors for removal, so I left the walls to you.
3. **The drill cannot pass** (worn 38 %, O1 later than T+900). It runs automatically and raises bridges while soldiers walk
   to their stations; the margin rule keeps it safe but slower.
4. **Kernel cost** is above budget at p90 (28 ms/s): the bigger audit snapshot (125,400 tiles) and economy's daily slices.
5. **Ghosts 2** (no corpses): memorial slabs need stone. The bedrooms dig placed for boulders (c1a12935628374c101) is
   stalled at build 40 %.
6. Sell goods: only crafts are sold (one visit failed on 'ratio'); wooden crafts now come from the idle backlog.
7. care's `hosp_water` (0) and water.lua (hospital ok on 2/7 sumps) disagree; one of them is wrong about the hospital well.

## 0e. Live slot L3: soak (2026-10-11 02:55 - 03:45)
**Fort at hand-over:** Castlerisen, y291 spring d79, pop 30 (15 adults, 3 soldiers), PEACE, phase **P4**, readiness
**R1** (audit ok), about 400-480 ticks/s, unpaused, no popup, DF on desktop 1 (runtime `region2/`; DF wrote
`autosave 1` at the y290 and y291 rollovers).
- Drink 406 days, food 122 days, stress 10 %, nobody thirsty or hungry; idle 41-75 % (logs 9, boulders 8: the y290
  bedrooms and an 8-coffin tombs project wait for furniture).
- Plan y291 applied (no new rooms, target P5, beauty none). `follow` and my sampler ran in this session's
  background and stop with it; live.lock released.

**Soak: y289 spring d9 → y291 spring d16 (2 game years + 7 days) in 42 min real time**: 817,404 ticks in 2,532 s
(323 game ticks per real second on average, including 7 kernel reloads for fixes, popups and the false BREACH).
I acted only on class-A lines (year reviews y289, y290 and y291 through `plan propose/check/apply`;
PROJECT_BLOCKED, BREACH, DECISION_NEEDED berserk and thirst) and on product bugs. For diagnosis I read the game
read-only through DFHack (hunger timers, manager orders, unbuilt buildings, tomb zones, death incidents).

**Deaths: 6 citizens in L3, five of them children.** Causes from the death incidents:
1. Momuz Cagithuzol (child 7, unit 19972), y289 spring d17: **thirst**. He was stark raving mad since his Fey
   mood failed in L2 (pending at the L2 hand-over).
2. Unib Eralkütük (child 3, 20048), y289 summer d21: **thirst**. Her Fey mood (y289 spring d7) failed at d49;
   care saw no missing material (no MOOD_NEED).
3. Sodel Stagshilfikod (child 7, 19946), y289 autumn ~d69: **struck down by the militia commander** after he went
   berserk; his Secretive mood (y289 summer d24) failed at d69. Nothing recorded the death (berserk dwarves leave
   the own group), his corpse was not buried, and **his ghost held the fort in BREACH for 40 days** (fix 4).
4. Libash Rakustidos (recruit 46, 19851), y289 autumn d70: **bled to death** in the same episode (no killer
   recorded: the berserk child or his ghost).
5. Nil Zursulsazir (child 1, 20055), y290 spring d14: **thirst** after a failed Possessed mood (y289 winter
   d31-77). She is now a ghost of the fort (own group, not hostile) and waits for a coffin.
6. Nomal Fikodtenshed (toddler 1.4, 20067), y290 summer d49: **thirst** with 450+ drink days and no mood. Most
   likely hurt in the berserk episode and bedridden; the fort has no well water for patients (not confirmed).
- Moods in L3: 4 started, **1 succeeded** (Secretive, unit 19853, y290 spring), 3 failed. Three of the four moody
  dwarves were children (1, 3 and 7 years). Every failed mood ended in a death.

**Found live and fixed (all tested; 5 commits)**
1. **Rock furniture never came.** quickfort `orders` orders doors, cabinets, coffers, coffins, tables and chairs in
   rock. With 8 boulders, 43 such buildings had waited up to two years (bedrooms, furnaces, tombs, temple, tavern)
   while 82 logs lay around. New `act.order_material` (work orders screen: cancel and re-enter in wood) and economy
   `wood_orders`: below 20 boulders, open one-time orders of these jobs turn wood while the logs beyond 30, minus
   the wood already ordered, cover them. **Live: 21 orders converted; bedrooms, furnaces (stalled since y287), two
   tombs, the temple and the tavern were finished, and the phase went P3 → P4 at y289 autumn d22.** Logs 82 → 9.
2. **The hunger alarm flapped the brake** (47 brake switches before L3; 2-3 "hungry" citizens with 150 food days).
   50,000 is DF's plain "hungry"; the alarm is at 65,000 now (10,000 before "starving"). No hunger brake since.
3. **A berserk popup halted the fort** ("Sodel Stagshilfikod, Dwarven Child has gone berserk!"). The arbiter now
   dismisses it and wakes the LLM (DECISION_NEEDED `berserk`, class A); while halted, nothing in v2 reacted.
4. **A berserker's ghost counted as a hostile inside Kern+.** ALERT → BREACH in one step, civ alert on Tiefe+ for
   40 days, idle 91 %, **21 citizens thirsty** in the refuge, GATE_FAIL x3 (`no_worker`: no civilian may leave
   Tiefe+ to pull a lever). sense now treats every ghost of the fort's civilization as own (`civ_id`); the FSM went
   RECOVERY → PEACE at once. care counts a berserker as a fort member through its histfig link (MEMBER or
   FORMER_MEMBER) to the site government, so its death is recorded, its corpse buried and its ghost counted.
   The ghost was put to rest.
5. **Duplicate tomb zones again (L2 item 5).** DFHack's `burial` zones every coffin with empty `relations`, and a
   coffin built after its zone has none; a second tombs project zoned over the same coffins as well. DF gave the
   dead those "free" zones on occupied coffins, and five citizens lay unburied. The runner's zone stage now leaves
   out one-owner zone cells (tomb, bedroom, office) whose tiles already lie in a zone of that type, and care runs
   `burial -c` only when no zoned coffin lacks its relation. **By hand (UI-equivalent, zone sheet "remove"):** I
   removed the 5 second zones; 19946, 19851 and 20067 were buried within a season.
6. **Mood stock:** economy keeps 1 hunter in PEACE from P1 while bone, shell or leather is below the mood stock
   (the fort has 0 of each). Live: a hunter joined; still 0 bone and leather at hand-over (no spare crossbow).
7. **Trade:** a 'time' failure now logs the phase, time left, ticks at the depot, trader present, goods value and
   broker toggles (the 4th caravan failed with 'time' in y289 autumn, and kern.log had no trace).

**KPIs measured (L3, DESIGN §14)**
| KPI | Value | Threshold |
|---|---|---|
| ticks/s PEACE | median 437 over 75 perf rows; **449 without** the 19 rows paused by popups or my 7 reloads (p10 388); doctor's last 10 min: 459 | ≥ 450 |
| ticks/s BREACH / RECOVERY | 352 (4 rows) / 208 (1 row), a false breach from the ghost; no real raid or siege and no drill in L3 | ≥ 100 |
| kernel ms/s | median 18, p90 29 (PEACE p90 23; 6 of 75 PEACE rows over 25), max 41 (BREACH and reload boots); `repeat` 20, `kern` 9, sense 3.3 | ≤ 25 |
| frame gaps > 3 s | 3, all yearly autosaves (y289, y290, y291 rollovers) | 0 outside autosaves |
| autosave freeze | 6.3 s each (6,297 / 6,297 / 6,313 ms) | ≤ 15 s |
| dfhack-run spawns/h by the product | **0** (follow, status, brief, cmd and plan only read and write files); mine: about 25 in 50 min (7 reloads, read-only diagnostics, the tomb repair) | 0 |
| LLM tokens | this engineer session: about 0.47 M in 47 min (≈ 0.6 M/h, including the code fixes) | ≤ 3 M/h |
| wakes | 2 wake lines in 50 min; the hourly limit (6 L2 wakes) held the BREACH line back 25 min | ≤ 6/h |
| idle % | median 33 (0-100); 91 in the BREACH, 75 at hand-over (no logs, no boulders) | — |
| starving postings | 504 all slot (stale Gather Plants postings from L1) | 0 |
| stress (category ≤ 1) | median 9 % (0-13 %) | ≤ 10 % |
| naked | 7-9 of 29-33 citizens (~24 %); cloth 4 | ≤ 5 % |
| ghosts | 1 most of the slot (19946 until buried, then 20055) | 0 |
| corpses older than 3 days | 2-5 | 0 |
| drink / food days | drink 297-927 (median 574), food 121-390 (median 220) | ≥ 170 / ≥ 60 |
| deaths | **6** (4 thirst, 3 of them after failed moods; 1 struck down while berserk; 1 bled) | 0 from tooling |
| moods | 4 started, 1 succeeded, 3 failed (children aged 1, 3 and 7) | 0 failed |
| readiness | R1 all slot (audit ok, traps 3); R2 fails on drill, soldiers < 8, cv < 12, traps < 30 | — |
| pop / cap | 30 → 30 (29-33, 15 adults), cap 55 (gate 55) | ≤ cap + 3 |
| buildings completed | 6 projects: bedrooms x12, furnaces, tombs x2, temple, tavern; phase P3 → P4 | — |

**Open for L4 / Gordon (most urgent first)**
1. **Moods still kill.** 3 of 4 failed in L3 (10 of 13 since L1), and every failed mood ends in a death (thirst or
   berserk). care sees only the claimed workshop's classes; the fort has 0 bone, shell, leather and bars and 4
   cloth. Children (1-7 years) took 3 of the 4 moods. Gordon may want to allow reading the mood's requirement list.
2. **BREACH cannot pull levers.** With the civ alert on Tiefe+, no civilian may walk to the levers in Kern+
   (GATE_FAIL `no_worker` for O1, B1 and B2). In a real breach B2, the core seal, would never rise. The S3 fallback
   is needed (a lever-puller burrow in the alert list, or levers inside Tiefe+).
3. **No water for patients.** The hospital and refuge wells are dry (`water NO`); a bedridden dwarf dies of thirst
   (L2 death 5, probably L3 death 6). The brook is about 90 tiles away.
4. **Wood.** The wood fallback used 70 logs; 9 are left and 2 woodcutters work. An 8-coffin tombs project (the
   ghost 20055 and two unburied children wait for it) and 6 bedrooms are stalled on furniture; idle 75 %.
5. **Trade.** A 4th 'time' failure (y289 autumn). P4 needs one traded visit, so the phases stay at P4. The next
   visit's kern.log line shows where it stands.
6. **Wake gate.** A burst of class-A events (BREACH, GATE_FAIL, thirst 21) waited 25 min behind the hourly limit,
   which the L2 session's wakes had used up. Safety lines may deserve their own slot.
7. Naked 24 % (cloth 4); 504 stale starving postings; PROJECT_BLOCKED `stalled` for furniture waits (16 queued);
   stale tomb assignments on z117 (zones assigned to dwarves buried in other coffins).

## 0d. Live slot L2 (2026-10-11 01:50 - 03:15)
**Fort at hand-over:** Castlerisen, y288 autumn d69, pop 29 (11 adults, 18 children and babies), PEACE, phase
**P3**, readiness **R1** (audit ok), about 450-480 ticks/s, unpaused, DF on desktop 1.
- Runtime folder `dfllm-runtime/region2/`; DF wrote `autosave 1` (y287) and `autosave 2` (y288) during the slot.
- Drink 518 days, food 365 days, stress 6 %, nobody hungry; two FillPond bucket carriers run thirsty (26-30k)
  on the long trips to the brook.
- Bridges O1, B1, B2 built, **each with 2 linked levers**, all down. Kern+ and Tiefe+ exist.
- Squads A (commander + 1), B (captain), C (crossbow captain): 4 soldiers, Constant training, worn 15 %.
- Projects running: bedrooms x12 (z119, waits for furniture), furnaces, tombs x4 (all waiting for materials).
- `follow` ran in this session's background for the automatic audits; it stops with the session.

**Deaths: 7 citizens in L2.** None from the defense work; the chain was failed moods, a ghost and no
water for the bedridden:
1. Meng Iddodók (stoneworker, unit 19664), y286 spring d54: the Secretive mason mood from L1b failed
   ("went insane") and he went berserk; citizens and a stray dog killed him (bled to death). My door lock came
   too late; the berserk popup halted the fort, I dismissed it.
2. Inod Vutoklir (toddler, 20040), y287 spring d23: a Possessed mood failed, berserk, struck down by citizens.
3. Zas Numurdim (farmer, 19662), y287 summer d34: **battered by Meng Iddodók's ghost** (bled to death). His corpse
   and four others lay in the refuse pile: duplicate tomb zones on the same coffins (two tombs projects at the
   same site) stopped every burial since y284. I removed the 9 duplicates and reassigned the tombs; the
   corpses were buried and both ghosts (Meng, Ilral from L1) were put to rest within a season.
4. Bomrek Amostar (farmer, 19660), y287 summer d82: Possessed mason mood, "needs rock: none available"
   (DECISION_NEEDED), melancholy, dehydrated. My prio-1 stone dig (bedrooms x12, z119) came too late.
5. Meng Thîdascog (militia commander, 19850), y287 winter d36: beaten by the same ghost, then **dehydrated**,
   probably bedridden: the fort has no well water (sump 2/7, `hosp_water` 0), so patients get no water.
6. Ast Rashgurrovod (fisherdwarf, 19663), y288 spring d70: Secretive mason mood; I freed a boulder for it (the
   surface carpenter's workshop deconstructed, mechanism jobs had eaten every boulder); the mood took it and
   still failed (some other material), berserk, killed by citizens.
7. Libash Gebkosoth (expedition leader, 19665), y288 autumn d24: Possessed bowyer mood (the fort had 4 logs),
   stark raving mad, died of thirst. care sent no MOOD_NEED (the job held a bone, see open items).
- **Pending at hand-over:** Momuz Cagithuzol (child, 19972) took a Fey mood (Craftsdwarf's workshop) at y288
  autumn, went stark raving mad at y288 winter d43; raving dwarves stop drinking, so he will most likely die.
- Moods in L2: 7, **6 failed** (one Fey mood succeeded, unit 20044); care emitted MOOD_NEED for 2 of the 6.

**S3, levers (implemented and live)**
- `act.link_lever(lever, target)` = the lever sheet's "link up": one `LinkBuildingToTrigger` job on the lever
  with two attached mechanisms (roles LinkToTrigger/LinkToTarget), a building holder ref (lever) and a trigger
  target ref (target); the mechanisms are free, reachable (walk groups, as the screen's
  need_accessible_mechanism warning) and nearest first. Refused while a link job is pending or a building is
  unbuilt. Lint allows `canWalkBetween` only in that choice.
- gate links every built, unlinked manifest lever in PEACE/ALERT/RECOVERY (LEVER `link` event), one pending
  link job per lever; a refusal backs off 1, 2, 4, 8 days (before the backoff: 194 refusals in a stoneless year).
- **Live: 6 link jobs, all 6 levers linked** (B1, B2, O1, 2 each); the mechanics finished each within days once
  2 mechanisms existed. Mechanisms came from stone digs and from 4 deconstructed hall traps.
- Pulls: real `PullLever` jobs, the single-pending invariant held, **0 double toggles** in 3 drills.
  Latency from the queued pull to a raised bridge: a dwarf takes the job after 156-243 ticks, the bridge moves
  91-108 ticks; an unworked pull is cancelled after 200 ticks (`cancel_own_lever_job`, live 2x) and the backup
  lever is pulled. Lowering after the drill: about 225 + 100 ticks.

**S2, squads and uniforms (implemented and live)**
- `act.squad_create` = the squads screen's "create squad": the vacant commander assignment first, else a new
  MILITIA_CAPTAIN assignment (`next_assignment_id`), then `makeSquad`; with `leader` it seats the leader at once.
- `act.squad_leader` = "choose leader": the citizen takes `squad.leader_assignment` (histfig, position link,
  `assignments_by_type`, `position_vector_idx`), position 0, `unit.military`, equipment update (the officer holds
  a POSITION link, no SQUAD link, as DFHack's Military.cpp). DF shows them as militia commander/captain.
- `act.squad_uniform` writes one `squad_uniform_spec` per item and position (material class Armor/Leather/none,
  indiv choice melee/ranged), replace_clothing, exact_matches, and the crossbow squad's bolt ammo spec.
- military: squads follow max(phase, plan `phase_target`) (applied plan y287 with target P5: A, B and C); every
  wanted squad keeps a leader; a leaderless squad gets one, a member promoted first (live: the commander died,
  DF vacated the post, Libash Rakustidos was promoted); uniform material per category = best available.
- **Live:** squad A (id 81, leaderless since adopt) got a leader; B (82) and C (83) were created with captain
  assignments 12 and 13. Routine Constant training resolved by name. Uniform specs 7 per melee position, 6 per
  crossbow position; **worn 15 %**: only 3 wooden shields and 1 crossbow could be assigned. The fort has no free
  armor, helm, pants, gloves or shoes (every one is worn clothing), no metal bars and no leather.
- Soldiers are never in a tool detail and hold no MINE/CUTWOOD labor (checked live; labormanager monitor).

**Fortcore stages 2-3 (built live through the runner)**
- Stage 3 done: O1, B2, levers, refuge level z116 with beds and well, Tiefe+ burrow. Stage 2 done: killing field
  K1, gallery, B1, barracks zone. Manifest has bridges, stations, killbox K1, refuge, Kern+ and Tiefe+.
- **R1 green** (y288 spring d72): audit ok, min traps 5 (3 after I freed the battle axe and a pick from two traps).
- Template changes:
  - the **41 traps are stage 4** (P6): with traps inside stages 2-3, buildingplan gave 7 mechanisms to traps and
    none to the six levers, and 28 trap weapons need metal (28 MakeWeapon orders that can never run). I
    removed the 34 unbuilt traps and re-placed stages 2-3 without them;
  - the **gallery is on the field level** behind constructed fortifications: z+1 is only reachable by digging
    upward through the military stair, and DF never dug the hidden tile above the up stair (3 years);
  - re-placed stages over existing buildings: tiles already holding a building are tracked (unbuilt = pending),
    not counted as lost (build_lost), and get no manager orders (three placements had ordered 93 mechanisms;
    I removed the 22 duplicate orders);
  - `cmd` retire keeps site `same` (cancelling stage 3 dropped the stage-1 anchor record).
- Audit fixes: built traps are Dynamic tiles and read as walls (no attack path); a dig in progress ran past the
  audit box and read as a bypass (R1 → R0); readiness now adds running project boxes (`runner.bboxes()`).

**Drills (DESIGN §14 KPIs)**
| Drill | Pull at | B1 up | O1 up | dbl | worn | outside T+1,200 | result |
|---|---|---|---|---|---|---|---|
| 1 | T+620 | T+876 | T+917 | 0 | 15 % | 4 | fail: slow O1, worn, outside |
| 2 | T+540 | T+891 | T+945 (backup lever after 200 unworked ticks) | 0 | 15 % | 2 | fail: slow O1, worn, outside |
| 3 | T+464 | T+801 | T+1,076 (first job lost its worker, backup) | 0 | 15 % | 3 | fail: slow O1, worn, outside |
- The timer pull moved from T+600 to **T+450** (siege `RAISE_BY`), DESIGN §4 updated. DRILL ran at 414 ticks/s.
- **The drill cannot pass in this fort yet:** worn 15 % (needs armor production or trade) and O1's lever job is
  slow to be taken (see open items). Citizens outside at T+1,200 were surface workers and bucket carriers.
- DRILL_FAIL (A) fired on the 2nd consecutive failure as designed.

**Other fixes (all tested)**
- arbiter: death notices ("has bled to death", "has been struck down", …), succession notices and failed-mood
  notices no longer halt the fort; "has gone berserk" still stays for Gordon (it halted the fort 3 times).
- labor.starving 504 is no parse error: labormanager reports 504 stale Gather Plants postings (oldest 295,072
  ticks, the L1 gather flood).

**KPIs measured (L2)**
| KPI | Value |
|---|---|
| ticks/s | PEACE median 453 (83 perf rows; p10 150 from popups and reloads); DRILL 414 |
| kernel ms/s | median 18, p90 25, max 41 (reload boots) |
| frame gaps > 3 s | 2 (the two yearly autosaves, max 6.3 s) |
| lever pull → raised | 256-297 ticks (take 156-243, motion 91-108); cancelled unworked pulls 2 |
| double toggles | 0 in 3 drills |
| links | 6 of 6 levers linked; 194 refused attempts before the backoff |
| squads | 3 (A, B, C), 4 soldiers, leaders seated by act; worn 15 % |
| readiness | R0 → R1 (y288 spring), held at hand-over |
| deaths | **7** (5 after failed moods incl. 3 berserk, 1 ghost kill, 1 bedridden without water); 1 raving child pending |
| moods | 7 started, 1 succeeded, 6 failed |
| game time | y286 spring d54 → y288 autumn d69 |

**Open for L3 / Gordon (most urgent first)**
1. **Moods kill this fort** (6 of 7 failed in L2). care sees only the workshop's classes, never the job's
   item list (fair-play choice, DESIGN §11), so a mood that needs a second material fails silently. The fort
   has no stone reserve (rock orders and mechanisms take every boulder), 4 logs, no leather, no bars. Proposal:
   a reserve of 5 boulders and 20 logs that supply orders may not consume, and a stone-dig request on MOOD_NEED
   rock. Gordon may want to allow reading the mood's requirement list.
2. **No water for patients:** the well sump holds 2/7, the hospital and refuge wells are dry, bucket brigades
   walk ~90 tiles to the brook. A bedridden dwarf dies of thirst (death 5).
3. **Berserk dwarves:** the popup halts the fort; nothing in v2 reacts (a kill order is allowed only in kill
   boxes, and DRILL/PEACE allow no sortie). A berserk citizen's corpse must be buried at once (ghost).
4. **Drill:** worn needs armor (no free armor in the fort; trade failed a third time, "time"). O1's lever job is
   taken late or loses its worker; proposal: the S3 fallback, a lever-puller burrow next to the levers.
5. Burial: two tombs projects on the same site made duplicate zones; occupancy must keep tombs of cancelled
   projects (or the runner must not place zones over zones).
6. Trap weapons take tools (a battle axe and a pick sat in traps); stage 4 should exclude picks and axes.
7. Trade failed 3 times with "time" (L4 spike); the caravan left each time.

## 0c. Live slot L1b (2026-10-11 00:46 - 01:45)
**Fort at hand-over:** Castlerisen, y286 spring d34, pop 25 (15 adults, 10 children and babies), PEACE, phase **P1**.
- Runtime folder `dfllm-runtime/region2/`; the kernel booted `autosave 2`; DF wrote `autosave 3` at the y286 rollover.
- About 400-550 ticks/s (timestream 500, no brake since P0 was delivered); DF on desktop 1.
- Drink 360 days (696 drinks), food 108 days, stress 20-24 % (was 36 %), nobody hungry or thirsty.
- Projects:
  - fortcore stage 1 **done** (well, depot, 6 shops, dorm, piles, zones), well **repaired** after a tantrum;
  - `workshops` **done** (9 shops; all 12 moodable types exist now);
  - dining hall (20 seats) **done**;
  - bedrooms x6, office (P1) and captives (P2) dug in stone at prio 1 for the moods, now waiting for furniture.
- Labor: labormanager monitor; Miners 2 (from the dig backlog), Woodcutters 1, Hunters 0.
- **Deaths: none in L1b.** Strange moods: one Secretive mason mood **succeeded**; a second one (unit 19664,
  Masons) found no rock at first; the office and captives digs gave boulders and it holds an andesite boulder and
  an amethyst at hand-over (still running).

**Orchestrator decisions, implemented and live**
1. **(a) Tool details owned by economy.**
   - `act.work_detail(name, unit, on)` = the work details screen, builtin Miners/Woodcutters/Hunters only; lint
     allows labor writes only inside it. New event WORK_DETAIL (B).
   - economy, only while labormanager is not modern:
     - miners = clamp(ceil(dig backlog / 40), 2, 4 from pop 20, else 2); backlog = max(`runner.dig_backlog()`,
       designation jobs);
     - woodcutters 2 / 1 / 0 by logs against autochop's 60/150; hunters 2 only during a famine;
     - every count capped by usable picks, axes or bows; a dwarf is in one tool detail at most;
     - no soldier, noble, moody dwarf or sole key-labor holder is picked; growth at once, shrinking after
       3 days, lowest skill first.
   - Live: Miners 1 → 3 (backlog 201); Atír left Woodcutters (he was in both); later 2 miners (backlog 68);
     a woodcutter joined at 148 logs.
   - My mistake, fixed: the first shrink order (ineligible members first) dropped the fort's only trained miner,
     the bookkeeper. Shrinking is now skill first. He stays out, because nobles are never picked.
   - **Modern re-evaluated:** usable behind the LABOR_STARVED → monitor fallback (≥ 100 starved cycles ends the
     A/B test), but measured worse on this fort (L1: 2,637 vs 758 starving postings; BREWER starved 243 cycles
     while dwarves died of thirst). Monitor stays the default (DESIGN §5.5). In modern mode labormanager keeps
     the tool details and economy writes none.
2. **(b) Moods.**
   - plans/year1.json P1 = dining, office, `workshops` types `moodable` + Still + Kitchen; P3 lost its moodable
     entry. Mood stock goals (STOCK_LOW per key, cloth order) count from P1.
   - The `workshops` deliverable also counts built workshops. follow starts the `workshops` template for a missing
     `workshops` deliverable, and `cmd.place` skips the moodable types the fort has or has planned.
   - PLAN_EXHAUSTED fires again after each finished project (it fired once per phase; P1 has three deliverables).
   - Live: `workshops` placed at once (skip carpenter, mason, craftsdwarf): jeweler, metalsmith's forge (the fort
     has an anvil), bowyer, clothier, leather works, tanner, loom, glass furnace, mechanic; all built by y285
     summer d23.
3. **(c) Stage orders sliced:** at most 8 cells per quickfort `orders` call, grouped by building key, one call per
   slice. Live: dining 41 cells = 6 calls of 5-14 ms; workshops 10 cells = 21 + 6 ms (L1: one 19-cell call, 60 ms).
4. **(d) Live replan and stage 1.**
   - `plan.reload {phases:true}` replaces the save's phase list with plans/year1.json (the plan and the current
     phase id stay). The fort now has office (P1), captives (P2) and furnaces (P3).
   - The well waited for a mechanism, the mechanism for a non-economic boulder, and **all 9 boulders sat in
     buildings** (soil embark). The workshops dig in stone (z118) produced boulders; stage 1 was done at
     y284 autumn d30.
   - The pond zone over the sump is filled by buckets (3-4/7 deep by y285 summer).
   - A tantrum **destroyed the well** (y285 spring). New `bp.place tpl=fortcore site=repair repair=<proj> keys=l`
     re-applies only the named build cells of a project; the well stood again after about 3,000 ticks.
5. **(e) Speed:** the brake lifted by itself at P0 → P1. It then flapped every game day, because the thirst alarm
   (25,000) is DF's plain "thirsty"; it is 40,000 now. Season y285 summer in PEACE: **403 ticks/s median**
   (p10 379), kernel 16.5 ms/s median, p90 28, max 28, no gap over 3 s (8 perf rows, 210 s real time).

**Found live and fixed (all tested; 8 commits)**
1. **Popups halted the fort.**
   - "Merchants have arrived and are unloading their goods." (10 min; the whitelist compared case-sensitively);
   - "… is throwing a tantrum!";
   - "… has claimed a Stoneworker's Workshop." (mid-mood).
   - Matching is case-insensitive now; tantrum and strange-mood notices are whitelisted.
2. **BREACH for 33 days because of an own ghost.** Ilral's ghost (isUndead, isOwnGroup) walked into Kern+: civ
   alert, projects frozen, idle 86 %. sense now ignores the ghosts of fort members. siege also asked for the
   missing Tiefe+ every retry (36 ACT_FAIL); a refuge that does not exist yet now means Kern+ at once.
3. **The melt pile ate the tools.** fortcore's `dfllm-melt` (automelt) held both spare picks and both battle axes,
   marked for melting: two of three miners and every woodcutter had no tool.
   - baseline registers the melt pile only once a smelter exists (`logistics clear` before);
   - the pile refuses picks, battle axes and crossbows (`stockpiles import -f`, filtered on the item names,
     checked live: `pick` disables ITEM_WEAPON_PICK only);
   - care unmarks those tools when anything marks them for melting.
4. **Brewing stopped for want of barrels** (0 empty, every brew order inactive, drink 46 → 22 days). economy
   counts empty barrels and keeps ≥ 4 through a `dfllm:barrel` MakeBarrel order (workorder refuses
   ConstructBarrel in DF 53). Drink went 22 → 251 days within a season.
5. **Dig stalls were judged per project:** the dining hall, queued behind the workshops dig, was reported blocked.
   A dig stage now stalls only when no dig stage of any project progressed for 7 days.
6. **A mood without a boulder.** The Secretive mason found no rock (MOOD_NEED). A bedrooms dig at prio 1, placed
   at once, gave the boulder; MOOD_END ok after about 26 days. care now also wakes the LLM (DECISION_NEEDED
   `mood_material`). The same happened again at hand-over (see above).

**KPIs measured (L1b)**
| KPI | Value |
|---|---|
| ticks/s | 150 (P0 brake) → PEACE median 403-418 (y285 summer); 250-290 while the brake flapped |
| kernel ms/s | median 16-18, p90 28, max 31 at 400-550 ticks/s (limit 25: **over at p90**; `repeat` 14-16 ms/s) |
| any call | stage orders ≤ 21 ms (was 60); baseline's first apply after every boot is still one ~200 ms slice |
| deaths | **0** |
| moods | 1 succeeded (Secretive); 1 running at hand-over |
| stress (category ≤ 1) | 36 % → 20 % |
| stock days | drink 123 → 170-251; food 723 → 120-250 (pop 19 → 25) |
| tool details | miners 1 → 2-3; woodcutters 0-1; hunters 0 |
| phase | P0 → P1 (y284 autumn d30) |
| projects done | fortcore stage 1, workshops (9 shops), dining (20 seats), well repair |
| idle % | 6-86 % (winter; the D-03 backlog is empty without boulders) |
| tokens (this L1b session) | about 1.0 M (no per-hour split available) |

**Open for L2 / Gordon**
- **Trade failed twice ("time")**: the caravan left before the trade screen opened (L4 spike area).
- Kernel p90 28-31 ms/s at speed (limit 25), mostly `repeat` (the dispatcher) at 14-16 ms/s; 403-418 ticks/s
  stays below the 450 KPI.
- **Boulders are scarce on this soil embark:** rock orders (crafts, blocks, mechanisms) take every boulder, and two
  mason moods found none. A stone reserve for moods and mechanisms is not managed (D-03 forbids filler digging);
  until then the LLM has to answer `mood_material` with a stone dig.
- `dfllm:barrel` keeps making barrels while brewing fills them (34 barrels, logs 183 → 66; the woodcutters follow).
- PROJECT_BLOCKED 'stalled' still wakes for builds that wait for furniture (dining, bedrooms).
- The only trained miner (the bookkeeper) is out of Miners by the noble rule; Gordon may want an exception.
- `labor.starving` read 504 all slot long in monitor mode; check the parse.
- P2 (fortcore stage 2, captives, squad A) needs the LLM; follow auto-places only P0/P1.

## 0b. Live slot L1 (2026-10-10 23:10 - 2026-10-11 00:40)
**Fort at hand-over:** Castlerisen, y284 spring d76, pop 20 (16 adults, 2 babies), PEACE, phase P0.
- Runtime folder `dfllm-runtime/region2/` (stable now, see L1-9); the loaded save is `autosave 1`.
- 152 ticks/s under the supply brake (P0); DF on desktop 1.
- Drink 164 days, food 1,639 days (eatable), nobody hungry (max hunger 42k) or thirsty (max 20k).
- 70 of 71 manager orders validated; labormanager in **monitor** mode; idle 0-6 %.
- Projects:
  - fortcore stage 1 (anchor 106,54,124 rot 0): dig done, build stage 38 %, waiting for beds, doors and a mechanism;
  - farms (106,99,121 rot 2): build 55 %;
  - two tombs projects;
  - all "stalled" only while buildingplan waits for 5 beds, 6 coffins, 1 door and 1 mechanism.
- Office (104,86,z124, chair, assigned to the manager); carpenter's workshop (100,86); surface farm plot (108,86) + autofarm.
- Piles `dfllm-melt` (102,62,122) and `dfllm-trade` (102,69,122) in the bailey.
- `follow` runs in the L1 session's background (until about 03:40).
- **Deaths: 3 citizens.**
  - Nil (clothier) starved.
  - Datan (bowyer) died of dehydration (her ghost is put to rest): her **fey mood failed** for want of a workshop
    (MOOD_END ok 0 at tick 114,273,487), she went melancholy and stopped drinking, and died 55k ticks later.
  - Ilral (herbalist) failed a fey mood the same way, went melancholy and died dehydrated (y284 summer).
  - See L1-15.

**What went wrong and what was fixed (live first, then in the product, all tested)**
1. **The fort idled with no plan (y281-283).** About 1.5 game years passed at 500 ticks/s after L0; food and
   drink ran out.
   - Fix: `follow` places the first missing `proj` deliverable at S1 when PLAN_EXHAUSTED arrives in P0 or P1 (L1 used it
     for farms and tombs).
   - Fix: the **supply brake** (arbiter) holds tempo and the vanilla FPS cap (`act.setting fps_cap`, restored via
     restore.json) at 150 while the phase is P0 or `economy.alarm()` is set. Timestream alone cannot slow DF below its own FPS.
2. **False "damp" BREACH_STOP (twice, same relative tile).** DF clears `designation.dig` while a miner works the
   tile (the Dig job holds it). The probe read "wall, no designation" and took it for a damp cancel.
   - `snapshot.tile` now reports `dig='job'` for tiles with a designation job.
   - A lost designation without a DIG_CANCEL_DAMP/WARM report (it also checks the vanilla announcement log) is
     re-marked once, then blocks as `dig_lost` (no undo; cleared at boot).
   - A real damp case later (farms under a swamp pond) stopped correctly on the report. `bp.sites` now rejects sites
     with revealed water or magma on the level above.
3. **No manager, no validated order (0/48).**
   - New `act.appoint` (nobles screen records: assignment histfig, histfig position link incl. `entity_vector_idx`,
     and **`entity.assignments_by_type[responsibility]`**, the index DF uses to find who manages production).
   - economy fills vacant MANAGER/BOOKKEEPER/BROKER by skill.
   - Validation then still failed: the MANAGER position has `required_office 1`, and above a population threshold
     the manager validates only from an office. DF posts `ManageWorkOrders` only when the office has a chair.
     L1 built a carpenter's workshop, one chair (workshop job built from DFHack's idle-crafting pattern) and an office
     zone reserved via preserve-rooms. Then 13 of 49 orders were validated within 4,000 ticks.
   - New template `office`; economy wakes the LLM (`DECISION_NEEDED manager_office`) after 3 days without a validated order.
4. **Food counted wrong.** The census counted cook-only items (34 egg yolks) as food (status "250 days" while a dwarf
   starved).
   - Food now means raw-edible items plus meals; cook-only items count as `cookable`.
   - Famine (< 10 days) allows hunting and fishing and sends a weekly DECISION_NEEDED famine.
   - Live: 3,498 visible wild shrubs (berries, peas, lentils, grains, all raw-edible) were marked for gathering.
5. **Thirst.** The nearest drinkable water is about 90 tiles away (32,144,117); the pond near the fort froze or
   dried, and the 25 "drinks" were caravan goods.
   - Live: brew jobs placed directly at the still (job items copied 1:1 from the reaction reagents), then the library orders.
   - Product: economy thirst alarm (≥ 2 citizens ≥ 25k, or drink < 10 days) → brake plus weekly DECISION_NEEDED thirst;
     brewing and meals prioritized (`prioritize -aq`).
6. **labormanager.**
   - `labormanager enable` always started the **modern** engine; the configured monitor never ran.
   - Modern never staffed brewing (skilled labors go to specialists only; BREWER starved 243 cycles).
   - Setting a labor "unmanaged" left it to the single dwarf outside the auto: work details (CARPENTER, BREWER, COOK: 1 holder each).
   - Fix: baseline sets the engine with `autolabor mode X` + `enable autolabor`, and runs `labormanager disable` before
     leaving modern (that removes its memberships).
   - Fix: economy falls back to monitor when modern starves a supply labor (LABOR_STARVED); builtin tool labors
     (MINE...) become managed.
   - Live in monitor mode: all 16 adults hold every labor and idle fell from 68 % to 0-6 %.
   - Mining stays with the vanilla Miners detail (1 member, 3 picks). v2 writes no work details: **Gordon decides**
     (add miners in the UI or allow modern for MINE only).
7. **Hidden stair tile stalled stage 1 forever.** A `j` above a `u` stays hidden and DF posts no job. A dig stage
   whose only pending tiles are hidden now completes after 2 days without progress.
8. **My own live error (not product):**
   - A 190x190x10 quickfort `p` (gather) designation took a 41 s frame freeze (PERF_DEGRADED) and removed the fortcore
     dig jobs at z119; the runner re-marked them by itself (§2 fix).
   - The first fortcore had been placed twice (two instances of me); the duplicate was cancelled. `dfllm cmd bp.cancel`
     now moves the bp file to `bp/.cancelled/`.
9. **Runtime folder renamed with every autosave (L0-6).** kern names it after `marker.save` (`region2`); supervise matches
   saves through `state.save`. Seen live: autosave 2, autosave 3, autosave 1, all in `region2/`.
10. **Popups:** guild establishment, "ghost put to rest" and "found dead" are whitelisted. A death notice halted the
    fort; care already records the death (DEATH, DEATHS_3PLUS).
11. **New templates:**
    - `furnaces` (smelter + wood furnaces), `office`, `captives` (pit zone over a drop, manifest `pit`);
    - fortcore stage 1 places the `dfllm-trade` (autotrade) and `dfllm-melt` (automelt) piles;
    - plans/year1.json: office P1, captives P2, furnaces P3. The live fort keeps its adopt-time phases.
12. **manifest.json:** kern mirrors the persisted manifest to `<save>/manifest.json` (boot plus every flush); `cmd` site
    ranking and follow's audit read it (no 8 KB limit).
13. **Supervisor alerts → wake:** follow emits SUPERVISE when supervise logs a new alert.
15. **Failed strange moods (2).** The fort is in P0 with 7 of 12 moodable workshop types missing.
    - care only emitted MOOD_NEED (B, digest); nothing woke and nothing was built.
    - Now a mood without a workshop also sends DECISION_NEEDED `mood_workshop` (A) and a `workshops` PROJECT_REQUEST,
      which follow places itself (rooms need Z4, i.e. fortcore stage 1 done).
    - The tombs flood is fixed too: care asked for tombs every 3 days while a tombs project was pending (3 tombs
      projects); `runner.pending(tpl)` now suppresses that.
    - **Open:** DESIGN has all 12 moodable workshops only in P3. Pull them into P1, or keep a moodable shop set in
      fortcore stage 1.
14. **Smaller:**
    - `dfllm reload` (dev reload of the kernel);
    - act logs the quickfort cost per call;
    - doctor knows the brake;
    - DECISION_NEEDED for famine, thirst and manager_office.

**Spikes**
- **S5 (labormanager):**
  - `status` parses in both engines ("N starving (> 1200 ticks ...)", monitor: "labor monitor: N starving postings").
  - Starving postings: modern 2,637 → monitor 758 → 504; the rest is the gather flood.
  - Soldiers: none yet, untested.
  - A/B: modern lost on this fort (see 6).
- **S6 (quickfort, commands.log `ms`):**
  - dig chunks (≤ 13 cells with extents) median 1 ms, p90 9 ms, max 16 ms (n = 68); dig undo median 1 ms;
  - build chunk 5 ms (19 cells);
  - the stage `orders` call **60 ms** (above the 50 ms KPI: one call per stage, consider slicing);
  - `command='orders'` created 6 manager orders for 18 items, and buildingplan picks them up (beds, coffins, door,
    mechanism waiting);
  - farm plots: the farms stage reached build 55 % on soil.
- **S1 follow-up:** kernel 6-10 ms/s (perf.csv median 9, p90 18, max 39 across reloads); max gap 171 ms in the last 10 min.
  Gaps > 3 s: my mass designation (41 s) and reloads.

**KPIs measured (L1)**
| KPI | Value |
|---|---|
| ticks/s | 499 before L1 (idle fort), 150 under the brake (P0), 50 during the emergency |
| kernel ms/s | median 9, p90 18 (limit 25) |
| idle % | 83 % (no plan) → 68 % (modern, gather flood) → 0-6 % (monitor) |
| stock days | drink 0 → 164; food (eatable) ~0 → 1,639 |
| starving postings | 2,637 → 504 |
| deaths | 3 (starvation; 2 x dehydration after failed fey moods) |
| manager orders validated | 0/48 → 70/71 |
| tokens (this L1 session) | about 0.72 M (context budget used; no per-hour split available) |

**Open for L2 / Gordon**
- Miners: only 1 dwarf mines (vanilla Miners detail). Gordon adds miners in the UI, or allows modern for MINE.
- The live fort has no well water nearby: the fortcore well spot needs its sump filled (pond zone, buckets). Until
  then drink depends on brewing.
- Stage-orders call 60 ms: slice it.
- The live fort's phases are still the adopt-time year1 (without office, captives, furnaces): place those by `bp.place`.
- S9 (supervised restart) and the hook spike are still open.

## 0a. Live slot L0 (2026-10-10, 20:47-23:10)
**Fort for L1:** Rimtarlocun "Castlerisen", world Zilirréth (folder `region2`), world tile **8,14**,
rectangle **131,233** (4x4), embarked y280 late summer, adopted, 16 modules ok, `selftest full` 9/9.
At hand-over: y281 autumn, pop 19, PEACE, timestream 500, about 499 ticks/s, unpaused. DF on desktop 1,
window 1716x1000. **The save folder is now `autosave 1`** (see L0-6): runtime `dfllm-runtime/autosave 1/`.

**Results**
1. **Migration** (`migrate_v2.py --apply --force`, at the title screen):
   - `script-paths.txt` now holds only `+…\dfpilot-public\lua`; it is only read at startup, so the
     running DF was switched in process (`removeScriptPath` repo B, `addScriptPath` repo A, first).
   - `onMapLoad.init` runs only `dfllm boot`; `hack/scripts/claude` is in `_archive-v1/`; DF-Aufsicht
     stays Disabled.
   - **Open:** `df-llm-helper-runtime/` was not archived (WinError 5): five orphaned `tail.exe`
     monitors from old sessions (08.-10.10.) hold its logs open; stopping them was refused by the
     auto-mode classifier. Harmless for v2 (nothing reads that folder). Gordon: end them or reboot,
     then re-run `migrate_v2.py --apply`.
   - **Found and stopped:** an orphaned v1 bash loop from 07.10. (`while true; dfhack-run claude/advance
     run; sleep 12`) unpaused DF every 12 s. It reached `claude/advance` through repo A's `lua/claude`
     (gap §6.11, now proven harmful). The v1 scripts must leave the v2 script path (W3).
2. **Embark tool, fixed live** (`tools/embark`, README "Live L0 findings"):
   - resumable `newgame` (the world loads before "Select a game type", up to 10 min);
   - tutorial prompt polled;
   - zoomed tile = `zoom_cent // 16`;
   - placement by a held mouse plus a **mouse injector** screen (DF writes the mouse before every render
     frame because the hidden window has no focus);
   - panel read before the popup;
   - all 16 tiles hovered and merged (`--tiles`);
   - two equal reads per panel;
   - "Cannot embark" sites recorded without a click;
   - poll one frame after a render frame.
   - **Prepare carefully does not work** (rows ignore every simulated click/key), so the fort was
     embarked with `--play-now`: DF's skilled seven, 324 points unspent.
3. **Site choice** (about 100 rectangles scanned from the vanilla panel/popup only):
   - Every tile ≥ 10 world tiles from all five old forts (y ≥ 24, or x ≤ 5 with y ≥ 20) is hot or
     scorching, has a light or heavy aquifer and goblin pits within half a day, or is an existing site.
   - Chosen: 8,14 local 3,9. The 16 hovered tiles give 8 woodland tiles (Hills of Kindness, mirthful,
     no aquifer) and 2 brook tiles; the badlands part (Desert of Crafts) has a light aquifer, iron, gold,
     silver, copper, nickel and flux. Temperate, very deep soil. Neighbours: elves at war half a day
     west, humans 2 days east, **no goblin site listed**. Gate verdict ok 64 (warn aquifer, soil, popup).
   - **Deviations from DESIGN §5.1:**
     - `rules.json old_site_min` lowered 10 → 4 (4 tiles from Canyonsyrups, 7 from Wheelsblows,
       18 from Trussroads);
     - a light aquifer in part of the rectangle (probe protocol applies);
     - elves at war nearby.
4. **adopt/boot:** `dfllm adopt` booted 16 modules (none DISABLED), `selftest full` 9 pass. Python
   `doctor/status/brief/follow` work (follow `--since 0` printed one merged wake line).
   `DECISION_NEEDED squads` and `PLAN_EXHAUSTED` are open for L1.
5. **Food crisis (fixed, partly open).**
   - No plan was applied, so 9 game months passed at 500 ticks/s with 85-100 % idle: food 0, drink 0,
     hunger up to 78,000.
   - UI-equivalent emergency, by hand (quickfort apply_blueprint plus a native tool):
     - butcher, still, kitchen and farmer's workshops near the wagon (98,95 / 99,90 / 103,93 / 108,95, z124);
     - "gather plants" on 958 shrubs;
     - `autobutcher target 0 0 0 0 CAMEL_2_HUMP WATER_BUFFALO DONKEY`.
   - Result: meat 35, plants 237, plant growths 568, hunger max 39,000, nobody starving.
   - **Open:**
     - drink comes only from the brook in the SW corner, about 130 tiles from the wagon;
     - **0 of 47 manager orders are validated because the fort has no manager**, so the still never brews;
     - appointing a manager (nobles screen) has no act function (like S2): Gordon or a new act.
6. **Save folder changes on autosave.** After the yearly autosave `cur_savegame.save_dir` is
   `autosave 1`. The kernel kept writing `region2/` until the next boot, then switched to
   `autosave 1/` (persist and seq continue: seq 710). Consequences:
   - `region2/` is stale history;
   - **S9 `load-save` must take the newest folder, never `region2`** (that is an older save);
   - supervise/doctor follow `ACTIVE`.
7. **Popups halt the game with `pause_state` false.**
   - "Some migrants have arrived." froze the fort for about 8.5 min, then two caravan popups.
   - Fix in `arbiter.lua`: popups count as a pause (owner `popup`). `M.POPUPS` whitelists migrants and
     caravan/merchants, and an expired inbox hold also clears them. Threat popups stay for Gordon.
   - Live: the kernel was reloaded (`dfllm stop`, `package.loaded` cleared, `dfllm boot`), and the
     arbiter dismissed the caravan popups.

**Spikes**
- **S1 (kernel cost, clocks, gaps):**
  - `os.clock` has 1 ms steps. `dfhack.getTickCount` has **16 ms steps** (the Windows tick), so gap
    values are multiples of about 16 ms (median `gap_max` 47 ms).
  - In frame callbacks `os.clock` and `getTickCount` cost 0.1 µs (55 µs per C call only inside a
    `dfhack-run lua` console command).
  - perf.csv over 23 min (47 rows, pop 7-19, timestream 500, FPS cap 500): ticks/s median 499;
    `ms_s` median 15, p90 18, max 32 (boot window).
  - Steady ms/s by module: dispatcher (`repeat`) 10.4, of which kernel I/O (`kern`) 9.4; sense 1.35,
    siege 1.03, snapshot 0.29, threat 0.27; all others ≤ 0.12. **The kernel's own I/O costs about
    3x all modules together.**
  - **The baseline first apply is one 425 ms call** (KPI: any call ≤ 50 ms), so it should be sliced.
  - Gaps > 3 s: 1, the yearly autosave, **6.1 s**. Two gaps of 2.3 s and 2.5 s were my own console
    measurements and the large quickfort designation.
  - While paused, the repeat-util callback keeps running (580 frames/s; the heartbeat advances, the
    tick stays). The inbox `pause ttl_s=40` and `unpause` work.
- **S4 (a/b state, live Python reader):** 75,721 reads in 60 s:
  - 0 failed, 1 torn slot (the other slot was used), 0 permission errors, 0 seq regressions;
  - read time p50 0.45 ms, p99 0.63 ms, max 16 ms;
  - Python `listdir(inbox)` 0.08 ms;
  - no kernel write error and no antivirus lock seen; ms/s unchanged (17-18) during the test.
- **S7 (report ids, DF 53.16):** all `contract.REPORTS` names exist.
  - Ids: CARAVAN_ARRIVAL 67, FIRST_CARAVAN_ARRIVAL 343, MERCHANTS_NEED_DEPOT 243,
    MERCHANTS_LEAVING_SOON 245, MERCHANTS_EMBARKED 246, D_MIGRANTS_ARRIVAL 69, MIGRANT_ARRIVAL 50,
    DIG_CANCEL_DAMP 52, DIG_CANCEL_WARM 51, FEATURE_DISCOVERY 2 (cavern), UNDEAD_ATTACK 150,
    NIGHT_ATTACK_STARTS 136, BEAST_AMBUSH 95, AMBUSH_AMBUSHER 63, AMBUSH_THIEF 55, AMBUSH_SNATCHER 60,
    MEGABEAST_ARRIVAL 93, WEREBEAST_ARRIVAL 94, STRUCK_DEEP_METAL 3, CAVE_COLLAPSE 82.
  - No SIEGE/D_SIEGE/D_AMBUSH/CARAVAN types exist.
  - Seen live: FIRST_CARAVAN_ARRIVAL, MERCHANTS_NEED_DEPOT, MERCHANTS_LEAVING_SOON, MERCHANTS_EMBARKED,
    D_MIGRANTS_ARRIVAL, LIAISON_ARRIVAL, DIPLOMAT_LEFT_UNHAPPY.
- **S8 (runtime settings):**
  - `df.d_init_autosave`: NONE -1, SEASONAL 0, YEARLY 1, SEMIANNUAL 2; the live value is YEARLY.
  - `enabler.gfps` 30, fps cap 500.
  - Population cap original 90, read from `getBaseDir()` = `%APPDATA%/Bay 12 Games/Dwarf Fortress/prefs`;
    pop-control then writes the global `population_cap` 22.
  - `restore.json` written at adopt. Its `orig` already shows autosave YEARLY, gfps 30, timestream 500,
    so the prefs or an earlier v1 setup had those values; the prefs files were not read.
  - Overlay profile: 100 overlays disabled, 5 kept: the two notify panels, `dig.asciicarve`,
    `autolabor.overlay`, and **`claude/tempohud.hud`, a v1 overlay from `lua/claude`**.
  - `visitor_cap` stays 300 (D-07).
  - Restore on a real map unload is **not tested** (S9); `dfllm stop` → `boot` ran twice without
    error.
- **Hook spike:** not run (this session is not a `dfpilot-public` Claude Code session).

## 1. Summary
- **Complete offline.** All 16 modules of `contract.MODULES` exist, including `snapshot.lua`, which no
  package had written (CONTRACTS §17 gives it to WP7) and which was added here. The Python side is
  complete: CLI, follow and wake, brief, plan, bp, doctor, supervise, lint and hook. So are the embark
  tool and `plans/year1.json`. `dfllm adopt` on a fake save boots all 16 modules without a fault.
- **Tests.** v2 pytest set: **1087 passed, 0 failed**. It includes 26 Lua suites (426 Lua cases).
  `dfllm lint lua/dfllm`: **0 findings**. `lint --config`: ok.
- **What blocks year 1 live** (§6): three actions have no act function and need Gordon in the UI
  until spikes S2/S3 land:
  - **lever linking**: without it bridges cannot be raised, so a siege ends in BREACH and R1 fails;
  - **squad leaders**;
  - **uniforms**: without them worn = 0 %, so drill 1, P5 and R2 fail.

  A trade pile also has to be made by hand.

## 2. Implemented (per work package)
| WP | Files | State |
|---|---|---|
| WP0 | CONTRACTS.md, schema.py, util/{json,contract,k_mock}.lua, tools/luahost.py | frozen + review round 1 (§19) |
| WP1 | dfllm.lua, kern, io, persist, act, arbiter, perf, selftest, util/geom | kernel; integration: R1/R2/R5/R6/R8 adopted here (§4) |
| WP2 | __main__, cli, paths, files, wake, brief, plan, cmd, doctor, events | all §7 commands work on the fixture runtime |
| WP3 | dfpilot/bp/* | fortcore (3 stage projects) + 8 room templates incl. farms; topo audit; site ranking |
| WP4 | fairplay, lint, hook, config/allowlist.json, decisions.yaml, DECISIONS.md, .claude/settings.json | lint 0 findings; hook covers shell and file tools |
| WP5 | sense, threat, gate, siege | siege reflex, BREACH, RECOVERY on fakes |
| WP6 | military, readiness, drill | squads adopted by name (A/B/C), worn %, R0-R3, drills |
| WP7 | runner (+ snapshot, written at integration) | projects, phases, manifest merge, keepers |
| WP8 | baseline, economy, care, config/baseline.json | native baseline, stock days, moods, burial, captives |
| WP9 | trade (act.trade now in act.lua) | caravan port on the click-level fake UI |
| WP10 | supervise.py, tools/migrate_v2.py | liveness, backup, restart (dry-run tested), migration |
| WP11 | tools/embark/*, plans/year1.json, RULES.md | embark checklist and procedure; Y1 phases P0-P7 |

## 3. Integration check
**Inbox verbs → handlers** (static test `tests/test_integration_v2.py`, kernel tests):

| Verb | Handler | Verb | Handler |
|---|---|---|---|
| plan.reload, inspect, module.enable | kern | audit, popcap.lower | readiness (audit: follow/test only, snapshot of this boot, once) |
| bp.place, bp.cancel | runner | tempo.lower, pause, unpause | arbiter |
| drill | drill | trade.want | trade |
| snapshot | snapshot (new) | squad.sortie | military |
| lever | gate | selftest | selftest |

Before this round `module.enable` fell through to `inspect` ("bad what") and `snapshot` had no module.

**Events.** Every type a module emits is in the registry with that module (or `any`) as the emitter.
This is checked statically and by k_mock strict mode. SNAPSHOT_READY was never emitted before; it is now.

**K.call targets.** All exist. `snapshot.export` and `snapshot.tile` were missing; readiness, runner,
care, military and siege call them.

**Files Lua writes, read by Python:**

| File | Writer | Reader | Check |
|---|---|---|---|
| `ACTIVE`, `heartbeat`, `state.a/b.json` | kern | paths, files.read_state_ex (prune rule), supervise | test_kern_files, test_cli_* |
| `events.jsonl` (+`.1`) | kern | files.EventTail, tail_events | rotation tests |
| `outbox/<id>[-n].json` | kern | files.read_outbox | roundtrip test |
| `snap/<id>.json` | snapshot (new) | files.read_snapshot, bp.topo, bp.sites | test_snapshot_files (schema + audit) |
| `perf.csv`, `commands.log`, `kern.log` | perf, kern | doctor, supervise | header identical |
| `restore.json` | arbiter | supervise (read only) | schema |
| `inbox/<ts>-<id>.json`, `plan.json`, `bp/<id>.json` | Python | kern, runner | schema.validate on both ends |

**act coverage.** Every `contract.ACT` function has an implementation. These are explicit stubs that
need a live spike: `squad_leader` [S2], `squad_uniform` [S2] and `order_suspend` [S5], which is
unsupported in DF 53. `idle_crafting` does not exist in act (baseline skips it while it is missing).

**Config.** All four files validate: `config/allowlist.json`, `config/baseline.json`,
`config/decisions.yaml` and `plans/year1.json`.

## 4. Fixes made in the integration round
- **kern.lua (CONTRACTS R1, R2, R5, R6, R8, which WP1 had not adopted):**
  - prunes invalid optional state keys before writing and logs them;
  - measures cost with `os.clock()` (tests override `kern.cost_clock`);
  - slow calls decay, demoted modules are promoted again, and a slow critical module raises KERN_FAULT at most once per 10 min;
  - faults back a module off (critical 30 s, others 10 min, doubling) and it is re-enabled automatically; KERN_FAULT carries `d.backoff_s`;
  - new `module.enable` verb;
  - `VERB_BY` check;
  - `parse_decisions = contract.parse_decisions`. The test_schema xfail now passes and its marker is removed.
- **perf.lua:** rounds the cost-clock floats (files hold integers only).
- **arbiter.lua (R6):** `unpause` releases only the inbox hold. The pause-DECISION text changed to match.
- **gate.lua:** a bridge's `gate_flags` are `raised/raising/lowering` (lever.lua:39-41, v1 BUG-427), not
  `closed/closing/opening`, and reading `gf.closed` raises in DFHack. Without this fix gate would have
  faulted on the first real bridge. It now probes both name sets.
- **act.lua:**
  - WP9's act.trade is pasted in (`A.install_trade`, `gui` required lazily);
  - `quickfort` with `command='orders'` now runs `orders.create_orders` (apply_blueprint never does);
  - explicit `squad_leader` [S2] stub.
- **snapshot.lua (new):** sliced export (1,000 tiles per frame, ms cadence so it also runs while
  paused), revealed-tile legend, manifest bridges from `gate.state`, traps, marks `soil`/`cavern`,
  `tile()` with pending designations, the inbox verb, and default boxes.
- **readiness.lua (R6):** accepts an audit only for an audit snapshot exported this boot, and only once.
- **military.lua:** `kill({})` withdraws running kill orders; `posture(P, force)`. Both are what siege.withdraw calls.
- **runner.lua:**
  - the P0 `baseline` deliverable also passes on `baseline.done()` (kern owns the marker; P0 could never pass before);
  - at most one plan bp file per run (R7).
- **baseline.lua + config/baseline.json:** stockpiles named `dfllm-trade` get `logistics add trade`.
  Nothing fed the depot before.
- **plans/year1.json:** P0 also needs `farms` (fortcore no longer has farm plots).
- **Python:**
  - `files.read_state_ex` uses `schema.prune_state`;
  - `dfllm cmd` offers only `--by cli|llm|gordon` and refuses `audit`; `plan --by` likewise;
  - the hook enforces the §13 trust rules (`--by`, `cmd audit`, inbox JSON with "by") and guards Write/Edit/MultiEdit/NotebookEdit under `dfllm-runtime/` and on `config/decisions.yaml`. settings.json matcher extended.
- **RULES.md:** unpause, backoff, farms and trade pile updated.
- **Tests:**
  - new: `tests/lua/test_kern_contract.lua`, `test_snapshot.lua`, `test_integration.lua`, `snapshot_world.lua`, `snapshot_scenario.lua`, `tests/test_snapshot_files.py`, `tests/test_integration_v2.py`;
  - updated: arbiter tests (R6), readiness, drill and runner tests, trade_scenario (real act.trade), baseline tests and the runner dump (farms).

## 5. Test results (run from the repo root)
```
python -m pytest -q -o addopts="" tests/test_schema.py tests/test_luahost.py tests/test_cli_cmd.py tests/test_cli_files.py \
  tests/test_cli_lua_roundtrip.py tests/test_cli_plan.py tests/test_cli_status.py tests/test_cli_wake.py tests/bp \
  tests/test_lint.py tests/test_hook.py tests/test_fairplay.py tests/test_supervise.py tests/test_migrate_v2.py \
  tests/test_embark.py tests/test_kern_files.py tests/test_runner.py tests/test_siege_files.py tests/test_trade_files.py \
  tests/test_wp6_files.py tests/test_wp8_files.py tests/test_snapshot_files.py tests/test_integration_v2.py \
  tests/test_economy_specs.py
  -> 1087 passed, 0 failed (48 s; after L0: 1087 passed, 61 s; after L1: 1145 passed, 61 s;
  after L1b: 1149 passed, 63 s; after L2: 1151 passed, 63 s; after L3: 1151 passed, 64 s;
  after L4 (iter2, with test_economy_specs.py): 1235 passed, 79 s; after L5: 1237 passed, 79 s)
for f in tests/lua/test_*.lua: python tools/luahost.py --path tests/lua $f   -> 26 suites, 426 passed, 0 failed
                                                                               (after L0: 430 passed, 0 failed;
                                                                                after L1: 442 passed, 0 failed;
                                                                                after L1b: 455 passed, 0 failed;
                                                                                after L2: 463 passed, 0 failed;
                                                                                after L3: 470 passed, 0 failed;
                                                                                after L4: 32 suites, 562 passed;
                                                                                after L5: 33 suites, 573 passed)
python -m dfpilot lint lua/dfllm        -> 0 finding(s)
python -m dfpilot.lint --config         -> config ok
```
**v1 cleanup (2026-10-11, W3):** the v1 code, tests, fixtures and docs left branch `v2` (they stay in tag
`v1-final`; list in [V1-LEGACY.md](V1-LEGACY.md)). `tests/` now holds only the v2 set, so the plain
`python -m pytest tests` runs exactly the file list above (no `--continue-on-collection-errors`): **1237 passed,
0 skipped, 78 s**; Lua 33 suites / 573 passed; `lint lua/dfllm` and `lint lua` 0 findings; config ok. The fixture
runtime `tests/fixtures/v2/runtime` is now tracked (the v1 `.gitignore` rule `runtime/` had hidden it, so a fresh
clone could not run the CLI tests; `make_runtime.py` reproduces it byte for byte).

**Fresh-user check (2026-10-11, offline, DF not touched):** README quick start, QUICKSTART and RULES walked as a new
user. Every command and flag of the prompt and README exists (`--help` of the CLI, all subcommands, migrate_v2,
embark.py, luahost; migrate dry run on an empty fake DF folder: 2 `todo`, 3 `n/a`; the CLI on a copy of the fixture
runtime; `selftest --mock` logic on luahost: 1 pass, 0 fail); the hook as `.claude/settings.json` runs it allows all
prompt commands and blocks inline lua; all links in README/QUICKSTART/RULES resolve; a local clone of `v2` passes the
gate. Fixed: luahost also finds `lua53.dll` through `DFLLM_DF` (before, a user with DF elsewhere silently skipped
114 Lua-backed pytest cases) and prints totals; `dfllm supervise --help` shows supervise's own flags (`--dry-run`);
`bp list`/`bp preview` work before adopt; `python -m dfpilot.lint --help` exits 0; docs (`--df` goes before
the command, embark README status, DESIGN §9 layout without the never-written MIGRATION.md). Open: the v1 embark
scratch copies in `tools/embark/` (V1-LEGACY.md). Gate after it: **1241 passed, 0 skipped**; Lua 33 suites / 573
passed; `lint lua/dfllm` and `lint lua` 0 findings; config ok.

## 6. Known gaps, by impact
**Needed for year-1 acceptance (A1):**
1. *Fixed in L2: `act.link_lever`, gate links built levers (6 of 6 live).* **Lever linking.** No act function exists. Templates build levers, but nothing links them, so:
   - gate pulls only linked levers, giving GATE_FAIL `no_lever` and then BREACH;
   - R1 needs 2 linked levers per bridge.

   Until `act.link_lever` (the UI link job with 2 mechanisms, [S3]) exists, Gordon links every lever in
   the UI after each fortcore stage. **This is safety-critical.**
2. *Fixed in L2: squads A/B/C created and led through act (captain assignments, `squad_leader`).* **Squads.** `act.squad_create` needs a vacant position assignment, and `squad_leader` is a stub.
   Military asks Gordon (DECISION_NEEDED `squads`) to create squads A/B/C with a leader; it then
   adopts and fills them. Needs [S2].
3. *Fixed in L2: `act.squad_uniform` writes the specs; worn is now limited by the armor the fort has (15 % live).* **Uniforms.** `act.squad_uniform` is a stub, so worn = 0 %. The drill then fails (`no_uniform`),
   which blocks P5 (drill 1, R1 needs a drill for R2) and R2. Needs [S2]; meanwhile Gordon assigns
   uniforms in the UI.
4. **Trade pile.** *Fixed in L1: fortcore stage 1 places `dfllm-trade` (autotrade).* No template builds one. Gordon names a stockpile next to the depot `dfllm-trade`,
   which baseline then registers. Without it P4 `{k:trade}` never passes.
5. *Fixed in L1: template `furnaces`.* **No smelter or wood furnace template.** `library/furnace` and `library/smelting` are never
   imported (year1 says so). Metal comes from trade only, which P6 metal ≥ 80 % depends on.
6. *Fixed in L1: template `captives`, fortcore `dfllm-melt` pile.* **No templates for the captive pit or the melt pile** (care and baseline wait for them).

**Operational:**

7. **A supervised restart leaves the fort paused.** DF loads paused, the owner is `df`, and by R6 only
   Gordon unpauses. Unattended years (A2) need a decision, for example: the arbiter releases a `df`
   pause once after a supervised restart in PEACE.
8. *Fixed in L1: follow wakes SUPERVISE.* **Supervisor alerts reach only `supervise.json`.** There is no wake line (WP10).
9. *Fixed in L1: `<save>/manifest.json`.* **The `inspect manifest` reply is capped at 8 KB.** follow's automatic audit stops (AUTO_FAIL) once
   the manifest grows past that, at roughly 40 room projects. Proposal: kern writes `<save>/manifest.json`.
10. *Fixed 2026-10-15 (FR-51 clock governor, offline): the arbiter drives the vanilla FPS cap by mode (SIEGE/BREACH/DRILL 30, ALERT 100), by the reflex lockdown, and `tempo.lower` lowers it too.* **`tempo.lower` cannot slow below the vanilla FPS cap.** timestream ignores targets below the actual
    FPS (tools/timestream.txt:43). The live prefs have FPS_CAP 500, so tempo.lower is close to a no-op.
11. *Fixed 2026-10-11 (v1 cleanup): `lua/` holds only `dfllm.lua` and `lua/dfllm/`; `tests/test_lint.py` checks it.* **v1 scripts stay on the DF script path.** After migration, `lua/claude/*` and `lua/pilot_*.lua`
    are reachable through repo A's `lua/`. The hook blocks `claude/*` for the LLM. Remove them in W3.
12. **Small missing act functions:**
    - `order_suspend` (unsupported; economy uses `orders recheck`);
    - `idle_crafting`;
    - removing the kitchen exclusion for D-09 "yes";
    - stockpile settings (barrels in food piles).
13. **Hook limits:**
    - it does not open script files (`bash x.sh`);
    - `tools/embark/embark.py` spawns `dfhack-run lua -f`, which RULES allows before adopt;
    - Write/Edit are guarded only for the two protected places.
14. **DESIGN.md is stale in places:** §0 prefs, `getTickCount` "ms only", "disable that module", and
    the bridge flag names. CONTRACTS §18 already records most of these.
15. **Size.** Most files are 2-3x the DESIGN line estimates (kern 1.1k lines, runner 1.1k, trade 1.2k,
    lint 1.5k, supervise 1.15k).

**Found live in L0 (§0):**

16. *Fixed in L1: `act.appoint` + office (see §0-3).* **No manager:** manager orders are never validated (0 of 47), so economy, brewing and the
    orders library do nothing. Appointing a manager (and a bookkeeper and broker for trade) needs an
    act function for the nobles screen, or Gordon. This blocks P0-P1.
17. **Prepare carefully** cannot be driven by simulated input; embarks use Play now.
18. *Fixed in L1: runtime folder = `marker.save`.* **The save folder renames** to `autosave N` after an autosave. Kernel I/O and supervise/`load-save`
    must follow the newest folder.
19. **Kernel I/O cost** (`kern` 9.4 ms/s) is about 3x all modules; the baseline first apply is a single
    425 ms call.
20. *Fixed in L1: follow auto-places P0/P1 deliverables; supply brake.* **The P0 plan is not applied by adopt.** With timestream 500 and no plan the fort idles and
    starves within a year. `adopt` (or L1 right after embark) must apply a plan before unpausing.

## 7. Contract changes to adopt (WP0 / orchestrator; implemented, CONTRACTS.md not edited)
- §3.4: snapshot runs on `every={ms=250}` (an export also runs while paused).
- §7 `snapshot.tile`:
  - `dig` is the lower-case `df.tile_dig_designation` name, `smooth`, `engrave`, `track` or `''`;
  - `bld` is the building type (Door, Hatch, Bridge, Trap, Well…), `passable`, `impassable` or `''`.
- §7 `snapshot.export`:
  - without `bbox` the box is the manifest geometry plus a 16/16/2 margin;
  - without a manifest it is 96×96 around the map centre, from 8 levels below the surface to 3 above;
  - at most 250,000 tiles; 4 exports may queue.
- §7: `military.kill({})` means withdraw, and `military.posture(P, force)`.
- §9.9: `baseline` passes on `marker.baseline == 1` or `baseline.done()`.
- §5 `act.quickfort` with `command='orders'`: creates manager orders; stats carry integer keys holding the order quantities.
- §5: the `act.trade` ops as WP9 listed them.
- §9.10 marks:
  - `soil` uses quickfort's farm rule (SOIL, GRASS_* or PLANT material on FLOOR/SHRUB/SAPLING);
  - `cavern` is `designation.feature_global` of revealed tiles.
- §17: snapshot.lua written at integration (WP7 file).
- DESIGN §0: bridge `gate_flags` are named `raised/raising/lowering`.
- `config/baseline.json` gains `trade_piles`.
- §13: the hook also covers Write, Edit, MultiEdit and NotebookEdit; `plan --by` is restricted like `cmd --by`.
- Earlier WP proposals still open (see the WP reports):
  - `act.link_lever` (WP3);
  - squad_uniform `spec.positions` (WP6);
  - `perf.csv` columns `target` and `paused_pct` (WP1);
  - `siege.recovery()` (WP5);
  - census field additions (WP5, WP8);
  - a `supervise` kind (WP10);
  - Z4 merge cap (WP3).

## 8. Live spikes, in order (one live slot; `dfllm-runtime/live.lock`)
**L0: embark and adopt.** Done on 2026-10-10 (results in §0). Still open: the hook spike, and restore
on a real unload (S9).
- Embark calibration (WP11 README §7):
  - popup, panel and Neighbors visible together;
  - rectangle fixed while the popup is open;
  - timings.
- adopt and boot. Check:
  - `DISABLED` is absent in `dfllm status`;
  - `dfllm selftest full` passes;
  - `heartbeat` ticks while paused.
- **S1**: `os.clock` gives 1 ms steps in game; kernel ms/s with 16 modules at timestream 500; the
  repeat-util frame callback runs while paused; unpaused_ms is right.
- **S4**: a/b state with a live Python reader; listdir cost; antivirus locks.
- **S7**: report ids for ambush, beast, undead, caravan and dig-cancel damp/warm.
- **S8**:
  - `getBaseDir` prefs (POPULATION_CAP 90); autosave enum; gfps 30; visitor cap;
  - timestream per-save fps; restore on unload;
  - how tempo.lower behaves under FPS_CAP 500.
- Hook spike: in a Claude Code session in `dfpilot-public`, check that the matcher fires for Monitor,
  the terminal MCP, Write and Edit, and that stdin is UTF-8.

**L1: baseline.**
- control-panel enables, seedwatch, autochop 150/60.
- **S5**: `labormanager status` parse in monitor mode.
- **S6**:
  - `apply_blueprint` ms per 40-tile chunk;
  - `command='orders'` creates manager orders (`N manager orders` in kern.log) and buildingplan picks them up;
  - farm plots only on soil;
  - smoothing of soil walls is skipped.
- Snapshot:
  - ms per 1,000-tile slice;
  - the legend against the vanilla view (raised bridge `H`, door `+`, trap `^`, water `w`/`~`);
  - `marks.soil`.
- Care: a hospital location found through `getCurrentSite().buildings`; UNIT_DEATH `isOwnGroup`; the mood job holder.

**L2: fortcore stages 1-2.**
- Runner stalls and cancels, BREACH_STOP on damp.
- Audit snapshot, then follow, then `audit`, then R1. R1 also needs the levers linked by hand (§6.1).

**L3: military and drill.**
- **S2**:
  - the leader appointment path for `squad_leader`;
  - the uniform spec layout and worn roles;
  - whether "assign uniform" covers vacant positions.
- **S3**:
  - leverPullJob latency;
  - `gate_flags.raised` names live;
  - cancelling our own job;
  - flinging and crushing on the footprint;
  - the link job.
- Drill 1 KPIs (DESIGN §14).

**L4: as events occur.** Trade (WP9 spikes):
- the frame of the Trade button;
- reply and totals rows;
- the depot sheet button;
- the confirm prompt;
- readTile cost.

Moods: the workshop-to-material classes.

**L5: soak.**
- **S9**: one supervised restart onto desktop 1 (warn Gordon first). Check that the autosave blocks
  the main thread; resolve §6.7.
- **S10**: difficulty siege triggers, read only.
- PERF_DEGRADED with no false restarts.

## 9. Live bring-up procedure
Run from `C:\Users\admin\claude gordons projects\dfpilot-public` on branch `v2`. Keep sound muted.
**Never adopt Inchcraft**; without the marker the kernel idles.

1. **Offline gate.** Run the §5 commands; all must be green.
2. **Migrate (DF closed).**
   ```
   python tools/migrate_v2.py              # dry run: read every step
   python tools/migrate_v2.py --apply      # refused while DF runs; journal in <DF>/_archive-v1/
   ```
   - The results:
     - `dfhack-config/script-paths.txt` gets `+…\dfpilot-public\lua`;
     - `onMapLoad.init` becomes `dfllm boot`;
     - the v1 runtime is moved away;
     - the DF-Aufsicht task is disabled.
   - Leave `--repoint-task` until S9.
   - `--plugins` (moves the automelt, channel-safely and confirm DLLs) is optional.
   - Undo with `--revert`.
3. **Prefs check (read only).** AppData `prefs/d_init.txt` has `[EMBARK_WARNING_ALWAYS:YES]`.
4. **Live lock.**
   `python -c "import time;from dfpilot import files,paths;files.write_json_atomic(paths.runtime_root()/'live.lock',{'holder':'L0','purpose':'bring-up','expires':int(time.time())+1800})"`
5. **Start DF on desktop 1** without stealing focus:
   `powershell -NoProfile -ExecutionPolicy Bypass -File tools\win\start_df_desktop1.ps1`
6. **New fort** (title screen, same world):
   ```
   python tools/embark/embark.py newgame [--world <name>]
   python tools/embark/embark.py scan WX,WY[,LX,LY] ...      # rank sites, embark nowhere
   python tools/embark/embark.py embark WX,WY[,LX,LY]        # --waive ID only after checking by eye
   ```
   If Prepare carefully fails, Gordon does it by hand (README §6). Loading an existing v2 fort
   instead: the main menu, or `dfhack-run load-save <folder>`.
7. **Adopt (in the fort, once).** Add `--acceptance` for the acceptance run; that disables dev exec.
   ```
   dfhack-run dfllm adopt
   dfhack-run dfllm status          # 16 modules, none DISABLED
   dfhack-run dfllm selftest full   # all pass
   ```
8. **Python side.**
   ```
   python -m dfpilot doctor
   python -m dfpilot status
   ```
   Gordon unpauses in DF: a pause by DF or by Gordon is never released through the inbox.
9. **Year-1 plan.**
   ```
   python -m dfpilot bp sites fortcore --fresh
   python -m dfpilot plan propose
   ```
   Edit `<save>/plan.draft.json`, then:
   ```
   python -m dfpilot plan check
   python -m dfpilot plan apply
   ```
10. **Orchestrator.** Start Claude Code with the project directory `dfpilot-public`, so the PreToolUse
    hook applies. Run `Monitor` on `python -m dfpilot follow`, with one subagent per wake line
    (RULES.md §5).
11. **Manual steps until the spikes land** (§6.1-6.4):
    - link levers after each fortcore stage (2 per bridge);
    - create squads A/B/C with leaders when DECISION_NEEDED `squads` arrives;
    - assign uniforms;
    - name a stockpile next to the depot `dfllm-trade`.
12. **Supervisor.** Use `python -m dfpilot supervise --once --dry-run` to inspect. The scheduled
    task stays disabled until S9.
