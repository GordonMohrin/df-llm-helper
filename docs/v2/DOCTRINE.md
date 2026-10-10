# DOCTRINE: a fast, strong, happy fortress under automated fair play (DF 53.16 / DFHack 53.16-r2)

Sources: [W] dwarffortresswiki.org (v50+ namespace, fetched today); [D] the installed DFHack docs in `hack/docs/docs` (authoritative for this build); [R] Gordon's runs 2-6 (understand.json). [?] marks points that are not verified and need a live test.

## 0. What the data shows (the frame for all the rules below)
- **Sieges are gated by population.** The difficulty setting "Enemy population triggers" is 20/50/80/110/140 on Normal. Production triggers (created wealth) are 5k/25k/100k/200k/300k, and trade triggers are 500/2.5k/10k/20k/30k exported [W Difficulty]. The wiki says sieges "begin once population reaches 80" [W Siege]. Run 6 is consistent with this: pop 46-54 with 675k wealth gave 0 sieges in about 56 game years, while pop 79-90 gave 5 sieges in 6.5 h [R]. Fortress rank needs population AND (production OR trade), so population is the binding gate [W; how the triggers combine for sieges is ?].
- **Siege size is capped by difficulty:** "Invasion creature cap (excluding mounts)" is 140. The Run 6 armies of 143 and 149 sit right at that cap plus leaders and mounts. Other defaults: "Siege frequency 25 %, otherwise raid"; "min raids before first siege 2"; "min raids between sieges 3" [W Difficulty]. Changing these is a vanilla Settings→Difficulty action, so it is fair. Changing them is still **Gordon's call**.
- **Forgotten beasts scale with wealth:** effective irritation = cavern irritation + wealth/40, with a minimum of 5,000 and sensitivity 10,000. Above about 200k wealth the beast risk starts; above about 600k it reaches the maximum of 33 % per layer per season. Beasts can arrive before a cavern is discovered [D agitation-rebalance]. Cavern irritation **persists in the world region across forts** [D]. Embark far from the 5 dead forts.
- **Time math:** 1 day = 1,200 ticks, 1 month = 33,600, 1 year = 403,200. At 450 ticks/s a month takes about 75 s and a year about 15 min real time. The LLM (10-70 s per turn) can never react tactically. In-game reflexes and geometry must do the defending; the LLM plans once per season or year.

## 1. Embark and the first 2 years

**Site criteria**, read from the vanilla embark screen and finder only. Never read hidden tiles or use prospect.
- Goblin Dark Fortress at least about 10 world tiles away (Runs 5 and 6 were 2.7-3 tiles away). Far from earlier fort sites.
- Evil: neutral or good, so no reanimation. Savagery low or medium.
- Trees, and a brook or river (well, hospital, fishing).
- Flux stone plus an iron ore layer if the finder shows it; otherwise plan to buy metal.
- Aquifer: **None** preferred. Light is acceptable with the protocol below. Heavy is a reject (Run 4 died to a 100 % soil aquifer).
- Shallow soil, needed for underground farms (or irrigate stone to mud).
- Temperate climate. Embark size 3x3 or 4x4: a smaller map means fewer trees, units and items.

**Embark loadout:** spend ALL points (Run 6 left 324 unused).
- 3 picks, 2 axes, 1 **anvil**, some iron or steel bars if offered, plenty of wood.
- Seeds: plump helmet plus surface crops. 1-2 breeding pairs (no extra cats).
- Skills: 2 miners, 1 mason/engraver, 1 carpenter/woodcutter, 1 brewer/grower, 1 mechanic, 1 cook/doctor.

**Light aquifer protocol:**
- Dig a 1-tile probe stair. If tiles are reported damp, stop and never re-designate them.
- Pass through with a sealed shaft only, or keep the fort above that layer.
- Every breach of water or caverns goes through a 2-wall airlock with a pathcheck before and after.

**Year 1** (game month → goal; real time at about 450 ticks/s):
1. **Granite (day 0-5):**
   - Native baseline (section 7) plus `pop-control set max-pop 55` / `wave-size 8`.
   - Deconstruct the wagon. Dig the entrance tunnel and **2 separate stairs**: a civilian core and a military/gate stair.
   - Temporary stockpiles inside. Carpenter + mason + still + kitchen workshops. Dormitory beds. Underground plump helmet plots plus surface crops.
   - Kitchen bans: `ban-cooking booze honey milk oil tallow`, plus `brew` for Gordon's plump-helmet rule.
