# df-llm-helper v2: final design

Date 2026-10-10. This design starts from the **native** proposal, which had the highest average judge score (6.8; kernel 6.7, doctrine 6.3). It grafts in kernel's scheduling and instrumentation and doctrine's fort geometry, BREACH protocol, write allowlist and mock-K tests, and it removes every fatal flaw the judges found (§16).

Markers: **[V]** means verified today against the installed DFHack 53.16-r2 sources or docs. **[S#]** means a spike must confirm it first (§13).

## 0. Facts this design relies on [V]
- **Levers.** `hack/scripts/lever.lua`: `leverPullJob(lever, do_now)` creates a PullLever job and **never deduplicates**. `leverPullInstant` is the armok path. For a bridge, `gate_flags.closed` means raised, and `closing`/`opening` mean it is moving. The kernel calls `reqscript('lever').leverPullJob` only through `act`.
- **pop-control** saves its state per site (`saveSiteData`) but monthly writes the **global** `d_init.dwarf.population_cap` = min(max_pop, citizens + wave) and never restores it on unload, so it leaks into other saves; v2 restores it (§10).
- **Civ alert.** `gui/civ-alert`: `sound_alarm()` sets `plotinfo.alerts.civ_alert_idx=1`, but only if the alert has burrows. `add_civalert_burrow` and `remove_civalert_burrow` change the burrow list.
- **quickfort.** `apply_blueprint{mode, data[z][y][x]=text, pos, command='run'|'orders'|'undo'}` is the in-memory API (`internal/quickfort/api.lua`). Zones accept `location=tavern|temple|library|hospital|guildhall`, and there is a burrow mode.
- **eventful** has INVASION, REPORT, UNIT_DEATH and more; `onJobCompleted` receives a *copy* of the job; the smallest registered frequency wins; no events fire right after a load, so v2 registers on SC_MAP_LOADED.
- **Lua API used:** `persistent.get/saveSiteData`; `getTickCount` (ms only); `filesystem.listdir/mtime/mkdir_recursive`; `run_command_silent` (returns output); units `isVisible` (ignores sneaking) + `isHidden` (accounts for it), `isInvader/isDanger/isGreatDanger/isMegabeast/isForgottenBeast/isTitan/isUndead`, `getStressCategory` 0 (worst) to 6; `military.makeSquad(assignment_id)` needs a position assignment and `addToSquad` fails while the leader slot is vacant; `kitchen.addExclusion({Cook=true},…)`; `maps.canWalkBetween` uses a walk-group cache that updates only while unpaused and ignores burrows and units; `internal.getPerfCounters()` (`lua/script-manager.lua:293`).
- **repeat-util** reschedules through `dfhack.timeout` without a pcall, so a throwing callback silently stops repeating.
- **labormanager** (r2 docs): modes modern, monitor, legacy; monitor warns when a posting waits >1,200 ticks; it leaves on-duty soldiers and burrow-assigned dwarves alone and tracks the builtin Miners/Woodcutters/Hunters memberships it adds.
- **timestream:** `timestream set fps N`; −1 means no adjustment. It skips at most 9 ticks per frame, and liquids and armies are not adjusted. It is tagged *gameplay*.
- **Other tools:** the `burrow` plugin auto-expands burrows whose names end in "+". `load-save <folder>` exists. `fix/` contains armok-ish scripts such as `retrieve-units`, so `fix/*` is never allowlisted wholesale.
- **Runtime settings fields exist:** `d_init.feature.autosave` (enum `df.d_init_autosave`), `d_init.dwarf.visitor_cap`, `strict_population_cap`, `enabler.fps/gfps`. Changing them is a vanilla Settings action.
- **Prefs today:** d_init AUTOSAVE:SEASONAL, POPULATION_CAP 75, STRICT 100, BABY 266:1000, VISITOR 300, TEMPERATURE:NO, WEATHER:YES; init FPS_CAP 250, G_FPS_CAP 250; announcements.txt has one P flag and **no siege type** (it has AMBUSH_*, MEGABEAST/WEREBEAST_ARRIVAL, BEAST_AMBUSH, UNDEAD_ATTACK, NIGHT_ATTACK_STARTS, CARAVAN_ARRIVAL).
- **Tested today:** `hack/lua53.dll` loads from Python via ctypes (C++-mangled exports), so pure-Lua logic **can be unit-tested outside DF**; Windows Lua `os.rename` onto an existing file fails ("File exists"), so atomic replace needs a/b slots.

## 1. Principles
1. **The fort defends itself.** Every reaction needed within 1 game day (1,200 ticks) runs in-game in the step that detects it. The LLM is a yearly planner and handles exceptions.
2. **Native first.** Plugins, the orders library, quickfort, labormanager, pop-control and vanilla settings run the economy. Our Lua only adds reflex, readiness, the project runner, care gaps, trade and export.
3. **One writer per actuator, level-triggered.** Each step recomputes the desired value from the mode and writes it idempotently. There is exactly one external hold, pause with a TTL. No leases, nothing is restored after a lease, no flag files.
4. **Growth is earned.** Pop cap, beauty and wealth projects rise only after a measured drill and a worst-case audit (gear worn, not assigned; all bridges lowered; doors open).
5. **Files, not calls.** The kernel writes files and Python only reads them. Steady state has 0 dfhack-run spawns and 0 RPC calls (both suspend the core).
6. **Opt-in per save.** Without the `dfllm` site marker the kernel does nothing. Gordon's Inchcraft and his global prefs stay untouched. Every runtime setting we change is restored on unload.
7. **Fair play by construction.** All writes go through `act.lua` (an allowlist of UI-equivalent actions). All unit and tile reads go through `sense.lua`/`snapshot.lua` (visible only). The inbox has a closed verb set.
8. **Heavy analysis off the main thread.** Path audits and site ranking run in Python on exported snapshots of revealed tiles. In-game work is O(units) per scan.
9. **Speed is a KPI.** ticks/s, kernel ms per second and frame gaps go into every state file. A regression fails acceptance.
10. **Fort-agnostic.** No coordinates or IDs in code. The manifest lives in the save and is written by the templates.

## 2. Dropped from v1
| Dropped | Evidence | Replaced by |
|---|---|---|
| waechter 2 s poller (about 4,300 spawns/h), dfhack-run per query, persistent RPC | blinded by 3-85 s stalls; RPC still suspends the core | kernel file export |
| 39 repeat jobs + aufsicht, 4 time bases | about 30 items.all scans/min, 883 ms spikes | one dispatcher + shared census |
| 6 pausers/5 unpausers, pause.hold, supervisor `advance run`, 3 deadman systems | forced play mid-siege in B8-B10 | arbiter + one liveness rule |
| Tempo governor with slow motion (8 ticks/s) | 74 toggles; tempo back on 10 s after siege arrival | mode table |
| Off-duty reserves, training calendar, "assigned gear" KPI, kill orders into shafts | 0 % worn in B10; elite lost in shafts | Constant-training squads, worn %, kill-box-only orders |
| Shortcut bridge, cage traps on the main path, doors as barriers | 8 prisoners freed in 80 s; 5-tile bypass | fortcore geometry + worst-case audit |
| 8 building watchers, 15 generators, 1,759 CSVs, an Opus agent per building | about 42 M tokens and 131 turns per building | templates + one runner |
| 18 Lua economy/labor writers (orders, essen, trinken, tuch, schmelz, knochen, arbeit, workdetail …) | 988 bin orders created and deleted | orders library, labormanager, natives |
| Idle-driven filler digging | boulders, wealth | ranked useful backlog (D-03) |
| Lua quicksaves (109, mean 31 s freeze) | session degraded from 236 to 90 ticks/s | DF yearly autosave + external copy |
| Regex on report text, 6,180 events without owners | the word "goblin" made a figurine CRITICAL | typed report ids + 3 event classes |
| Exception register with cheat consents | legitimised fastdwarf and caravan extend | decisions.yaml (Gordon's answers only) |
| Python aux (agents, bus, journal, dashboard, forecast, runbooks, kb …), 68-KPI ZIELE, ERFAHRUNGEN as working memory | no live use in Run 6; 854 KB | about 3k lines of Python; RULES.md ≤300 lines |

## 3. Architecture
```
DF 53.16 + DFHack (virtual desktop 1, muted, never focused)
├─ natives (baseline, §5.5): suspendmanager buildingplan autochop autobutcher autonestbox nestboxes autoslab burial
│  preserve-rooms/-tombs tailor logistics seedwatch idle-crafting pop-control labormanager[monitor] burrow timestream
│  prioritize, orders library, fix/{stuck-merchants,dead-units,empty-wheelbarrows}
└─ lua/dfllm: ONE repeat-util 'frames' callback (dispatcher) + eventful INVASION/REPORT/UNIT_DEATH (enqueue only)
   SENSE   sense (census, visibility filter) · snapshot (revealed tiles, sliced)
   DECIDE  siege FSM (mode) · threat · readiness · runner · economy · care · military · trade
   ACT     act.lua = the only writer: tempo pause civ-alert squads levers popcap quickfort orders zones forbid/dump settings
   IO      <DF>/dfllm-runtime/<save>/ state.a|b.json · events.jsonl · heartbeat · inbox/ → outbox/ · snap/ · perf.csv
   PERSIST dfhack.persistent site data 'dfllm' = marker + manifest + projects + drill + mode   (in the save)
          ▲ files only (0 DF calls)                                 ▲ dfllm cmd → inbox (closed verbs)
Python df_llm_helper (stdlib): follow/wake · status/brief · plan · bp (templates, topo audit, sites) · doctor · lint/hook
Windows task DF-Aufsicht → `dfllm supervise --once` (liveness, backup, restart; never pauses/unpauses)
Claude Code orchestrator (≤60k ctx, Monitor on `dfllm follow`) → fresh Sonnet subagent per wake/year review
```
**Data flows.** The kernel writes state and events, Python tails them, and the follower prints a wake line that the orchestrator turns into a subagent. The subagent writes plan.json, and `dfllm plan apply` puts it in the inbox for the kernel. For a path audit, the kernel exports a snapshot (SNAPSHOT_READY), the follower runs `bp.topo.audit` automatically with no LLM involved, and the result comes back through the inbox `audit` verb into readiness.

**Actuator ownership** (sole writer is the module; `act.lua` is the only code that assigns to `df.*`):

| Actuator | Sole writer | Desired value from | External input |
|---|---|---|---|
| pause | arbiter | Never pauses. Unpauses only pauses caused by a whitelisted popup, which it dismisses. | inbox `pause` (TTL ≤600 s)/`unpause`. A pause by Gordon is honoured; a D event after 10 min. |
| timestream fps, `enabler.gfps` | arbiter | mode table | inbox `tempo` (lower only, TTL) |
| civ alert + alert burrow list | siege | mode (Kern+ or Tiefe+) | — |
| squad routine/orders/stations | military | posture set by siege/drill | `squad.sortie` only with approval |
| levers/bridges | gate | f(mode, drill, trade window), single pending job | `lever` verb (PEACE only) |
| pop cap | readiness → `pop-control set max-pop` | readiness level ∧ plan ceiling | inbox can only lower it |
| designations, buildings, zones, burrows, locations | runner (care asks the runner for tomb zones) | project queue | plan.json |
| manager orders | economy (library imports, `quickfort orders`, `dfllm:`-tagged supply orders) | phase + stock days | plan.orders |
| work details/labors | **labormanager only** | — | military only *reads* membership to filter recruits |
| kitchen, seedwatch, stockpile settings | economy | baseline | — |
| forbid/dump/melt flags on items | care (corpses, captives, mood materials) | care rules | — |
| runtime settings (autosave, visitor cap, gfps, overlays) | arbiter at boot; restored on unload | profile + decisions | — |

**Mode table** (owned by the siege FSM, applied by the arbiter). "Visible" means `isVisible ∧ ¬isHidden ∧ not caged`.

| Mode | Entered when | timestream | civ alert | squads | Bridges O1 / B1 / B2 | Projects | Growth |
|---|---|---|---|---|---|---|---|
| PEACE | default; RECOVERY + 8,400 quiet ticks | fps 500 (700 after A2 if stable) | off | Constant training | down / down / down | all, per readiness | per gate |
| ALERT | 1-5 visible hostiles, no great danger | 250 | on if a hostile is ≤30 tiles from a citizen outside Kern+ | squad A stationed inside B1 | O1 up if a hostile is ≤30 tiles from O1 | defense + infrastructure | frozen |
| SIEGE | ≥6 visible invaders; or INVASION armed + ≥1 visible invader; or a visible great danger, megabeast, FB or titan; or UNDEAD_ATTACK/NIGHT_ATTACK report + visible undead | −1 (off), FPS_CAP 250 | on (Kern+) | all Ready; melee inside B1, crossbows in gallery | up by T+600 / up by T+600 / down | defense repairs inside only | frozen |
| BREACH | a bridge not up at T+900, or a visible hostile inside Kern+ | off | on (Tiefe+) | melee hold the B2 choke | up / up / up | none | frozen |
| RECOVERY | 0 visible invaders map-wide ∧ 0 visible dangers within 40 tiles of O1, for 2,400 ticks | 250 | on until B1 is lowered | training; squad A stays inside B1 | lowered stepwise (§4) | cleanup | frozen until re-drill |
| DRILL | inbox `drill`, or yearly in PEACE with no merchants on the map | off | on | as SIEGE | as SIEGE, then lowered | frozen | — |

## 4. Control loops, cadences, siege reflex
Gameplay modules run on `cur_year_tick` deltas, which stay correct under timestream's skips of up to 9 ticks. I/O runs on `getTickCount` and also works while paused.
- **Budget:** at most 25 ms per real second (2.5 %), measured as window sums because the clock only has ms resolution, plus `getPerfCounters`.
- **Demotion:** a module that exceeds 5 ms three times gets its period doubled and emits KERNEL_SLOW. sense, threat, gate and siege are never demoted; if they run slow they emit KERN_FAULT.
- Every module call is wrapped in a pcall. Three faults in 10 min disable that module and emit KERN_FAULT (A).

| Loop | Cadence | Real time at 500 / 100 ticks/s | Budget |
|---|---|---|---|
| dispatcher (repeat-util, 1 frame) | every frame | — | O(1), <0.05 ms |
| eventful INVASION / REPORT / UNIT_DEATH | freq 10 / 10 / 100 (no JOB_*, CONSTRUCTION, BUILDING, UNIT_NEW_ACTIVE) | 0.02 s | enqueue only |
| threat scan (sense) | 50 ticks in PEACE; 25 in ALERT/SIEGE/DRILL; 10 for 2,400 ticks while INVASION is armed | 0.1 s / 0.25 s | ≤0.5 ms |
| census of units / items (`items.other` categories, sliced) | 100 / 1,200 | 0.2 s / 2.4 s | ≤1 ms per slice |
| gate controller | 25 in SIEGE/BREACH/DRILL, otherwise 600 | — | ≤0.2 ms |
| runner (≤3 active projects; 1 apply chunk ≤40 tiles per slice) | 600 per project | 1.2 s | ≤3 ms per chunk [S6] |
| economy · care | 1,200 | 2.4 s | ≤2 ms, sliced |
| military upkeep · `uniform-unstick --all --drop --free` | 3,600 · 33,600 | 7 s · 67 s | ≤1 ms |
| readiness check; snapshot export on request | 33,600 + after any defense-zone stage; 2,000 tiles per slice | 67 s | ≤2 ms per slice |
| state a/b · events flush · inbox listdir · heartbeat · perf row | ≥2 s and on mode change · 1 s · 0.5 s · 5 s · 30 s (real time) | — | ≤1 ms each |
| Python follow · supervisor | 1 s file tail · 60 s task | — | 0 DF calls |
| LLM | year review (403,200 ticks ≈ 13-15 min) + class-A events | ≤6 wakes/h | — |

**Siege reflex.** T0 is the detecting step. Latency is ≤25 ticks once INVASION is armed and ≤50 ticks otherwise. onInvasion alone only *arms* the scan, because the army may still be hidden.
- **T0, same step:** mode SIEGE; timestream `set fps -1` with FPS_CAP left at 250 (no slow motion); civ alert on with `Kern+` (the whole sealed interior, so the economy keeps running); `military.posture(READY_STATION)` sends melee to `manifest.stations.melee` inside B1 and crossbows to `manifest.stations.gallery`; runner frozen; SIEGE_START (B) and a state flush.
- **T0 to T0+600, every 25 ticks:** `gate.want(O1,B1,'up')` fires as soon as citizens outside Kern+ (soldiers excluded) = 0, or T ≥ 600, or a visible hostile is ≤10 tiles from the bridge.
- **Gate invariant (fixes the double toggle).** A pull is queued only if (1) desired ≠ current (`gate_flags.closed`), (2) the bridge is not `closing`/`opening`, (3) **no PullLever job is pending on any lever of that bridge**, and (4) no citizen stands on the bridge footprint (wait ≤300 ticks; hostiles on it do not block). If the queued job has no worker after 200 ticks, `act.cancel_own_lever_job` cancels it (UI: cancel the queued pull) and the pull goes to the backup lever. There is only ever one pending pull.
- **T0+900:** a bridge not raised → GATE_FAIL (A) and **BREACH in-game**: alert burrow switches to `Tiefe+` (deep refuge), B2 (core seal) goes up, melee holds `manifest.stations.b2`.
- **Every 600 ticks:** SIEGE_STATUS (C): visible hostiles, worn %, soldiers on station, deaths, captures. **Kill orders** only on targets inside `manifest.killboxes`, never on stair or shaft tiles; sorties only via `squad.sortie` plus approval.
- **Exit to RECOVERY** on **visibility, never on path existence** (a raised bridge cuts the walk groups, so "no path" means nothing during a siege). Then, on quiet time: +0 training resumes; +1,200 B2 then B1 down and alert off, traps reload, captives hauled to the pit, visible corpses within 15 tiles of the approach dumped then buried; +2,400 O1 down; +8,400 PEACE and SIEGE_END (A). Any visible invader sends the FSM straight back to SIEGE (raise, same invariant).
- **ALERT exit:** 1,200 quiet ticks.
- **DRILL** is SIEGE without enemies. It runs the real routines, real lever pulls and real burrows. At T+1,200 it records the KPIs of §5.4, then lowers the bridges with the same invariant.

## 5. Doctrine encoded
**5.1 Site and embark** (checklist read from the vanilla embark screen and finder only; port of `tools/embark`):
- **Site:** ≥10 world tiles from any goblin Dark Fortress and from the 5 old fort sites. Evil neutral or good, savagery low or medium. Trees and flowing water. Aquifer none (light only with the probe protocol; heavy rejects the site). Flux plus ore if shown. Shallow soil. Temperate. Embark 3x3 or 4x4.
- **Spend all points:** 3 picks, 2 axes, an anvil, bars, wood, plump helmet and surface seeds, 1-2 breeding pairs.
- **Starting skills:** 2 miners, mason/engraver, carpenter, brewer/grower, mechanic, cook/doctor.

**5.2 Fortcore template** (the doctrine geometry, parametric only in anchor, rotation and depth).
- **Zones:** Z0 outside → **O1** (3-wide drawbridge, 2 levers inside) → **Z1 bailey** (walled, 2-tile overhang, depot) → **Z2** trap hall (1 wide, ≥40 tiles, ≥3 bends, weapon traps with ≤10 components plus stone-fall filler, **no cage traps on the main path**), then a 7x7 killing field under a roofed, fortified gallery at z+1 reachable only from inside → **B1** inner bridge (2 levers) → **Z3** gatehouse and barracks (racks, stands, chests) plus the military stair → **B2** core seal → **Z4** civilian core (civilian stair, farms, workshops, stockpiles, well, hospital with its own water, tombs, dining, bedrooms). The **Tiefe+** refuge sits ≥3 z below the core with its own well, food and beds.
- **Burrows and manifest:** `#burrow` sections for `Kern+` (Z3+Z4) and `Tiefe+`, plus a manifest fragment (bridges→levers, stations, killboxes, edge, refuge anchor, stairs).
- **Stages:** 1 (P0-P1) tunnel, 2 stairs, workshops, dorm, farms, well, depot; 2 (P2-P3) trap hall, B1, barracks, gallery; 3 (P5) full traps, O1, B2, refuge. Outer natural walls are smoothed (unclimbable).
- **Validator** (offline) rejects a single stair, a shortcut bridge, a refuge on the attack path, doors counted as barriers, diagonal leaks and unclosed rooms.

**5.3 Military.**
- **Squads:** A and B melee, C crossbows, each ≤10. Size is 15 % of adults at pop ≤55 and 20 % from 60 (D-12), with ≥8 soldiers for readiness level R2.
- **Routines:** Constant training, never Off duty. Minimum soldiers per order = half the squad.
- **Setup [S2]:** routines are configured once, resolved by **name**, and verified on a backup save. At runtime only `cur_routine_idx` and the orders change.
- **Uniform:** Replace clothing, full metal armor plus shield. Bronze and bought metal in Y1, iron and steel in Y2 via `library/military`. Goblin gear is melted through a `logistics add melt` pile.
- **Recruits** are chosen read-only. Excluded: members of the builtin Miners, Woodcutters and Hunters details, sole holders of a key labor, nobles. Preferred: existing combat skill, then strength and toughness. There are **no work-detail writes** (labormanager is the sole owner).
- `autotraining` only runs a geared need-squad that is never drafted. No civilian squads.
- **KPIs:** worn % (items worn ÷ uniform slots, measured at T+1,200 of a drill), combat value (weapon + shield + armor + dodge skill levels).

**5.4 Readiness gate.** Only readiness raises max-pop.
- **R0:** cap 55.
- **R1 "sealed":** the audit passes (with all bridges *lowered* and doors open, removing the trap-hall tiles leaves no edge→Z3 path; the refuge is reachable from the core without Z2/Z3; civilian path ≠ attacker path; caverns sealed), Kern+ and Tiefe+ exist, and every manifest bridge has 2 levers.
- **R2 "grow to ≤75":** R1, plus a drill passed ≤100,800 ticks ago (bridges up ≤T+900, worn ≥90 %, nobody outside at T+1,200, 0 double toggles), soldiers ≥15 % of adults and ≥8 with combat value per soldier ≥ `plan.cv_min` (default 12), ≥30 armed traps on every attacker path, food ≥60 days and drink ≥170 days.
- **R3 "≥80":** D-01 = Option B and ≥20 % of soldiers wearing iron or steel.
- **Demotion:** readiness red → max-pop frozen at the current population and beauty pauses. The S10 read of the difficulty siege triggers sets the R2 ceiling at trigger − 5, leaving margin for births and visitors.

**5.5 Economy and labor.**
- **Baseline on adopt and on every load:** `control-panel enable` for the native list in §3; `prioritize -a defaults`; autochop with wood ≥14; autobutcher with low targets and ≤2 cats; `tailor materials silk cloth yarn`; `pop-control set max-pop 55` and `wave-size 8`; `labormanager mode monitor`.
- **Staged orders imports:** `library/basic` after the first migrants, `rockstock` once a mason exists, `furnace`/`smelting` with a smelter and fuel, `military` with a forge, all followed by `orders sort` and `orders recheck`.
- **labormanager:** after 2 seasons in monitor mode, an A/B test switches to `modern` + `balance balanced` + `labor MINE unmanaged`. The test compares starving postings and projects done [S5].
- **KPI:** starving postings = 0, parsed from `labormanager status` once per game day.
- **Idle (D-03):** act only if idle >40 % for 3 game days **and** the useful backlog is not empty. The backlog holds boulders→blocks (capped), walls and overhangs, smoothing of *used* rooms, capped trade crafts, and `combine`. Never filler digging.
- **Cancel-loop detector:** an order cancelled ≥5 times per day is suspended and reported (Run 4).

**5.6 Happiness.**
- **Order:** dining hall with tables and chairs → own bedrooms (free ≥ adults + 4, value ≥500) → general temple (≥2,000 when a sect petitions) → tavern (keeper, mugs) → library.
- **Locations** are created through the quickfort `location=` zone property [V].
- **Stress KPI:** share of citizens with category ≤1 (0 is the worst). The top 5 stressors per week go into the brief.
- **0 naked:** tailor; `fixnaked` is not used.

**5.7 Beauty.**
- Templates tag rooms `used` or `utility`. Only `used` rooms (dining, temple, tombs, noble suites) are smoothed and engraved, and only up to the template's tier target (dining Grand 2,500 then Royal 10,000; bedrooms ≥500; temple ≥2,000).
- Artifacts and masterworks go onto pedestals in the dining hall or temple.
- Beauty runs only in PEACE with R1 green.
- Created wealth is logged with every threat event to test the wealth hypothesis. There is **no automatic wealth pause** (D-13).

**5.8 Trade.**
- **Trigger:** the CARAVAN_ARRIVAL report.
- **Port:** handelauto (broker job, vanilla trade screen, ratio ≥1.5) after an audit of its goodflag writes. Goods come from `logistics add trade` piles; the buy list from `plan.trade.want`.
- O1 stays down only while no visible hostile exists.
- Stuck caravans: `fix/stuck-merchants` (D-08 drops the `flags1.left` edit).

**5.9 Moods.**
- All 12 moodable workshop types by the end of Y1, checked against the manifest.
- A mood stock of cloth, leather, bone, shell, gems and bars ≥10 each, kept as order conditions.
- On MOOD_START, care unforbids and un-dumps the needed materials and emits MOOD_NEED if a material is missing.
- `act` has **no** job-removal function except `cancel_own_lever_job`. Lint enforces this.

**5.10 Burial.**
- One 1x1 tomb zone per coffin, with free tombs ≥ open corpses + 6; otherwise care requests a `tombs` project.
- autoslab, burial, preserve-tombs.
- KPIs: 0 ghosts, 0 corpses older than 3 days.

**5.11 Food and drink.**
- **Days of stock:** stock divided by a 7-day moving consumption average, seeded with Run 6 rates (0.053 drinks and 0.024 meals per dwarf per day). Targets: drink ≥170, food ≥60, ≥5 meal kinds.
- **Kitchen:** `ban-cooking booze honey milk oil tallow` plus one `kitchen.addExclusion` for PLUMP_HELMET (Gordon's rule; no `brew` ban).
- `seedwatch` only on farmed crops, at 12.
- **Guards:** forbidden-barrel guard (Run 5), barrels allowed in food piles, hospital water check (Run 6).

**5.12 Phases** (`plans/year1.json`, advanced by the kernel when deliverables pass; ★ = LLM approval):

| Phase | Deliverables |
|---|---|
| P0 | baseline; probe stair (damp → stop); fortcore stage 1 |
| P1 | dining, well, depot, offices, craftsdwarf workshop |
| P2 | trap hall, B1, barracks, squad A |
| P3 | smelter, forge, all workshop types, hospital, mood stock |
| P4 | caravan trade, bedrooms, tombs, tavern, temple |
| P5 | stage 3, gallery, squads B and C, **drill 1** |
| P6 (Y2) | iron or steel kits, ≥300 bolts, ★ R2 cap raise |
| P7 | beauty; ★ R3 only with D-01 = B |

## 6. File formats
**Runtime folder.** `<DF>/dfllm-runtime/ACTIVE` holds the save folder name (written at boot, deleted at unload); everything else lives under `<DF>/dfllm-runtime/<save>/`. Lua writes integers only. State writes alternate between `state.a.json` and `state.b.json`, and readers take the valid one with the higher `seq`. New files (outbox, snap) are written to `.tmp` and renamed onto a name that does not exist yet; Python writes the inbox with `os.replace`. **Persistent site data** `dfllm` (marker, manifest, projects, drill results, mode) is the single source for anything fort-specific.

**state.a|b.json** (≤4 KB, written every ≥2 s and on every mode change):
```json
{"v":2,"seq":812,"t":{"y":3,"tick":123456,"season":1,"tps":462,"paused":false},"mode":"PEACE","phase":"P3",
 "pop":{"cit":52,"adults":44,"cap":55,"gate_cap":55,"soldiers":8},"ready":{"lvl":1,"worn":94,"cv":13,"drill_age":40000,
 "audit":{"ok":1,"age":9000,"min_traps":22},"fail":["traps<30"]},"stock":{"drink_d":182,"food_d":75,"meals":6,"hosp_water":1},
 "care":{"stressed_pct":4,"naked":0,"ghosts":0,"corpses_old":0,"tombs_free":9,"moods":0},"labor":{"starving":0,"idle":31},
 "threat":{"vis":0,"armed":0},"proj":[["fortcore","s2.build",64,""]],"bridges":{"O1":"down","B1":"down","B2":"down"},
 "k":{"ms_s":11,"gap_max_ms":420,"slow":[],"faults":0},"owners":{"pause":null,"tempo":"mode"},"ev":8812}
```
**events.jsonl** (append-only, rotated at 5 MB; emitted on change only):
`{"n":8812,"tick":1234500,"type":"SIEGE_END","cls":"A","msg":"149 hostiles, 31 killed, 0 lost, sealed 6.1 d","d":{}}`
- **A** wakes the LLM: SIEGE_END, GATE_FAIL, BREACH, DEATHS_3PLUS/day, DRILL_FAIL×2, KERN_FAULT, PERF_DEGRADED, DECISION_NEEDED, PLAN_EXHAUSTED, PROJECT_BLOCKED>2 days, YEAR_REVIEW.
- **B** goes into the digest: SIEGE_START, ALERT_*, MOOD_*, CARAVAN, MIGRANTS, PETITION, STOCK_LOW, CANCEL_LOOP, CAPTURE, BREACH_STOP, KERNEL_SLOW, WEALTH.
- **C** is log only: SIEGE_STATUS, SEASON, PROJECT_STAGE.

**inbox/`<ts>-<id>.json`:** `{"id":"c123","verb":"bp.place","args":{"tpl":"bedrooms","site":"S2","n":20},"by":"llm"}`. The reply goes to **outbox/`<id>.json`** as `{"id":"c123","ok":true,"msg":"queued P7"}`.

The verb set is closed: `plan.reload, bp.place, bp.cancel, drill, snapshot, audit, popcap.lower, tempo.lower, pause, unpause, trade.want, squad.sortie(approval), lever(PEACE), inspect, selftest`. There is no arbitrary Lua.

**plan.json** (written only by `dfllm plan apply` after checks):
```json
{"v":2,"year":3,"policy":{"option":"A","pop_ceiling":75,"beauty":"used_rooms"},"phase_target":"P6",
 "seasons":[{"build":[{"tpl":"bedrooms","site":"S2","p":{"n":20,"tier":500}}]},{"build":[]},{"build":[]},{"build":[]}],
 "military":{"pct":15,"squads":{"melee":2,"xbow":1},"cv_min":12},"supply":{"drink_d":170,"food_d":60,"mood_stock":10},
 "orders":{"import":["library/smelting"]},"trade":{"want":["bar:iron","anvil","cloth"],"sell":["crafts"]},"notes":""}
```
**snap/`<id>.json`:** `{"bbox":[x0,y0,z0,x1,y1,z1],"rows":{"z120":["##..+=B1..",...]},"bridges":{"B1":"up"},"traps":[[x,y,z,"W",3]]}`. Hidden tiles are `?`.

**config/decisions.yaml** holds Gordon's answers (§15). **commands.log** records the origin of every act and command.

## 7. CLI
- **In-game:** `dfllm boot|adopt|stop|status|selftest [--mock]|restore`. `adopt` is run once on the new fort and sets the marker. `onMapLoad.init` runs only `dfllm boot`.
- **Python** (`python -m df_llm_helper`, alias `dfllm`):

| Command | Purpose |
|---|---|
| `status` | ≤300 tokens |
| `brief` | ≤1.5k tokens |
| `follow` | Monitor target; prints one wake line of ≤150 tokens; runs the topo audit automatically |
| `events [--cls A] [--since N]` | read events |
| `plan propose\|check\|apply` | propose drafts from phases and state |
| `cmd <verb> [json]` | send an inbox verb |
| `bp list\|preview\|sites <tpl>` | ASCII preview, materials, top 3 sites |
| `doctor` | ticks/s, kernel ms per module, frame gaps, stalls |
| `supervise [--once]` | liveness, backup, restart |
| `lint [paths\|--cmd STR]` | also used as the hook entry |

## 8. LLM protocol and token budget
- The orchestrator is the main Claude Code session. It keeps ≤60k context, never reads ERFAHRUNGEN or transcripts, and runs `Monitor` on `dfllm follow`.
- **Per wake line** it spawns one **fresh Sonnet subagent** (Opus only for the Y1 plan and postmortems), briefed with the RULES.md card (≤2k) plus `dfllm brief` (≤1.5k); at most 5 tool calls; returns ≤100 tokens.
- **Year review:** `plan propose`, edit a few fields, then `plan check` and `apply`. This approves 4 season plans at once, which is how Gordon's "plan per season" fits into one review: a season is only 3.4 min real time.
- **Exception:** read `events --cls A`, then issue one `cmd`.
- **New building:** `bp sites`, pick, `bp.place`: ≤5 turns, <0.3 M tokens (v1: 42 M).
- **Rate limit** (in `follow`): ≤1 wake per type per 5 min, bursts merged within 60 s, ≤6 wakes per hour. Notifications go to chat only, never push.
- **Budget:** ≤3 M input tokens per real hour (alarm at 5 M; v1 74 M) and ≤30k output tokens per hour.
- **Without an LLM** the kernel keeps running safety and supply and finishes the approved plan. It never starts ★ items.

## 9. Repository layout and migration
**Repo A** (`dfpilot-public`, GordonMohrin/df-llm-helper) is the single source. Work happens on branch `v2` after tag `v1-final`, and `v2` merges to main only after A3 passes. Commits are authored by Gordon with Co-Authored-By and always pushed.
```
RULES.md (≤300 lines)  README.md  docs/v2/{DESIGN,CONTRACTS,DECISIONS,MIGRATION}.md
lua/dfllm.lua   lua/dfllm/{kern,io,act,sense,snapshot,persist,arbiter,perf,threat,gate,siege,military,readiness,drill,
                runner,baseline,economy,care,trade,selftest}.lua  lua/dfllm/util/{json,geom,k_mock}.lua
df_llm_helper/{__main__,cli,paths,files,schema,wake,brief,plan,cmd,doctor,events,supervise,fairplay,lint,hook}.py
df_llm_helper/bp/{primitives,fortcore,rooms,validate,emit,render,topo,sites}.py
plans/year1.json  config/{baseline.json,allowlist.json,decisions.yaml}  tools/{luahost.py,migrate_v2.py,embark/,win/vdesk_move.ps1}
tests/ (pytest; tests/lua/*.lua via luahost; fixtures/v2 recorded from the new fort)  .claude/settings.json (PreToolUse → dfllm lint --cmd)
```
**Removed from `v2`** (kept in `v1-final`):
- `df_llm_helper/*` except `lint`, `fairplay` (rules), `stalllog`, `clock` and `planners/blueprint.py` (which becomes `bp/validate.py`);
- `dfpilot/`, `Bugs/`, `Features/`, `fixtures/`, `scenarios/`, `runtime/`, `lua/claude`, `lua/pilot_*.lua`;
- `docs/manual-v3`, `specs-v2`, `specs-v3`.

**Repo B** (`dwarf-fortress`):
- Tag `run6-final`.
- `git rm` `lua/claude` (161 scripts), `dfpilot/`, `tools/aufsicht` (after neustart/sicherung are ported), `tools/gen_bau*.py`, `tools/*.flag` and the loop files.
- Keep `POSTMORTEM-run2..6.md`, `ERFAHRUNGEN.md` (archive), `BAUANLEITUNG.md` and `runs/run7/`. `CLAUDE.md` becomes a 30-line pointer to RULES.md.

**DF install** (`tools/migrate_v2.py`; everything is moved, nothing deleted):
1. Stop the waechter, the repo B supervisor and the DF-Aufsicht task.
2. In `script-paths.txt`, replace the repo B lua path with `+…\dfpilot-public\lua`.
3. `onMapLoad.init` = `dfllm boot`.
4. Move `hack/scripts/claude` → `<DF>/_archive-v1/`; move the automelt, channel-safely and confirm DLLs → `hack/plugins/_disabled/`; move `df-llm-helper-runtime/` → `_archive-v1/`.
5. Repoint DF-Aufsicht to `pythonw -m df_llm_helper supervise --once`.
6. Embark, then `dfllm adopt`.

Prefs files are **not** edited.

## 10. Speed and CPU plan
- **Targets:** PEACE ≥450 calendar ticks/s at pop ≤55 (timestream 500; Run 3 measured 458; try 700 after A2). SIEGE and DRILL ≥100 ticks/s with timestream off and FPS_CAP 250. Kernel ≤25 ms per second, 0 frame gaps >3 s per hour outside autosaves, autosave freeze ≤15 s.
- **Per-save runtime profile** (applied at boot; originals saved to `restore.json` and the save; restored at SC_MAP_UNLOADED; a crash is healed at the next boot of any save): timestream fps by mode; `enabler.gfps` 30; `d_init.feature.autosave` YEARLY [S8: enum name]; population cap back to its pre-boot value (pop-control leak); headless overlay profile with everything but notify disabled (overlays cost 3.6-6.4 % of real time; old state re-enabled on unload); `visitor_cap` 30 and weather only per D-07.
- **Load:** 3x3 or 4x4 embark, low autobutcher targets, caverns sealed, goblin gear melted, bins and `combine`, no filler digging.
- **Never:** `items.all`, `buildings.all` or `reqscript` inside loops; the quickfort CLI (use `apply_blueprint` in chunks of ≤40 tiles); JOB_* or CONSTRUCTION hooks; in-game BFS (Python does it on snapshots); Lua quicksaves.
- **Measurement:** a frame-gap meter blames each gap on the last module or on "external"; perf.csv every 30 s holds ticks/s, pop, units, items and ms per module; `doctor` aggregates.
- **DEGRADED** fires when rolling 10-min ticks/s falls below 60 % of the post-load baseline (same mode and target) or an autosave freeze exceeds 20 s. The supervisor restarts DF **only in PEACE right after an autosave**: kill DF → Steam start → `vdesk_move.ps1` to desktop 1 (no focus steal) → `dfhack-run load-save <folder>` (port of neustart.py) [S9]. It never loads an older save. Liveness: heartbeat file (frames, so it also beats while paused) older than 120 s.

## 11. Fair-play guarantees
1. **Reads.** Only `sense.lua` and `snapshot.lua` read units and tiles. Units count only if `isVisible ∧ ¬isHidden`; tiles only if revealed (hidden tiles become `?`). No `water_table`, prospect or locate-ore. Damp, warm and cavern knowledge comes only from vanilla cancel reports and revealed-tile flags (BREACH_STOP). onInvasion only arms the scan.
2. **Writes.** Only `act.lua` assigns to `df.*` or calls mutating APIs, and each function maps to a UI action: designations (dig, smooth, engrave) and quickfort apply (dig, build, place, zone, burrow); work orders and `orders import`; stockpile, kitchen and seedwatch settings; forbid, dump and melt flags; squad create, assign, routine index, orders and uniform; civ alert and alert burrows; lever pull job and cancelling our own queued pull; `pop-control set`; timestream, gfps and runtime vanilla settings; dismissing whitelisted popups.
3. **Lint** (pre-commit and pytest, `dfllm lint`) rejects any `df.` assignment or vector insert/erase outside `act.lua`; unit or tile iteration outside sense/snapshot; `createItem`, `removeJob` (except in `act.cancel_own_lever_job`), `.hidden=`, `water_table`, `--instant`, `teleport`, and writes to skills, body, pos or timers.
4. **Commands.** `act.run` uses an **explicit allowlist** (`config/allowlist.json`), cross-checked at boot against `helpdb.get_tag_data('armok')`: an allowlisted entry with an armok tag must be a listed exception (`lever` is reachable only through `act.pull`). Always blocked: `digv`, `digvx`, `digtype --hidden`, fastdwarf, `caravan extend|happy`, autodump, locate-ore, prospect, showmood, reveal, createitem, dig-now, build-now, `fix/retrieve-units`.
5. **Hook.** A PreToolUse hook on Bash and PowerShell runs `dfllm lint --cmd`. It allows `dfhack-run dfllm …`, `load-save` and read-only `dfllm inspect`, and blocks `claude/*`, inline `lua` and anything on the blocklist. `DFLLM_DEV=1` enables `dfllm selftest --exec <file>` (linted, logged), which is refused while the save's `acceptance` flag is set.
6. **Register.** The exception register is retired. decisions.yaml holds only Gordon's answers, and the default until he answers is off or unchanged.

## 12. Work packages and waves
Wave 0 freezes the contracts. Waves 1 and 2 code in parallel against mock-K and fixtures. The **single live slot** is serialized through `dfllm-runtime/live.lock` (holder, purpose, expiry ≤30 min).

| WP | Goal | Files | Interface contract | Size | Deps | Tests | Done when |
|---|---|---|---|---|---|---|---|
| **WP0** (W0) | Freeze contracts; Lua testable offline | docs/v2/CONTRACTS.md, df_llm_helper/schema.py, lua/dfllm/util/{json,k_mock}.lua, tools/luahost.py, tests/lua/test_json.lua | Module `{name, every={ticks=N} or {ms=N}, init(K), step(K,budget_ms), on={EV=fn}, state(K)}`; K = `now() emit(type,cls,msg,d) census mode act persist plan cfg log`; JSON schemas for state, event, inbox, outbox, plan, manifest, snapshot | 300 Lua + 300 Py | — | luahost runs Lua tests on lua53.dll; JSON round-trip (ints, umlauts, comma locale) | Tests green; schemas validate the §6 examples; CONTRACTS frozen (changes go through the orchestrator) |
| **WP1** (W1) | Kernel: dispatcher, IO, persist, opt-in, arbiter, act core, perf | lua/dfllm.lua, lua/dfllm/{kern,io,persist,arbiter,act,perf,selftest}.lua | Implements K; a/b state, events, outbox; boot is a no-op without the marker; arbiter.apply(mode) idempotent; restore on unload; pcall per module | 800 Lua | WP0 | luahost: tick deltas with 9-tick skips, demotion, fault isolation, a/b writer. In-game: S1, S4, S8 | ≤25 ms/s with 5 dummy modules; heartbeat while paused; 0 dfhack-run in steady state; Inchcraft-style unmarked save untouched |
| **WP2** (W1) | Python CLI, follow and wake | df_llm_helper/{__main__,cli,paths,files,wake,brief,plan,cmd,doctor,events}.py | `files.read_state()` (best seq, retry); wake classes and limits; `plan check` = schema + validators + fair play + `pop_ceiling ≤ R-level cap` | 800 Py + 300 tests | WP0 | Torn-read fixtures, rate limits, brief ≤1.5k tokens, plan rejections | All §7 commands work on the fixture runtime; follow lines ≤150 tokens |
| **WP3** (W1) | Templates, validators, emitter, topo audit, site finder | df_llm_helper/bp/*.py (port planners/blueprint.py), tests/bp/, golden JSON | `emit(tpl,params,site) → {stages:[{label,mode,data,chunks≤40}], manifest, materials}`; `topo.audit(snap,manifest) → {ok, fails, min_traps, bypass, refuge_sep, civ_sep, caverns}`; `sites.rank(snap,tpl) → top 3` | 1,200 Py + 400 tests | WP0 | Flood-fill closure, diagonals, 2 stairs, shortcut bridge, trap-hall-removed BFS, golden data | fortcore stages 1-3 + 7 room templates (dining, bedrooms, tombs, hospital, temple, tavern, workshops) valid; audit ≤2 s on 100×100×12 |
| **WP4** (W1) | Fair play: lint, allowlist, hook, decisions | df_llm_helper/{fairplay,lint,hook}.py, config/{allowlist.json,decisions.yaml}, docs/v2/DECISIONS.md, .claude/settings.json | `lint.lua(paths)`, `lint.cmd(str)`; `decisions.get(id)` with defaults | 400 Py | WP0 | Positive and negative cases, including v1 snippets | 0 findings on lua/dfllm; hook blocks `lever pull --instant`, `claude/x`, fastdwarf |
| **WP5** (W2) | Threat, gate, siege FSM, BREACH, RECOVERY, captives | lua/dfllm/{sense,threat,gate,siege}.lua, tests/lua/test_siege.lua | `sense.census` (cit, adults, outside_kern, hostiles_vis[]); `gate.want(bridge, 'up' or 'down', why)` with the single-pending invariant; modes and events per §3/§4 | 800 Lua | WP1 | luahost table-driven scenarios: no flapping, raised bridge ≠ RECOVERY, no double toggle, BREACH at T+900. Live drill L3 | 20/20 synthetic scenarios pass; drill KPIs of §14 met |
| **WP6** (W2) | Military, readiness, drill | lua/dfllm/{military,readiness,drill}.lua | `military.posture(P)`, P ∈ TRAIN, STATION_B1, READY_STATION, B2_HOLD; worn % and combat value; read-only recruit filter; `readiness.level` → `act.popcap`; `drill.run()` | 700 Lua | WP1, WP5, WP3 (audit) | luahost worn % on fixtures; S2 live | 3 squads; routine resolved by name; worn ≥90 %; cap changes only through pop-control |
| **WP7** (W2) | Project runner + capacity keepers | lua/dfllm/runner.lua | Project `{id,tpl,site,stage,chunk,pct,blocked}`; dig → build → place → zone/burrow → finish; `command='orders'` once per stage; BREACH_STOP; deregister at 100 % | 500 Lua | WP1, WP3 | luahost with fake quickfort; S6; live L2 | fortcore stage 1 built on the new fort with only the site picked by the LLM |
| **WP8** (W2) | Baseline, economy, care | lua/dfllm/{baseline,economy,care}.lua, config/baseline.json | `baseline.apply()` idempotent; stock days, staged imports, cancel-loop detector, labormanager parse; care: moods, tombs, corpses, captives → pit, hospital water, barrel guard, stress and naked sampler | 700 Lua | WP1 | luahost fixtures; S5; live L1 | Baseline active after adopt; supply KPIs in state; 0 mood jobs removed |
| **WP9** (W3) | Trade port | lua/dfllm/trade.lua | CARAVAN_ARRIVAL → broker job → trade screen; `plan.trade`; O1 window through `gate.want` | 600 Lua | WP1, WP5 | goodflag audit; luahost ratio math; live when a caravan comes | 1 caravan traded with ratio ≥1.5 and no LLM |
| **WP10** (W1 offline / W3 live) | Supervisor, restart, backup, migration | df_llm_helper/supervise.py, tools/migrate_v2.py, tools/win/vdesk_move.ps1 | Liveness = heartbeat age; DEGRADED rule; restart only in PEACE after an autosave; backup copy after an autosave; migrate is idempotent and reversible | 400 Py | WP2 | Fake clocks, dry-run migrate; S9 live | One supervised restart onto desktop 1 with no focus steal |
| **WP11** (W1 embark / W3 docs) | Embark, year-1 plan, RULES.md, repo cleanup | tools/embark/* (port), plans/year1.json, RULES.md, docs/v2/MIGRATION.md, repo B CLAUDE.md | Embark checklist (§5.1) from the vanilla screen; phases P0-P7 as data | 400 mixed | WP0 (plan schema) | Site checklist against vanilla finder output | Fort embarked per §5.1; RULES.md ≤300 lines; v1 code removed in `v2`; repo B tagged and cleaned |

**Waves:** **W0** WP0 (1 agent, about 2 h) → **W1** WP1, WP2, WP3, WP4 + WP11 embark port + WP10 offline, in parallel → **W2** WP5, WP6, WP7, WP8, in parallel → **W3** WP9, WP10 live, WP11 docs and cleanup, then acceptance.

**Live slots, in order:** L0 (after WP1) embark, adopt, S1, S4, S7, S8 → L1 baseline, S5, S6 → L2 fortcore stages 1-2 → L3 squads S2, levers S3, drill → L4 trade and moods as they occur → L5 soak with S9 and S10.

**MVP cut** if time runs short: WP9 is deferred (manual caravan handling through the LLM). Legacy repo B scripts are **never** wrapped.

## 13. Spikes (run first; each has a fallback)
| # | Question | Fallback |
|---|---|---|
| S1 | Kernel cost with 5 dummy modules at timestream 500; cur_year_tick scheduling; frame-gap meter | merge modules, longer cadences |
| S2 | Squad creation needs a position assignment: UI-equivalent creation, routine names and index, `uniform_mode` values; write once on a backup save and reload | in-process `gui.simulateInput` on the squad screen (no OS focus) |
| S3 | `leverPullJob` latency; reading `gate_flags`; cancelling our own pending job; bridge flinging with a unit on it | a lever-puller burrow next to the levers |
| S4 | a/b state under 10k writes with a concurrent Python reader; listdir cost; antivirus locks | seq-numbered files |
| S5 | `labormanager status` parse cost; does it add soldiers to tool details; A/B test monitor vs modern | stay in monitor mode + vanilla details |
| S6 | `apply_blueprint` ms per 40-tile chunk for dig, build, zone and burrow; `command='orders'` | smaller chunks; files under `dfhack-config/blueprints/dfllm/` |
| S7 | Report ids for ambush, beasts, undead, caravan and dig-cancel damp/warm; INVASION timing relative to visibility | the census scan is the primary trigger anyway |
| S8 | Runtime settings: autosave enum, gfps, visitor cap; restore on unload; timestream status parse | Gordon sets them once in the Settings UI |
| S9 | Restart on desktop 1 + load-save (warn Gordon first) | manual restart on Gordon's word |
| S10 | Read the difficulty siege triggers and caps (read-only) | Gordon reads Settings → Difficulty |

## 14. Live acceptance on the new embark
**Setup.** A new fort in the same world, at a site per §5.1. `dfllm adopt`, with the acceptance flag set (no dev exec).
- Before every stage: `dfllm doctor`.
- KPIs come from state, perf.csv and events. Tokens come from the session usage.
- Real sieges may not happen at pop ≤55, so **drills are the acceptance test for the reflex**. A real raid or siege is a bonus test.

**Stages:**
- **A0, days 0-5:** baseline active, heartbeat live, ticks/s baseline recorded, 0 spawns per hour.
- **A1, end of Y1:** P0-P5 delivered, drill 1 passed, R1 green.
- **A2:** 2 game years unattended (about 30-40 min real time at speed); KPIs green.
- **A3:** an R2 cap raise to ≤75 after a passed drill. A first real raid or siege must cost ≤10 % of citizens; if none comes, A3 passes on 2 consecutive drill passes.

| Area | KPI | Threshold |
|---|---|---|
| Speed | PEACE median calendar ticks/s over 10 min | ≥450 at pop ≤55 |
| Speed | SIEGE/DRILL ticks/s | ≥100 |
| Speed | kernel cost; p99 slice; any call | ≤25 ms/s; ≤3 ms; ≤50 ms (reflex ≤10 ms) |
| Speed | frame gaps >3 s outside autosave; autosave freeze | 0 per hour; ≤15 s |
| DF calls | dfhack-run spawns per hour in steady state | 0 (≤10 per hour for dev tools) |
| Reflex (drill) | mode and alert in the trigger step; lever job queued | same step; ≤T+600 or when 0 citizens are outside |
| Reflex (drill) | bridges raised; double toggles | ≤T+900; 0 |
| Reflex (drill) | worn % and citizens outside at T+1,200 | ≥90 %; 0 |
| Readiness | R1 by end of Y1; cap violations | yes; 0 (citizens ≤ cap + 3) |
| LLM | input tokens per hour; wakes per hour; turns per building; brief size | ≤3 M; ≤6; ≤5; ≤1.5k |
| Labor | game days with starving postings = 0 | ≥90 % |
| Labor | Y1 phase deliverables | done by winter |
| Happiness | citizens with stress category ≤1; naked | ≤10 %; ≤5 % |
| Happiness | ghosts; corpses older than 3 days; failed moods from a missing workshop or material | 0; 0; 0 |
| Supply | from Y1 autumn: drink and food days | ≥170 and ≥60 |
| Supply | thirst or hunger deaths | 0 |
| Fair play | lint findings; hook blocks; hidden reads | 0; all logged; 0 |
| Safety | deaths caused by tooling bugs; actions on unmarked saves | 0; 0 |

## 15. Decisions for Gordon (asked once, answers stored permanently; defaults apply until then)
| Id | Decision | Default |
|---|---|---|
| D-01 | Option A (cap ≤75) or B (≥80) | A |
| D-02 | Difficulty changes (invasion cap, siege frequency) | unchanged |
| D-03 | Idle rule: >40 % idle for 3 days, act from a useful backlog only | this rule |
| D-04 | `work-now` | off |
| D-05 | `agitation-rebalance` | off |
| D-06 | tailor confiscate, cleanowned | off |
| D-07 | `visitor_cap` 30, WEATHER off, baby caps (per save) | unchanged; visitor cap recommended |
| D-08 | caravan `flags1.left` edit | dropped; `fix/stuck-merchants` instead |
| D-09 | Cook plump helmets in a famine | no |
| D-10 | emigration, deteriorate | off |
| D-11 | timestream | accepted |
| D-12 | Army share | 15 % at pop ≤55, 20 % from 60 |
| D-13 | Automatic beauty pause at high wealth | no (wealth is logged) |

## 16. Fatal flaws from the judges and how they are removed
| Flaw | Fix |
|---|---|
| RECOVERY on "no path" lowers bridges into a camping army (native) | RECOVERY needs **0 visible invaders map-wide** for 2,400 ticks; bridges are lowered in steps on quiet time (§4) |
| Backup or second pull double-toggles the bridge (all three) | single-pending-job invariant, gate_flags check, cancel our own job before the backup lever (§4) |
| Melee in an open killing field (kernel, native) | melee only inside B1, crossbows in a roofed gallery; kill boxes only (§5.2-5.3) |
| GATE_FAIL with no in-game fallback (kernel) | BREACH: Tiefe+ alert, B2 seal, B2 hold, no LLM in the loop |
| No per-save opt-in; global prefs patches (kernel, doctrine) | site marker + manifest in persistent data; runtime settings with restore; prefs untouched |
| Two writers on work details (all three) | labormanager sole owner; military read-only filter |
| Lua untestable outside DF (all three) | `tools/luahost.py` on `hack/lua53.dll` (verified) + mock-K + in-game selftest |
| Acceptance needs sieges (all three) | drill-based acceptance with real levers and routines (§14) |
| os.rename is not atomic on Windows (kernel) | a/b slots with seq; new-name renames only (verified) |
| JOB_COMPLETED/CONSTRUCTION hooks and frequency 1 (kernel) | only INVASION 10, REPORT 10, UNIT_DEATH 100 |
| 20k-tile BFS slices against a 2 ms budget (doctrine) | BFS runs in Python on sliced snapshots |
| Scope too large (doctrine) | about 4.4k Lua + 3.8k Py (incl. 0.7k tests) + 0.4k mixed, near native's size; MVP cut (WP9 deferrable); no legacy wrapping, no hot reload |
| Auto-unpauser (native) | unpauses only popup-caused pauses; honours manual pauses |
| FPS cap 100 in SIEGE (native) | timestream off, FPS_CAP 250 |
| No site rule (doctrine, native) | §5.1 site checklist |
| Unsupported wealth pause (kernel) | D-13, logging only |