2. **Slate:**
   - Dining hall with tables and chairs ("ate without table" is a stressor). Well or cistern. Trade depot.
   - Manager and bookkeeper offices. Craftsdwarf workshop (mugs, crafts) with idle-crafting enabled on it.
   - Refuse and corpse areas away from the living area (miasma).
3. **Felsite:**
   - Dig the trap hall (layout in section 2). Mechanic workshop, then mechanisms. Weapon traps as soon as components exist.
   - Inner drawbridge plus 2 levers inside. Barracks zone, archery range.
   - **Squad 1** of 4-6 non-miners in whatever metal is available, with shields.
4. **Hematite-Galena (summer):**
   - Smelter, forge, charcoal. Exploratory tunnels for ore (`digexp`/pattern digs are fair; `digv` follows hidden veins and is not).
   - **Every moodable workshop type:** carpenter, mason, craftsdwarf, jeweler, metalsmith, bowyer, clothier, leatherworks, tanner, loom, glass, mechanic.
   - Stock mood materials: cloth, leather, bone, shell, gems, bars.
   - Hospital: beds, traction bench, chests with cloth/thread/splints/soap, a real water source.
   - After the first migrant wave: `orders import library/basic` and `library/rockstock`.
5. **Limestone-Timber (autumn):**
   - Dwarven caravan: trade crafts for bars, anvil, cloth, seeds, breeding animals. Use the liaison to request metal.
   - Individual bedrooms for everyone. Coffins plus 1x1 tomb zones. Tavern with mugs, a general temple, a minimal library.
6. **Moonstone-Obsidian (winter):**
   - Trap hall at its full count. Surface walls with overhangs. Archer gallery.
   - **Squad 2.** `library/smelting` + `library/military` once there is fuel.
   - First **siege drill** (section 2).

**Year 2:**
- Steel or iron full kits for 10-12 melee soldiers. Crossbow squad of 4-5 with at least 300 combat bolts.
- Deep refuge level with its own well, food and beds.
- Dining hall to Grand (2,500), later Royal (10,000). Temple to 2,000 (petition level). Bedrooms Decent or better (≥500).
- Keep pop ≤55. Raising the cap to 75-79 (still below the 80 trigger) or to ≥80 happens only after a passed drill.
- Caverns stay sealed. Magma only if it is reachable without breaching a cavern.

## 2. Defense that works for automated play

**Policy choice (the biggest lever):**
- **Option A (recommended):** stay at pop ≤75-79, below trigger 80. You face only raids, ambushes, thieves and beasts.
- **Option B:** go to ≥80 only with ≥20 % soldiers in worn steel or iron, a passed drill, and possibly a lower Invasion creature cap (Gordon's call).

**Sealed-fort principle:**
- Only **raised drawbridges and constructed or natural walls** count as barriers. A raised bridge is "invulnerable to building destroyers", and climbing over a raised bridge or a protruding floor is impossible [W Drawbridge, Climbing].
- Doors and forbidden doors stopped nothing in Run 6.
- Invaders climb walls [W]. Smoothed natural walls cannot be climbed. A floor overhang (2 tiles is safe) blocks climbing. Fortifications and overhanging walls can be climbed from 1 z below [W Climbing]. So: smooth the outer natural walls, give constructed perimeters a 1-2 tile overhang, and roof the courtyard.
- Besiegers retreat "after being sufficiently successful … killing sufficient attackers, waiting them out, or some combination" [W Siege]. A goblin siege that cannot path in eventually leaves [? the duration is not documented; expect weeks to a season]. Necromancer sieges can take "a year or more" [W].
- The fort must therefore be self-sufficient while sealed: underground farms, a well or cistern, stockpiles, workshops, hospital and tombs, all behind the inner gate.

**Geometry** (fixes Runs 2, 5 and 6):
- Surface → **trap hall**: 1 wide, ≥40 tiles, with bends. Weapon traps with up to 10 components each (serrated discs, axe blades, spiked balls). Use stone-fall traps as filler.
- → **outer killing field** under fortified archer galleries. The galleries are on a higher z, roofed, and have no path from outside.
- → **inner drawbridge**, raised by default during danger → barracks → **civilian stair separate** from the military stair. The refuge is deep, off every attack path, and sealable with a second bridge.
- The depot sits in the outer bailey, so trade does not require opening the inner gate.
- **No shortcut bridges.** Every defense metric is computed for the real current state of every bridge and door, never the best case.

**Cage traps:**
- "If a cage trap captures an invader, his fellow attackers will attempt to free him from the cage" [W Siege]. Run 6 lost 8 prisoners in about 80 s.
- So: no cage traps on the main path, only at side entrances or for wildlife.
- Every capture gets a deadline task: haul the cage deep inside (animal stockpile that accepts cages; prioritize Animals hauling), then assign it to a **pit zone**: a deep drop or spike pit, a vanilla UI action.
- Cages must be empty. Run 5 had cages full of seeds and logged 46,000 "Needs empty cage" messages.

**Siege reflex** (in-game, same tick, owned by ONE actor, triggered by eventful `onInvasion` plus filtered `onReport`; only invaders that have been revealed count, never `hidden_in_ambush` units):
1. Mode becomes SIEGE. Timestream returns to normal speed with no slow motion, and is locked until RECOVERY.
2. Civ alert on: `plotinfo.alerts.civ_alert_idx=1`, as `gui/civ-alert` does.
3. All squads go to their pre-configured Ready routine. They already wear uniforms, so pickup time is 0.
4. Squads get a station order in the killing field and galleries. **No kill orders into shafts or stair feet.**
5. When all citizens are inside the burrow, or after at most about 600 ticks, `lever pull --id N --priority`. `--instant` is armok and not allowed. Use 2 levers and check that nobody is on the bridge (raising flings units [W]).
6. Freeze wealth and beauty projects. Send the LLM one summary.

**Civilian alert burrow:**
- The burrow = **the whole sealed interior**: farms, workshops, stockpiles, tombs. Name it with a trailing `+` and `enable burrow` so it auto-expands when adjacent walls are dug [D].
- Then the alert costs no production. Run 6's alert froze trap reloading, building and farming because the burrow was small.
- The alert ends only when 0 visible hostiles have a path in (z-aware), checked with hysteresis.

**Military:**
- Standing army of 15-25 % of adults, squads of up to 10. Keep 2 melee squads and 1 crossbow squad.
- Soldiers have **mining, woodcutting and hunting disabled**: those tool "uniforms" conflict with all military gear [W].
- Routines [W Scheduling]: Off duty = "civilian equipment". Ready = "no orders, wear military equipment the entire year". Constant training = train all year.
  - Core squads: Constant training, or Ready plus training months. **Never Off duty.**
  - "Minimum soldiers per order" defaults to 10. Set it to about half the squad so soldiers can attend to needs.
  - "At least half as many training orders as members, ≥2 soldiers per order" encourages sparring [W].
- Uniform setting "Replace clothing" plus full metal armor. Civilian caps, gloves and shoes conflict with military gear [W]. Run `uniform-unstick --all --drop --free` monthly.
- **KPI = worn %**, measured with a 60 s drill, plus combat value (weapon, shield, armor and dodge skill sums). Never count "assigned" gear (Run 6: 86 % assigned, 0 % worn).
- Reserve squads of civilians are fodder. They are unarmored, they steal labor, and unarmed sparring killed 8 civilians in Run 5.
  - Use `autotraining` only for the martial-training need, in its own squad with weapons and armor.
  - Never draft these squads in a siege.
- **Equipment pipeline:**
  - Year 1: bronze (copper + tin), bought metal, leather armor as filler, wooden or bone training bolts.
  - Year 2: iron, then steel (iron + flux + fuel, via pig iron).
  - `library/military` picks the best available metal. Melt goblin gear with a `logistics add melt` pile. The masterwork-upgrade loop costs a lot of fuel.
  - Barracks needs weapon racks, armor stands and chests assigned.
- **Siege drill**, the acceptance test that unlocks pop growth: routine Ready for everyone, then after 60 s require:
  - worn ≥90 %;
  - bridge raised within ≤600 ticks;
  - refuge reachable only from inside;
  - civilian path not equal to the attacker path;
  - nobody outside.

**Undead and necromancers:**
- They come from "every side". Corpses within line of sight (about 15 tiles) get raised [W Necromancer].
- Bury, slab or haul all corpses away from the approach after every fight. The atom smasher (raised bridge) or magma prevents raising [W].
- Kill the necromancer first (marksdwarves). Blunt weapons are the safer bet [W: "jury is still out"].
- Stay sealed. Undead do not tire; plan for a year-long siege.
- Werebeast attack period is 10 seasons; megabeasts 10. Forgotten beasts often have TRAPAVOID and building-destroyer traits [R Run 3]: only walls and raised bridges stop them.

## 3. Labor efficiency (v50 work details)
- The v50 job auction already prefers skilled dwarves. The real failures are starved unskilled jobs (hauling, levers, care) and specialists hauling.
- `labormanager` is NEW in 53.16-r2 [D NEWS]. It is the modern autolabor mode and works through work details:
  - an `auto:Laborers` pool;
  - demand-weighted specialists;
  - builtin Miners, Woodcutters and Hunters details for tool labors;
  - needs-aware assignment and strange-mood steering;
  - a guild idle-reserve of 30 %;
  - it leaves soldiers on duty and burrow-assigned dwarves alone.
- **Legacy `autolabor` disables work details. Never run it** [D].
- Rollout:
  1. `labormanager mode monitor`: a "task starvation" warning when a posting waits more than 1,200 ticks; no management.
  2. Then `labormanager enable`, `balance balanced` (`staffing` early), `labor MINE unmanaged` if digging stays controlled.
  3. **Retire all 18 repo-B labor writers first.** Untested here [?]: A/B test it on the new fort.
- KPI: **starving postings = 0** and projects completed per season, not raw idle %. Idle time is where dwarves socialize, pray, read and drink, so it feeds happiness. Gordon's "idle >40 % → act" rule needs his re-decision. Proposed version: act only if idle >40 % for 3+ game days AND the backlog has useful jobs.
- Useful filler, never filler digging:
  - boulders → blocks via orders;
  - walls and overhangs;
  - smoothing and engraving of *used* rooms;
  - capped trade crafts;
  - hauling into bins (`combine`).
- `work-now` cuts post-job wandering. It is tagged gameplay [D], so Gordon's call. `idle-crafting` covers the craft need (`happy no`, thresholds 500/1000/10000) [D].

## 4. Happiness and needs that matter in 53.x
- **Top stressors** in Gordon's data: seeing corpses (SawDeadBody was the number one thought), deaths of friends, nakedness or tattered clothing (31 of 51 naked in Run 6), thirst and hunger, failed moods, ghosts, combat, eating without a table, sleeping without a bed, miasma, rain.
- **Rooms:** the value tiers are identical for bedroom, dining hall, office and tomb: 0 / 100 / 250 / 500 / 1,000 / 1,500 / 2,500 / 10,000 (Meager … Royal) [W Activity zone]. "More impressive zones" relieve more stress [W].
  - Priority order: dining hall (everyone eats there daily) → own bedrooms → temple → tavern → library.
- **Temple:** a temple with no specific deity satisfies worshippers of local gods; foreign gods need their own temple. Shrine <2,000, Temple ≥2,000, Temple Complex ≥10,000. A sect of 10 petitions for a 2,000-value temple [W Temple].
- **Tavern:** needs a tavern keeper, drinks and mugs (`library/basic` makes mugs). **Library:** bookcase, tables and chairs. **Guildhalls:** on petition.
- **Food and drink:** keep stock in days, not item counts: drink ≥170 days, food ≥60 days [R]. Have ≥5 kinds of meals and booze. `seedwatch` only on farmed crops at 10-15 (`seedwatch all` caused the Run 2 lockout).
- **Clothing:** `tailor` with `materials silk cloth yarn` keeps leather for armor. The `confiscate` default removes ownership, which collides with fair-play rule FP13 → Gordon decides [D].
- **Dead:**
  - one 1x1 tomb zone per coffin, with free tombs ≥ open corpses + 6;
  - `burial`, `preserve-tombs`, `autoslab` (ghosts got 0 memorials only when slabs were forbidden [R]);
  - `prioritize` defaults (rot-prone hauling, medical, DumpItem, PullLever).
- **Moods:** every workshop type plus a material stock. No script may ever cancel mood jobs (Run 5 lost 9 of 9 moods that way).
- **Martial need:** autotraining squads with gear. **Rooms for nobles:** `preserve-rooms` (track-roles).

## 5. Beautiful buildings cheaply
- **Value formula [W]:** room value = walls + floors + furniture.
  - Engraved floor ≈ 10 × material value × quality multiplier.
  - A smoothed natural floor is 4 × material value; a raw floor is 1 ×.
  - Constructed tiles beat natural ones; walls are worth a little more than floors.
- **Best return on effort:**
  1. Put mood **artifacts** and masterworks in the dining hall or temple; one artifact makes a room Royal.
  2. Pedestals or displays with valuable items [W Temple].
  3. A skilled engraver on the dining hall, temple and nobles' rooms only.
  4. Furniture from valuable stone or metal via `rockstock`.
  5. Smooth outer walls: it costs little and makes them unclimbable.
- **Do not engrave** corridors, stockpiles or workshops. Run 6 had 296k of its 675k wealth in architecture, which feeds forgotten-beast risk via wealth/40 and possibly siege size [?].
- Beauty projects run only in mode PEACE, after a green drill, through one generic project runner using quickfort blueprints. Never during siege seasons.

## 6. Speed
- **FPS:** unit turns take over 60 % of CPU in big forts; pathfinding under 10 %. Units more than 26 tiles apart skip line-of-sight checks [W]. Temperature off gives roughly +100 % [W]; `TEMPERATURE:NO` is already set.
- **Population and visitors:** pop 50-80 plus `VISITOR_CAP` 300 → 20-30. `BABY_CHILD_CAP` 266:1000 → about 10:10 [? semantics]. `STRICT_POPULATION_CAP` 100 → cap+5.
- **Animals:** `autobutcher` with low targets (few cats). **Items:** melt or trade goblin gear, use bins, avoid boulder spam.
- **Caverns:** keep sealed. `agitation-rebalance` caps cavern invaders, but it is a gameplay mod (Gordon's call) and its monitor overlay cost 2.2 % CPU.
- **Fluids:** avoid open flows and evaporation.
- **init.txt:** `FPS_CAP` 250, `G_FPS_CAP` 250 → 30 (Run 3 measured +15-35 %). `MULTITHREADING:YES` is already set.
- **Overlays:** disable the overlays nobody sees (headless play). They measured 7-14 % of real time.
- **d_init:** `WEATHER:NO` is a fair vanilla option that also removes rain thoughts (Gordon's call). `AUTOSAVE:SEASONAL` → **YEARLY** (about 15 min real time at speed). **Drop the Lua quicksaves**: Run 6 averaged a 31 s freeze across 109 saves.
- **timestream** [D]:
  - It skips at most 9 ticks per frame, so calendar speed ≤ real fps × 10.
  - Run 3: target 500 → 458 ticks/s, 700 → 661, 1000 → 828. Run 6 ran a target of 200.
  - Not adjusted: liquids and world-map armies.
  - Peace: 500-700. Siege: off or 100 (combat fidelity). Never slow motion at 8 ticks/s.
- **Restarts:** restart DF when save freezes exceed 20 s or ticks/s drops below 60 % of baseline (Run 6 degraded from 236 to about 90 ticks/s).

## 7. DFHack facts for the controller
- **control-panel:** `control-panel enable|disable <cmd>` acts now and is saved per fort. `control-panel autostart <cmd>` applies on new forts. Repeats for fix/*, orders sort/recheck, combine, automilk [D]. The current `control-panel.json` is empty.
- **Native baseline:**
  - automation: suspendmanager, buildingplan, `prioritize -a defaults`, autochop, autobutcher (+autowatch), autonestbox, nestboxes, autoslab, burial;
  - rooms and dead: preserve-rooms, preserve-tombs;
  - stockpiles and orders: logistics, stockflow, tailor, idle-crafting, the orders library;
  - population and fixes: pop-control, the fix/* defaults;
  - training: autotraining;
  - labor: labormanager in monitor mode.
- **Delete** the stale automelt, channel-safely and confirm DLLs; they fail to load at every start [R]. Melting is now `logistics add melt`.
- **orders:** `orders import library/basic|furnace|smelting|military|rockstock|glassstock`. Import `basic` after the first migrants; it includes cooking, so check it against the plump-helmet ban. Also `orders sort` and `orders recheck`. `workorder` takes JSON with item_conditions [D].
- **quickfort** modes: #dig, #zone, #place, #build, #burrow, #notes, #meta. There is no #query/#config in v50+.
  - `quickfort orders <bp>` queues the materials a blueprint needs. Use `--dry-run`.
  - The API `apply_blueprint` took 3-17 ms vs about 670 ms for the CLI [R].
  - `#build` plans unbuilt buildings through buildingplan, and suspendmanager unblocks them. Run 6 had 97 of 167 furniture jobs stuck while it was off.
- **eventful** (`require 'plugins.eventful'`):
  - Events: `enableEvent(eventType.X, freq)` with TICK, JOB_INITIATED, JOB_STARTED, JOB_COMPLETED (needs freq 0 for accuracy), UNIT_NEW_ACTIVE, UNIT_DEATH, ITEM_CREATED, BUILDING, CONSTRUCTION, SYNDROME, INVASION, INVENTORY_CHANGE, REPORT ("happens more often than you think"), UNIT_ATTACK, UNLOAD, INTERACTION.
  - The smallest frequency across all registrants wins. Register on map load, because there are no events right after loading [D].
  - Keep callbacks O(1); filter REPORT by type.
- **Timers:** `dfhack.timeout(n,'ticks'|'days'|'months',cb)` does not fire while the game is paused; `'frames'` does [D].
- **Squads:**
  - API: `dfhack.military.makeSquad/addToSquad(unit,squad,-1)/removeFromSquad/getSquadName` [D].
  - `sq.cur_routine_idx` is the UI routine dropdown (0 Off duty, 1 Staggered, 2 Constant, 3 Ready by default [? order]).
  - `sq.schedule.routine[r].month[m].{orders,uniform_mode,sleep_mode}`. A schedule write crashed DF once [R], and which `uniform_mode` value means "uniform" is ?. Configure routines once and verify; afterwards only switch `cur_routine_idx`.
- **Civ alert:** `df.global.plotinfo.alerts.civ_alert_idx` (0 off, 1 on). `alerts.list[*].burrows` lists the safe burrows. You can call `reqscript('gui/civ-alert').sound_alarm()/clear_alarm()` [script source].
- **Levers:** `lever list`, `lever pull --id N --priority` (a job, fair). `--instant` is the hand of Armok [D].
- **Population caps live in `df.global.d_init.dwarf.population_cap`**, a global value. pop-control rewrites it monthly to min(max-pop, citizens + wave-size). d_init.txt (currently 75) applies to any fort without pop-control [script source].
- **Remote RPC** [D Remote, DFHack source]:
  - Handshake `DFHack?\n` + int32 1. Header: int16 id, int16 pad, int32 size. BindMethod = 0, RunCommand = 1.
  - RunCommand is `SF_DONT_SUSPEND` at the RPC layer, but `Core::runCommand` takes the core lock for normal commands and scripts. **RunLua** is registered without that flag, so it **suspends** the core, and only modules named `rpc.*`, `*.rpc` or `*-rpc` may be called [R, from a dfhack.dll string].
  - **So a persistent socket removes the ~120 ms process spawn but not the main-thread stop:** every call freezes the game for its runtime.
  - Design: an in-game kernel (budget ≤2 ms/frame) writes state.json and events.jsonl; Python only reads files; at most one batched RPC per decision. Never hold `CoreSuspend` across calls.
  - luasocket must be non-blocking with `select(0)`; its sockets are not garbage-collected [R].
- **Fair play:** generate the blocklist from `helpdb.get_tag_data('armok')`. Also block `digv`/`digvx`/`digtype --hidden`, `fastdwarf`, `caravan extend|happy`, `lever --instant`, `autodump`, `locate-ore`, `prospect`, `showmood`. `timestream` (gameplay tag) is accepted. Gordon still decides on `work-now`, `agitation-rebalance`, `deteriorate`, `emigration`, tailor/cleanowned confiscation, and difficulty changes.

## Top 25 rules
1. Pop cap via `pop-control` from day 1: max-pop 55, wave-size 8, re-checked on every load. The pop-80 siege trigger is crossed only on purpose.
2. Raise the cap above 55 only after a passed siege drill. Go to ≥80 only with ≥20 % soldiers in worn metal (Gordon decides on Option A, staying at ≤79).
3. Only raised drawbridges and walls are barriers. Doors are not. No shortcut bridges. Metrics use the real bridge state.
4. Two stairs: military/gate and civilian. The refuge is deep, off the attack path, and self-sufficient.
5. Smooth outer natural walls and give constructed perimeters an overhang (climbers). Roof the courtyard.
6. Trap hall: 1 wide, ≥40 tiles, bends, multi-component weapon traps. No cage traps on the main path.
7. Every capture gets a deadline: haul inside, then pit zone. Comrades free caged invaders [W].
8. The siege reflex runs in-game on `onInvasion`, in the same tick: alert, Ready, station, priority lever pull. The LLM only gets a summary.
9. The alert burrow is the entire sealed interior, so the alert never freezes the economy. It auto-expands with `+`.
10. Standing army of 15-25 % on Constant training or Ready. Never Off duty. Soldiers have no mining, woodcutting or hunting labors.
11. Uniforms: Replace clothing, full metal armor plus shield. KPI = worn % after a 60 s drill, never "assigned".
12. No kill orders into shafts or stairs. Soldiers hold the geometry; crossbows fire from roofed galleries.
13. Undead: clear corpses within about 15 tiles of the approach, target the necromancer, stay sealed for up to a year.
14. Never breach caverns or aquifers without a 2-wall lock plus pathcheck. Keep wealth away from useless tiles (forgotten beasts scale with wealth/40).
15. Native DFHack first: control-panel baseline, orders library, suspendmanager, buildingplan, prioritize defaults. Lua only fills gaps.
16. Labor: `labormanager` monitor mode, then modern mode, with every other labor writer retired. KPI = 0 starving postings, not raw idle %.
17. Idle time is needed for needs. Filler work comes from a ranked useful backlog, never filler digging.
18. Every moodable workshop type plus a mood-material stock by the end of year 1. Never cancel mood jobs.
19. Food and drink tracked in days (drink ≥170, food ≥60). Use ban-cooking/seedwatch only on actual crops. The hospital has its own water source.
20. Corpses are handled the same day: 1x1 tombs ≥ corpses + 6, autoslab, burial, preserve-tombs.
21. Beauty goes to the dining hall (Grand, then Royal), bedrooms (≥500) and the temple (≥2,000). Artifacts and pedestals first. Only in PEACE.
22. Speed: TEMPERATURE off, G_FPS_CAP 30, overlays off when headless, low visitor cap, autobutcher, timestream 500-700 in peace and normal speed in siege.
23. Saves: DF AUTOSAVE:YEARLY, no Lua quicksaves. Restart DF when save freezes exceed 20 s or ticks/s falls below 60 %.
24. Control plane: an in-game kernel that writes files and costs ≤2 ms/frame, plus one owner per actuator. Every RPC call freezes the game for its runtime, so batch it or avoid it.
25. Fair play at the boundary: armok-tag blocklist, plus digv, `lever --instant`, fastdwarf and hidden-tile reads. Gordon decides each gameplay-tag tool and difficulty change once, and the answer is recorded permanently.

Sources: https://dwarffortresswiki.org/index.php/Siege · /Difficulty · /Drawbridge · /Climbing · /Scheduling · /Uniform · /Necromancer · /Activity_zone · /Temple · /Maximizing_framerate · https://raw.githubusercontent.com/DFHack/dfhack/develop/library/RemoteTools.cpp · local docs `E:\Program Files (x86)\Steam\steamapps\common\Dwarf Fortress\hack\docs\docs\tools\{labormanager,autolabor,timestream,pop-control,autotraining,idle-crafting,lever,agitation-rebalance,work-now,uniform-unstick,prioritize,preserve-rooms,preserve-tombs,logistics,tailor,control-panel,orders,quickfort}.txt`, `dev\Lua API.txt`, `dev\Remote.txt`, `NEWS.txt`; scripts `hack\scripts\pop-control.lua`, `hack\scripts\gui\civ-alert.lua`, `hack\lua\plugins\eventful.lua`; `prefs\d_init.txt`, `prefs\init.txt`; C:\Users\admin\AppData\Local\Temp\claude\C--Users-admin-claude-gordons-projects\2a46845f-7ea2-4b7a-9f30-43d41c1737e6\scratchpad\critic.md and understand.json.