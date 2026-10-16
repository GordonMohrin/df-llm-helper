# dfpilot v2: final design

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
Python dfpilot (stdlib): follow/wake · status/brief · plan · bp (templates, topo audit, sites) · doctor · lint/hook
Windows task DF-Aufsicht → `dfllm supervise --once` (liveness, backup, restart; never pauses/unpauses)
Claude Code orchestrator (≤60k ctx, Monitor on `dfllm follow`) → fresh Sonnet subagent per wake/year review
```
**Data flows.** The kernel writes state and events, Python tails them, and the follower prints a wake line that the orchestrator turns into a subagent. The subagent writes plan.json, and `dfllm plan apply` puts it in the inbox for the kernel. For a path audit, the kernel exports a snapshot (SNAPSHOT_READY), the follower runs `bp.topo.audit` automatically with no LLM involved, and the result comes back through the inbox `audit` verb into readiness.

**Actuator ownership** (sole writer is the module; `act.lua` is the only code that assigns to `df.*`):

| Actuator | Sole writer | Desired value from | External input |
|---|---|---|---|
| pause | arbiter | Never pauses. Unpauses only pauses caused by a whitelisted popup, which it dismisses (live L3: a berserk notice too, with DECISION_NEEDED `berserk`; halted, nothing in v2 reacted and the fort stood still). | inbox `pause` (TTL ≤600 s)/`unpause`. A pause by Gordon is honoured; a D event after 10 min. |
| timestream fps, `enabler.gfps` | arbiter | mode table | inbox `tempo` (lower only, TTL) |
| civ alert + alert burrow list | siege | mode (Kern+ or Tiefe+) | — |
| squad routine/orders/stations | military | posture set by siege/drill | `squad.sortie` only with approval |
| levers/bridges | gate | f(mode, drill, trade window), single pending job | `lever` verb (PEACE only) |
| pop cap | readiness → `pop-control set max-pop` | readiness level ∧ plan ceiling | inbox can only lower it |
| designations, buildings, zones, burrows, locations | runner (care asks the runner for tomb zones) | project queue | plan.json |
| manager orders | economy (library imports, `quickfort orders`, `dfllm:`-tagged supply orders; removes make-item orders without item_subtype, which crash DF 53.16, and orders that keep cancelling for "Needs ...": FR-39, FR-10) | phase + stock days | plan.orders, inbox `order.add` |
| work details/labors | **labormanager**, except the builtin tool details Miners/Woodcutters/Hunters: **economy** (`act.work_detail`) whenever labormanager is not in modern mode (live L1b: in monitor mode nobody staffed them, one miner for the fort) | miners from the dig backlog (min 2, up to 4 from pop 20), woodcutters from logs vs autochop's band, hunters only in a famine; each capped by picks/axes/bows; no soldier, noble, moody dwarf or sole key-labor holder is picked; in a starvation economy also adds planters and plant gatherers (FR-25), and it drops the ids of dead citizens from every detail (FR-40) | military only *reads* membership to filter recruits |
| kitchen, seedwatch, stockpile settings | economy | baseline | — |
| forbid/dump/melt flags on items | care (corpses, captives, mood materials); economy unforbids forbidden drink/food/seed containers and seeds, food in a starvation (FR-23/25/50); military the invaders' metal gear (FR-46) | care rules; revealed, reachable tiles in PEACE/RECOVERY | — |
| runtime settings (autosave, visitor cap, gfps, overlays) | arbiter at boot; restored on unload | profile + decisions | — |

**Mode table** (owned by the siege FSM, applied by the arbiter). "Visible" means `isVisible ∧ ¬isHidden ∧ not caged`.

| Mode | Entered when | timestream | civ alert | squads | Bridges O1 / B1 / B2 | Projects | Growth |
|---|---|---|---|---|---|---|---|
| PEACE | default; RECOVERY + 8,400 quiet ticks | fps 500 (700 after A2 if stable) | off | Constant training | down / down / down | all, per readiness | per gate |
| ALERT | 1-5 visible hostiles, no great danger | 250; FPS cap 100 (Run 9, FR-51: timestream off under the cap) | on if a hostile is ≤30 tiles from a citizen outside Kern+ | squad A stationed inside B1 | O1 up if a hostile is ≤30 tiles from O1 | defense + infrastructure | frozen |
| SIEGE | ≥6 visible invaders; or INVASION armed + ≥1 visible invader; or a visible great danger, megabeast, FB or titan; or UNDEAD_ATTACK/NIGHT_ATTACK report + visible undead | −1 (off), FPS cap 30 (Run 9, FR-51; was 250) | on (Kern+; the separated refuge at the BREACH level in the deep defense, BUG-030) | all Ready at the inner station (READY_IN, BUG-029: `stations.melee`, `stations.b2` while B2 is not down); killing field and gallery only during an intake wave (INTAKE); every squad at the core station (CORE: `stations.core`, else `stations.b2`) in the deep defense (BUG-030: building destroyers in sight, an army > 3x our soldiers, weak squads) | up by T+600 / up by T+600 / down; an intake wave lowers B1 (muster, back) or O1 (open), never both | defense repairs inside only | frozen |
| BREACH | a bridge not up at T+900, a destroyed outer/inner bridge (at once, BUG-030), or a visible hostile inside Kern+ | off | on (Tiefe+) | melee hold the B2 choke | up / up / up | none | frozen |
| RECOVERY | 0 visible invaders map-wide ∧ 0 visible dangers within 40 tiles of O1, for 2,400 ticks | 250 | on until B1 is lowered | training; squad A stays inside B1 | lowered stepwise (§4) | cleanup | frozen until re-drill |
| DRILL | inbox `drill`, or yearly in PEACE with no merchants on the map | off, FPS cap 30 | on | as SIEGE | as SIEGE, then lowered | frozen | — |

## 4. Control loops, cadences, siege reflex
Gameplay modules run on `cur_year_tick` deltas, which stay correct under timestream's skips of up to 9 ticks. I/O runs on `getTickCount` and also works while paused.
- **Budget:** at most 25 ms per real second (2.5 %), measured as window sums because the clock only has ms resolution, plus `getPerfCounters`. On a big fort the critical modules (sense scans every unit) may take more: the self-test allows `25 + 6 * (units / 150 - 1)` ms/s, at most 40 (FR-62).
- **Demotion:** a module that exceeds 5 ms three times gets its period doubled and emits KERNEL_SLOW. sense, threat, gate and siege are never demoted; if they run slow they emit KERN_FAULT. Promotion needs quiet running time that doubles after every demote/promote flip; KERNEL_SLOW is news once per module per 6 h (FR-62).
- **Pacing and fort size (FR-62):** a non-critical module spends at most its share of ms per real second (seal 4, economy 3, default 2); while over it, its runs and `'more'` slices wait, so on a big map a sliced pass takes more frames instead of more ms per second. In PEACE the shares of the waiting modules are scaled together to what the budget leaves after the critical modules and the kernel's housekeeping. economy and care stretch their cadence with the load factor `max(units / 150, items / 6000)`, at most 3x. Every ms is booked to an owner (modules, `k.state`, `k.io`, `k.persist`, `k.inbox`, `k.events`, `kern`); `doctor` lists them.
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
- **Before T0 (Run 9, FR-49/51/52, CONTRACTS §9.18):** the arrival announcement (popup or report), INVASION or the first armed hostile in sight starts the reflex lockdown: every lever-linked bridge up (no manifest needed), entrance doors forbidden (next to open sky, and the doors on seal's entrance routes, BUG-012; the openings without one are named; a door waits while a citizen is outside it, at most 450 ticks, not at all with a hostile within 15 tiles), civ alert (siege owns it, seal picks the burrow; when every burrow fails its audit the interior `Innen+` is kept for the lockdown, BUG-011), timestream off and FPS cap 30, until threat 0 for 2 days; interrupts go to `<save>/alarm.txt` and wake at once.
- **T0, same step:** mode SIEGE; timestream `set fps -1` with the FPS cap at the siege cap 30 (CONTRACTS §18.12; was "left at 250, no slow motion"); civ alert on with `Kern+` (the whole sealed interior, so the economy keeps running); `military.posture(READY_IN)` sends every squad, crossbows too, to the inner station (`manifest.stations.melee` inside B1, `stations.b2` while the core seal is up: BUG-029, the stations between O1 and B2 had no drink for weeks; DRILL keeps READY_STATION, crossbows in `stations.gallery`); runner frozen; SIEGE_START (B) and a state flush.
- **T0 to T0+450, every 25 ticks:** `gate.want(O1,B1,'up')` fires as soon as citizens outside Kern+ (soldiers excluded) = 0, or T ≥ 450, or a visible hostile is ≤10 tiles from the bridge (live L2: a pull takes 256-297 ticks from queue to raised, a cancelled unworked pull plus the backup lever about 400, so pulls at T+600/T+540 missed T+900).
- **Gate invariant (fixes the double toggle).** A pull is queued only if (1) desired ≠ current (`gate_flags.closed`), (2) the bridge is not `closing`/`opening`, (3) **no PullLever job is pending on any lever of that bridge**, and (4) no citizen stands on the bridge footprint (wait ≤300 ticks; hostiles on it do not block). If the queued job has no worker after 200 ticks, `act.cancel_own_lever_job` cancels it (UI: cancel the queued pull) and the pull goes to the backup lever. There is only ever one pending pull.
- **T0+900:** a bridge not raised → GATE_FAIL (A) and **BREACH in-game**: alert burrow switches to `Tiefe+` (deep refuge), B2 (core seal) goes up, melee holds `manifest.stations.b2`.
- **Every 600 ticks:** SIEGE_STATUS (C): visible hostiles, worn %, soldiers on station, deaths, captures. **Kill orders** only on targets inside `manifest.killboxes`, never on stair or shaft tiles; sorties only via `squad.sortie` plus approval.
- **Intake waves (Gordon 2026-10-16, Run 10 y419: 47 goblins waited weeks in front of the raised O1, the trap hall and the killing field were never used; `config/reflex.json` `intake`, on by default; siege `m.siege.ik`, state `wave`).** SIEGE only: `idle` checks every pass: a fortcore manifest (O1, B1, a killbox, zones Z1/Z2) whose intake area Kern+ does not cover (a hostile on Kern+ is a BREACH), SIEGE for `stable` (600) ticks, no STRANDED rescue/hold or sortie, O1 and B1 up, the civ alert on, no civilian and no hostile in the intake area (Z1, Z2, killboxes), none past B1, no dangerous hostile in sight (a great danger, or the caste raws BUILDINGDESTROYER, TRAPAVOID, FLIER: sense `dz`), soldiers ≥ `min_soldiers` (4), worn ≥ `worn` (80 %), visible hostiles ≤ `army_ratio` (4) × soldiers, every trap of the intake area armed (`snapshot.traps`; `?` when unreadable); a refusal is INTAKE `refused` (B, once per reason). `muster`: posture INTAKE (melee to `stations.field` or the killbox centre, crossbows to the gallery), a raised core seal and B1 go down with O1 up, B1 rises again once the soldiers stand on station (all, or `min_soldiers` after half of `muster`) and no civilian is in the area. `open`: O1 down (the airlock: gate lowers an outer bridge for an intake or sortie only while every inner one is up and wanted up, and the reverse); O1 rises (raising onto hostiles flings them, gate never raises onto our units) when min(`wave` 6, soldiers on station) hostiles are in the area, at `losses` (1) citizens lost (WAVE_FAIL), a dangerous hostile within `danger_dist` (20) of O1, fewer soldiers on station or a lower worn, or after 2,400 ticks without anybody. `fight`: kill orders on the killbox hostiles to the crossbows and the melee in the field; clear = no visible hostile in the area; `fight` (4,800) ticks without: WAVE_FAIL stuck (B1 stays up). `back`: posture READY_IN, B1 down until no soldier is left in the area or the gallery, B1 up; `cool` (1,200) ticks, then `idle`. Hostiles in the intake area are expected: no BREACH (that needs one on Kern+), no INTRUDER (reflex asks `siege.expects`); one past B1 during a wave is WAVE_FAIL past_b1 and, on Kern+, BREACH. Leaving SIEGE ends a wave. BUG-029 also with intake off: soldiers outside B1 between waves (`stray`) come in through the airlock, soldiers between B1 and a raised core seal get it lowered (`unseal`, the SIEGE state). STRANDED's rescue waits while a wave moves B1 or O1 (muster, open, back, stray) or a sortie runs (they own B1); during the fight it runs as usual. Kernel cost: no new scans; zones and danger ride on sense's hostile pass, the idle checks read military's KPI at most every 300 ticks and the squads' positions every 100.
- **Destroyed bridges and the deep defense (BUG-030, Run 10 y421: 58 goblins and 6 trolls destroyed O1, B1 and B2; 19 recruits at the melee and gallery stations between O1 and B2 died first, then 40+ civilians in the main hall; the kernel kept pulling the bridges for nine days).** gate remembers the building of every manifest bridge it saw complete on its footprint (`m.gate.seen`); when that building is gone and the footprint holds no bridge any more, the bridge is destroyed: BRIDGE_DESTROYED (A, once), its want, pull and move record dropped, no want accepted, no GATE_FAIL, state `bridges` `destroyed`, `inspect defense` `destroyed`, the audit snapshot draws the footprint as the tiles are; `gate.state` answers `unknown` (readiness' `bridge:B`) plus the destroyed tick; the footprint is looked at once a game day (a complete bridge there again: `rebuilt`). siege treats it as an open way: no raise hold, cut check or STRANDED for it, a destroyed O1/B1 in SIEGE is BREACH at once (why `destroyed`), no BREACH → SIEGE while one is gone, RECOVERY counts it as lowered. **Deep defense (plan B), SIEGE only:** building destroyers in sight (sense `census.h.bd`: the caste flag or `caste_raw.misc.buildingdestroyer`; latched for the episode), visible hostiles > `stations.core_ratio` (3) × soldiers, or weak squads (worn < `stations.worn` 60 %, iron/steel share < `stations.metal`, 0 = off): the civ alert confines to the separated refuge at seal's BREACH level (BUG-018/019: separated, no supply counts for `refuge.breach_days`; seal keeps the refuge afterwards until `back_days` are quiet), every squad, crossbows too, at the core station (posture CORE: `stations.core`, fortcore's core hub next to the civilians' stair one level below B2, else `stations.b2`), no kill orders (they would draw the crossbows into the gallery and the field), no intake wave (INTAKE refused `deep`; a wave already out ends by its rules); SIEGE_DEEP (A) names the reasons and the destroyers, again only with a new reason or race; `army`/`weak` release after 2,400 ticks without them; RECOVERY, PEACE, ALERT end it, BREACH keeps it. State `wave.deep`. Kernel cost: no new scan.
- **Sortie through O1** (inbox `squad.sortie` with `gate`, approved; SIEGE only; `m.siege.so`): the reply compares the squad's combat value with the visible hostiles within `sortie.near` (10) tiles of the target × `foe_cv` (10) and refuses below it or below `sortie.worn` (80 %), with a wave, a rescue, a hostile in the area or past B1, a danger or civilians in the area. `gather` in the bailey (`stations.bailey` or the Z1 centre; military holds the order through every posture): B1 down while somebody still has to come through, up once all are there; `open` O1 down; `out` kill order on the hostiles near the target; recall on losses (WAVE_FAIL), no target left, `max_ticks` (2,400), a danger; `recall` O1 up once all are back in the bailey, or at once with a hostile within `gate.force_near` of O1 or after `max_ticks` (WAVE_FAIL left_outside names them; GATE_FORCED if one stands on the footprint); `home` released, B1 down until they are in, then up; SORTIE (B) per phase. Never O1 and B1 down at once while hostiles are visible.
- **Exit to RECOVERY** on **visibility, never on path existence** (a raised bridge cuts the walk groups, so "no path" means nothing during a siege). Then, on quiet time: +0 training resumes; +1,200 B2 then B1 down and alert off, traps reload, captives hauled to the pit, visible corpses within 15 tiles of the approach dumped then buried; +2,400 O1 down; +8,400 PEACE and SIEGE_END (A). Any visible invader sends the FSM straight back to SIEGE (raise, same invariant).
- **ALERT exit:** 1,200 quiet ticks.
- **DRILL** is SIEGE without enemies. It runs the real routines, real lever pulls and real burrows. At T+1,200 it records the KPIs of §5.4, then lowers the bridges with the same invariant.

## 5. Doctrine encoded
**5.1 Site and embark** (checklist read from the vanilla embark screen and finder only; port of `tools/embark`):
- **Site:** ≥10 world tiles from any goblin Dark Fortress and from the 5 old fort sites. Evil neutral or good, savagery low or medium. Trees and flowing water. Aquifer none (light only with the probe protocol; heavy rejects the site). A metal ore listed and a hard stone layer within reach, read from the panel's layer lines (Run 9 postmortem lesson 1: no metal ore or deep soil rejects the site; a failed criterion passes only with a logged `--accept ID --reason`, FR-08). Flux if shown. Temperate. Embark 3x3 or 4x4.
- **Spend all points:** 3 picks, 2 axes, an anvil, bars, wood, plump helmet and surface seeds, 1-2 breeding pairs.
- **Starting skills:** 2 miners, mason/engraver, carpenter, brewer/grower, mechanic, cook/doctor.

**5.2 Fortcore template** (the doctrine geometry, parametric only in anchor, rotation and depth).
- **Zones:** Z0 outside → **O1** (3-wide drawbridge, 2 levers inside) → **Z1 bailey** (walled, 2-tile overhang, depot) → **Z2** trap hall (1 wide, ≥40 tiles, ≥3 bends, weapon traps with ≤10 components plus stone-fall filler, **no cage traps on the main path**), then a 7x7 killing field with a roofed gallery behind constructed fortifications on the same level, reachable only from Z3 (live L2: a gallery at z+1 is never dug, because DF does not dig the hidden tile above an up stair) → **B1** inner bridge (2 levers) → **Z3** gatehouse and barracks (racks, stands, chests) plus the military stair → **B2** core seal → **Z4** civilian core (civilian stair, farms, workshops, stockpiles, well, hospital with its own water, tombs, dining, bedrooms). The **Tiefe+** refuge sits ≥3 z below the core with its own well, food and beds.
- **Burrows and manifest:** `#burrow` sections for `Kern+` (Z3+Z4) and `Tiefe+`, plus a manifest fragment (bridges→levers, stations, killboxes, edge, refuge anchor, stairs).
- **Stages:** 1 (P0-P1) tunnel, 2 stairs, workshops, dorm, farms, well, depot; 2 (P2-P3) killing field, B1, barracks, gallery; 3 (P5) O1, B2, refuge; 4 (P6) the 41 traps of the hall (live L2: traps inside stages 2-3 took every mechanism before the levers, and their weapons need metal). Outer natural walls are smoothed (unclimbable).
- **Outward gallery `gallery_o1` (Run 10, 2026-10-16).** In a siege O1 stays up and the army waits in front of it for weeks (Run 10: 47 goblins); the inner gallery covers only the killing field, so nothing could hit them. `gallery_o1` (`dfpilot/bp/defense.py`) is a separate template placed in the O1 frame: anchor = the centre of the O1 footprint at ze, the fortcore's rotation (`bp sites gallery_o1` derives both from the manifest: the inner gallery station and the bailey Z1 of stages 1-2, checked against the O1 bridge once stage 3 lists it; it needs the O1 tunnel and the inner gallery dug). Geometry (fortcore local, ze): the east wall of the tunnel in front of O1 (u 2, v 4..6) becomes constructed fortifications (`CF`); behind it the gallery strip u 3, v 4..6 (station: its middle tile), roofed by the rock of w -1; a 1-wide corridor east to u 8 (one rock column beside the trap hall, as between the hall's own runs), south along u 8 and west into the north end of the inner gallery (5, 26). The outer gallery is reached only through the inner gallery, i.e. from the military stair alcove in Z3: never from outside, no door, ramp or stair. **Stage order is the safety argument:** `g1.dig` digs the three F-line tiles from the tunnel (outside O1, an alcove of the attack path), `g1.build` builds the fortifications from the tunnel side (the tiles behind are still rock: no builder is shut in), `g2.dig` digs strip and corridor from inside, `g2.unburrow` takes them out of every burrow (the burrow plugin grows `Kern+` over dug tiles; civilians on alert must not idle where bowmen outside can shoot through the fortifications). At no point does an open tile join the tunnel to the corridor; a fortification stage that never finishes leaves the corridor undug. Occupancy ignores the fortcore tiles it is built against (`bp.emit.ATTACHED`). Manifest: one room `{tpl: gallery_o1, use: utility, bbox: strip}`; `topo.audit` fails `gallery_o1: reachable without passing Z3` (a new way in), `not roofed`, `no fortification faces the O1 approach` (no F tile between a gallery tile and an attacker tile within 6 of the outer bridge), `not dug`; the room closure check skips it. `dfllm plan check` warns from P5 on (the phase that builds O1) when the fort has or builds a fortcore O1 and no `gallery_o1` is planned, applied or in the manifest. **Use:** in a SIEGE with the army waiting in front of O1, the crossbow squad goes there by `squad.sortie {squad: C, target: [x,y,z] of the strip's middle tile (centre of the room bbox, inspect what=manifest), approve: true}` (ask the player first; the kernel's READY_STATION posture still sends crossbows to the inner gallery). Open (kernel, not in this change): a manifest station for it (schema) and a posture that stations squad C there while hostiles wait outside O1.
- **Seal `seal` (Run 10, 2026-10-16).** Closes the open ways in that `inspect entrances` and SIEGE_UNREADY list (`x,y,z kind`, live: `90,109,125 ramp`, `53,126,127 floor`, `95,127,123 floor`) with one piece each, by quickfort `#build` with buildingplan materials: a **door** on a floor-like tile (the lockdown forbids it like every entrance door), a **constructed wall on the ramp top** above a ramp (a ramp carries neither door nor wall: quickfort builds constructions only on floor, open space and ramp tops; the wall cuts the ramp's way up and down), a **hatch** on a stair (it covers the stair's floor); `close=wall` puts walls on floors (what the worst-case audit counts), `close=grate`/`bars` wall grates or vertical bars on floors and floor grates/bars on ramp tops (walkers blocked, water and air pass); a piece per opening overrides it (`x,y,z floor wall`). Params: `at` = `x,y,z[ kind[ piece]];...` (absolute, at most 6) or `last` (the default in `dfllm cmd`: the open ways in of the newest SIEGE_UNREADY, else `state.ready.ents`), `audit` (the walls the newest audit names, §5.4 audit findings) or `all` (both); the CLI takes each kind from the newest snapshot (the shape there wins) and leaves out what it shows closed. The site is the first opening (any rotation); a seal is never refused for touching another project (it builds only on open tiles), but its tiles keep later projects off. `bp sites seal` refuses a hidden tile, a tile whose shape no longer matches (closed already) and a ramp whose top is not open space. One `seal:piece` line per piece goes to `cli.log` (and to stdout of `dfllm cmd`): `90,109,125 ramp: wall at 90,109,126 (the ramp top)`. **Run 11 (Kilrudrabed, y429):** `at=last|all` gave the same door 125,103,144 on every repetition (its seal was pending, then the entrance check reused an old answer) and never the new leaks (188,103,144 floor; `124,81,138` open route without a roofed tile; shrubs and saplings at 188,88,144 and 177,99,144). `at=last` now takes the current open ways in (`cmd.current_openings`): the newest SEAL_LEAK unless a newer SEAL check read the fort sealed (a **wall**, since walk groups pass doors; RULES §7), the entrance check (newest SIEGE_UNREADY `ents`, else `ready.ents`) and a current REFUGE_FAIL's `open` entrances (while `alert.ok` is 0 or `alert.ref.sep` 0); like `at=audit` it leaves out openings a seal project builds (not done) or built (done, unless a snapshot taken after it shows the piece gone), at most 6 per seal (the next one takes the rest); one `seal:note` line per opening left out or moved. No piece stands on a plant: a **shrub** gets the player's gather-plants designation (quickfort `#dig p`, stage `seal.clear`) and its piece after it (`seal.plant`); a tree tile (branch, trunk_branch, twig) the chop designation (`t`; the felled tree takes the branches, no piece); a **sapling** is no tree yet (quickfort's `t` marks tree tiles only, no player designation removes it), so like a door/hatch the route passes beside or another building on the opening it gets the **neighbouring tile that closes the same route** (`bp.topo.SealGeo.neighbour`: in a 7x7x3 window, doors, hatches and bridges closed, no climbing, the opening's own entries (roofed tiles beside open sky within one tile, and those touching them) open and the other entries shut, the first neighbour, orthogonal first, whose blocking cuts the open sky from the roofed rim); the text names it `N kind for=O:kind`. An **open route without a roofed tile** (the citizen at `pos` stands under the open sky) gets a wall on the first of the first 8 floor/ramp tiles of its route to the snapshot border whose wall leaves him no way to the border with ≥ 12 roofed tiles on his side (`SealGeo.route`; a citizen in the open field gets none). Open sky is approximated from the snapshot (every tile above is open space; a tree crown counts as a roof); plants come from snapshot marks `shrub`/`sapling` (roofed ones first, ≤ 500 each, both always written). Never DFHack `plant remove` (no player action). BUG-031 (main 7e02aa7) made REFUGE_FAIL carry `fix` (the `at` for the tiles beside a door that leaves them open) and `entrance_doors().open` list those tiles: `at=last` takes a REFUGE_FAIL's `fix` as given. **`at=refuge`** = the refuge's own pieces: a **hatch on the civilians' stair one level above the refuge** (`cmd.refuge_head`: the manifest refuge anchor and the `stairs.civ` column down to it; fortcore's Tiefe+ hangs below Kern+ on that stair without a door or hatch, so whatever reaches Kern+ reached it; the hatch is a closer for seal's refuge flood, and walkers pass it) plus the current REFUGE_FAIL's `fix` tiles; `at=all` includes the stair head.
- **Validator** (offline) rejects a single stair, a shortcut bridge, a refuge on the attack path, doors counted as barriers, diagonal leaks and unclosed rooms.

**5.3 Military.**
- **Squads:** A and B melee, C crossbows, each ≤10. Size is 15 % of adults at pop ≤55 and 20 % from 60 (D-12), with ≥8 soldiers for readiness level R2.
- **Routines:** Constant training, never Off duty. Minimum soldiers per order = half the squad.
- **Setup [S2]:** routines are configured once, resolved by **name**, and verified on a backup save. At runtime only `cur_routine_idx` and the orders change.
- **Uniform:** Replace clothing, full metal armor plus shield. Bronze and bought metal in Y1, iron and steel in Y2 via `library/military`. Goblin gear is melted through a `logistics add melt` pile.
- **Recruits** are chosen read-only. Excluded: members of the builtin Miners, Woodcutters and Hunters details, sole holders of a key labor, nobles. Preferred: existing combat skill, then strength and toughness. military writes **no work details**: economy owns the tool details (it never picks soldiers and drops a member who joins a squad), labormanager the rest.
- `autotraining` only runs a geared need-squad that is never drafted. No civilian squads.
- **KPIs:** worn % (items worn ÷ uniform slots, measured at T+1,200 of a drill), combat value (weapon + shield + armor + dodge skill levels).
- **Stations (BUG-029, Gordon 2026-10-16):** a squad stands outside B1 only during an intake wave (INTAKE: `stations.field`, the gallery) or an approved sortie; otherwise at the inner station on the side with the drink (READY_IN / STATION_B1: `stations.melee`, `stations.b2` while the core seal is up). **Core stations (BUG-030):** in the deep defense (building destroyers in sight, an army > `stations.core_ratio` × soldiers, weak squads) every squad stands at the core station (CORE: `stations.core`, else `stations.b2`), never in the corridor or the killing field, while the civilians go to the separated refuge (§4). Flasks are not set: `act.squad_uniform` has no supplies setting and the squad's carry fields are unverified for 53.16 (live probe first); on the inner station a soldier's own drink and food breaks (DF, bounded by the routine's minimum soldiers per order, set once in the UI [S2]) reach the stock, so no explicit drink rotation is run.

**5.4 Readiness gate.** Only readiness raises max-pop.
- **R0:** cap 55.
- **R1 "sealed":** the audit passes (with all bridges *lowered* and doors open, removing the trap-hall tiles leaves no edge→Z3 path; the refuge is reachable from the core without Z2/Z3; civilian path ≠ attacker path; caverns sealed), Kern+ and Tiefe+ exist, and every manifest bridge has 2 levers.
- **R2 "grow to ≤75":** R1, plus a drill passed ≤100,800 ticks ago (bridges up ≤T+900, worn ≥90 %, nobody outside at T+1,200, 0 double toggles), soldiers ≥15 % of adults and ≥8 with combat value per soldier ≥ `plan.cv_min` (default 12), ≥30 armed traps on every attacker path, food ≥60 days and drink ≥170 days.
- **R3 "≥80":** D-01 = Option B and ≥20 % of soldiers wearing iron or steel.
- **Demotion:** readiness red → max-pop frozen at the current population and beauty pauses. The S10 read of the difficulty siege triggers sets the R2 ceiling at trigger − 5, leaving margin for births and visitors.
- **R0 → R1 blockers** (state `ready.fail` at R0, `status` line `SIEGE UNREADY (R0): …`, event SIEGE_UNREADY; `lua/dfllm/readiness.lua`):

  | Token | Means | First fix |
  |---|---|---|
  | `audit` | no audit result yet. readiness exports an audit snapshot monthly and after defense stages (only once the manifest has geometry); follow's audit job turns it into the `audit` verb | keep `dfllm follow` running (`--no-auto` keeps the audit) or run `dfllm audit` |
  | `audit_old` | the last audit is older than a season (100,800 ticks) | the same |
  | `audit_fail` | `bp.topo.audit` said ok=false; its own reasons are the AUDIT event's `fails` (SIEGE_UNREADY `afails`), e.g. `manifest: no Z2 trap hall`, `stairs: need a civilian and a separate military stair`, `levers: B1 has 1 lever(s), needs 2` | fix what they name, then `dfllm audit` |
  | `bypass` | with every bridge lowered and every door open, a path from the map edge (or the snapshot border) reaches Z3/Z4 without crossing the trap hall Z2, or there is no Z2 | wall the extra ways in; doors count for nothing |
  | `refuge_sep` | no walkable refuge (`manifest.refuge.anchor`), or it is not reachable from the core Z4 without Z1/Z2/Z3, or attackers reach it without passing Z4 | fortcore stage 3 refuge (Tiefe+), a dead end below the core |
  | `civ_sep` | no civilian plus a separate military stair (≥ 2 tiles apart), the civilian stair inside Z1/Z2/a kill box or on the attack path to Z3, or core → refuge needs attacker zones or the military stair | fortcore stairs |
  | `caverns` | a cavern tile is reachable from Z3/Z4 | 2-wall airlock (§10) |
  | `no_kern`, `no_refuge` | burrow Kern+ / Tiefe+ (manifest roles `kern`/`refuge`) missing | fortcore stages 1 / 3, or the burrows screen |
  | `no_outer`, `no_inner` | no manifest bridge of role `outer` (O1) / `inner` (B1) | fortcore stage 3 / 2 |
  | `bridge:<B>` | gate cannot read manifest bridge `<B>` (not built yet, or destroyed) | build it (again) |
  | `levers:<B>` | fewer than 2 levers linked to `<B>` | build the levers; gate links built ones in PEACE |

  R1 → R2: `drill` (no passed drill), `drill_old`, `redrill` (a siege since the pass), `army<N%`, `soldiers<8`, `cv<N`, `traps<30`, `food<N`, `drink<N`, `military?`/`food?`/`drink?` (no number yet). R2 → R3: `option_a` (D-01), `metal<20%`. A fort without the fortcore manifest stays R0.
- **Audit findings** (`bp.topo.audit` `fails`: `dfllm audit` prints them, the AUDIT event keeps 8, SIEGE_UNREADY `afails` 3, each cut to 60 characters by readiness). Every route is the worst case: all bridges lowered, all doors and hatches open, so a door never fixes one. Since Run 10 a route finding names the wall that closes it (`bp.topo.choke`: on the part of the route after it leaves the fort's attack side, walking back from the target, the first tile outside the fort's own geometry that takes a constructed wall and whose wall closes every such route; `(+more)` = it closes this route, others remain). The seal template builds these walls: `dfllm cmd bp.place tpl=seal site=S1 at=audit` (or `at="x,y,z floor wall"`), then `dfllm audit`.
- **Bypass gate (Run 10, 2026-10-16):** `bypass: edge->Z3/Z4 avoids the trap hall (reaches 139,128,117)` stood in every audit for months, the plans kept growing the fort and the 41 traps stayed unused. Now an audit route with a wall tile is closed by itself: (a) readiness (R0 already, `bypass`/`refuge_sep`) publishes the first route finding as `ready.route` and SIEGE_UNREADY names it with `(fix: seal at=audit)` (`(no wall tile: inspect entrances)` without one); `status` prints `audit route: ... | next: wall it: dfllm cmd bp.place tpl=seal site=S1 at=audit`. (b) follow (auto, not `--no-auto`) reacts to each AUDIT event: in PEACE, the walls of the newest audit that no seal project builds yet get `bp.place {tpl: seal, site: S1, p: {at: audit}}` (the follower's placement path, like tombs; a player's blueprint, fair play). (c) `dfllm plan propose` drafts `{"tpl":"seal","site":"S1","p":{"at":"audit"}}` as the first new build (the current season; seasons[0] of next year's plan), and `dfllm plan check` makes it an ERROR to raise phase_target above the current phase or to add other builds unless a new build due now is a seal with `at=audit`/`all` or naming every open wall tile. "Builds it already" (`cmd.audit_routes`): a seal project in `bp/` names the tile and has not finished before the newest audit (a seal done before an audit that still names its tile counts as gone and is placed again); `seal at=audit` leaves such tiles out, so no tile gets two seals. A route without a wall tile, or with its seal pending, only warns (no plan build can fix it); readiness stays R0 until the next audit passes. Source of the findings: the newest AUDIT event (SIEGE_UNREADY `afails` if newer), else `state.ready.route`.

  | Finding | Means for the player | What to build |
  |---|---|---|
  | `bypass: wall x,y,z floor -> X` | attackers reach Z3/Z4 at X without crossing the trap hall; this floor tile is where their route enters the fort | a constructed wall on x,y,z (seal `at=audit`) |
  | `bypass: wall x,y,z ramp -> X` | the route climbs the ramp at x,y,z | a wall on the ramp top (z+1); the seal does that |
  | `bypass: edge->Z3/Z4 avoids the trap hall (reaches X)` | the same, but no tile on the route takes a wall (stairs, doors, bridges, or it runs on the attack side) | look at the route near X (`inspect entrances`); remove the stair/door or wall the corridor beside it |
  | `refuge: on the attack path, wall x,y,z kind` | attackers reach the refuge (Tiefe+) without passing the core Z4; in Run 10 the same tile also opened Z4 up the civilian stair | the wall on x,y,z |
  | `refuge: on the attack path (reachable without passing Z4)` | the refuge itself lies on the attack side | a new refuge (fortcore stage 3), never on Z1/Z2 |
  | `refuge: none ...` / `refuge: not reachable from the core without Z1/Z2/Z3` | no walkable refuge anchor / the civilians would have to walk through attacker zones | fortcore stage 3 |
  | `stairs: ...`, `civ: core->refuge needs attacker zones or the military stair` | one stair for everybody, or the civilian stair on the attack path | the fortcore stairs |
  | `caverns: open to the fort at X` | a cavern tile is reachable from Z3/Z4 | a 2-wall airlock (§10) |
  | `gallery: ...`, `gallery_o1: ...` | a gallery reachable from outside, unroofed, not dug, or facing nothing (§5.2) | rebuild its fortifications/roof |
  | `levers: B has N lever(s), needs 2`, `levers: a lever of B is outside Z3/Z4`, `bridge B: footprint is not a bridge` | the bridge cannot be raised from inside | build the levers/bridge |
  | `cage trap on the main path at X` | caged invaders get freed by their comrades | replace it with a stone-fall trap |
  | `no attack path with bridges lowered`, `manifest: ...`, `edge: ...` | the snapshot or the manifest is incomplete (nothing to judge) | `dfllm audit` again after the stage is done |
- **Refuge gate (Run 10, 2026-10-16):** Tiefe+ was never usable (beds 8 < 27, open to the entrance 95,127,123, 58 steps), Kern+ lay on the attack path, and at pop 110 the fort had no safe room. seal publishes the refuge burrow's audit as state `alert.ref` = `{ex, sep, beds, need}` (exists; separated 1 / an opening reaches it without door, hatch or bridge 0 / not known yet −1, BUG-018; beds inside it; `need` = ceil(citizens × `refuge.bed_pct` / 100), the bed rule of the civ alert). `dfllm plan check` refuses phase_target P3+ (ERROR) unless the refuge exists, is separated and has `beds ≥ need`, or the plan's new builds (or projects under way: bp files without PROJECT_DONE, `state.proj` `s3.*` of adopt's fortcore) fix the gap: no refuge → fortcore stage 3 (O1, B2 and the refuge; its beds and doors are judged once it exists); `sep` 0 → a seal (`at=last`: doors on the open ways in, or walls); beds short → `refuge_beds` rooms whose `n` add up to the shortfall. `sep` −1 and a state without `alert.ref` (an older kernel) only warn. `dfllm plan propose` drafts these first, right after the audit's seal. **Run 11 (Kilrudrabed, pop 54):** the refuge stood open (REFUGE_FAIL `Kern+: open to 1 entrance 127,121,143 Door (62 steps)`) and short of beds while the plans went on with P1 work, so the gate holds **from the fort's start once the refuge burrow exists**: below P3 a plan that raises phase_target or adds builds is refused (a plan that adds nothing gets warnings) unless the seal (`at=last`, also for the entrances a current REFUGE_FAIL names: `fort.refuge.open`) and the missing `refuge_beds` come no later than its first other new build; at P3+ the same ordering applies. The refuge seal is `{"tpl":"seal","site":"S1","p":{"at":"refuge"}}` while it has something to close and the stair head lacks its hatch (`fort.refuge.head_open`, an ERROR like the others; only a seal at=refuge/all or one naming the tile fixes it) or the refuge is open; else `at=last`. Nothing is asked that no build can give: a seal while `seal at=last` finds nothing to close (`seal_n` 0) and, below P3, refuge_beds without a site (no fortcore refuge room yet: `bed_site` false) are warnings; below P3 a missing refuge is no gate (fortcore stage 3 belongs to P5). **`refuge_beds`** (`rooms.refuge_beds`, params `n` 2-30, `burrow` Tiefe+): a room dug from a floor tile of the fortcore refuge room into the rock (`sites.rank`: anchors only there, no lever tile; the footprint and its 1-tile wall ring must be rock or unknown, so it opens no way in; it keeps off the attack zones like every room), a door in the doorway, beds in rows beside a centre aisle, a dormitory zone, painted into the refuge burrow; it never joins Z4 (a Z4 box beside the refuge would let the audit's core → refuge check start next to it) and is private (no room opens from it).
- **Traps (`min_traps`, status `traps N`):** the armed traps (weapon and stone-fall, `armed` in the snapshot: not
  resetting) an attacker meets on the cheapest route to Z3/Z4, counted as entered tiles (a diagonal step cuts a bend: the
  fortcore hall's 41 traps read 35). Run 9 (46 traps) and Run 10 (41 stone-fall traps) showed `traps 0`: the audit's
  minimum took the bypass it had found, which meets no trap. With a bypass the count is now taken as if the walls its
  findings name stood (up to 4 routes closed one after the other; if that does not close them all it stays the plain
  minimum, 0); without a bypass it is the plain minimum over every route, so the R2 rule (≥ 30 on every attacker path,
  read only while R1 is green) is unchanged. A way into the hall's trap-free end (no bypass, R1 green) still reads 0:
  `dfllm audit` prints `traps: (41 of 41 armed traps in the trap hall; the counted route enters the hall at x,y,z)`,
  follow logs the same; status adds `(counted as if the bypass were walled)` / `(a bypass skips the hall)` at R0 and
  `(dfllm audit: where the cheapest route enters the hall)` while `traps<30` blocks R2.
- **Siege readiness gate (FR-65):** while R0 fails in PEACE, readiness emits SIEGE_UNREADY (A): the blockers, the ways in without a door or bridge from seal's last entrance check (`x,y,z kind`), the last audit's trap count and its own fail texts; first 2 days after a load at the earliest, then after a game month and 30 real minutes (10 when a blocker or an open way in is new; `util/cadence`). `status` never shows a plain PEACE then: line 1 reads `PEACE UNREADY`, line 2 `SIEGE UNREADY (R0): … | 2 ways in without door or bridge: … | traps 0 | next: …`.
- **Drills** start by themselves (drill.lua: the first one, yearly, every season while the plan wants R2, after a siege, retries after a failure), only in PEACE without merchants, ≥ 2 days after a load, with an outer/inner manifest bridge, phase ≥ P5 and soldiers. `drill.hold()` names what is missing (state `ready.dhold`; `status`: `drill never (auto: no bridges; run dfllm cmd drill)`); `dfllm cmd drill` runs one by hand in PEACE (without bridges it fails `no_bridges`, but it exercises the alert and the squads).

**5.5 Economy and labor.**
- **Baseline on adopt and on every load:** `control-panel enable` for the native list in §3; `prioritize -a defaults`; autochop with wood ≥14; autobutcher with low targets and ≤2 cats; `tailor materials silk cloth yarn`; `pop-control set max-pop 55` and `wave-size 8`; `labormanager mode monitor`.
- **Staged orders imports:** `library/basic` after the first migrants, `rockstock` once a mason exists, `furnace`/`smelting` with a smelter and fuel, `military` with a forge, all followed by `orders sort` and `orders recheck`.
- **labormanager:** monitor is the default. After 2 seasons in monitor mode an A/B test switches to `modern` + `balance balanced`; it compares the share of days with starving postings [S5]. Live L1 measured modern worse on Castlerisen (2,637 starving postings vs 758 in monitor; BREWER starved 243 cycles while dwarves died of thirst), so modern runs only behind the LABOR_STARVED fallback: a starved supply labor (≥ 100 cycles, about 2 game days at labormanager's cadence) switches back to monitor at once and ends the A/B test. That makes modern safe to try but not better: monitor stays the default until a fort measures modern better.
- **Tool details (live L1b):** in monitor mode economy is the sole writer of the builtin Miners/Woodcutters/Hunters memberships (`act.work_detail`, the work details screen): miners = clamp(ceil(dig backlog / 40), 2, 4 from pop 20 else 2) where the backlog is `runner.dig_backlog()` or the designation jobs, whichever is larger; woodcutters 2 below 60 logs, 1 below 150, else 0; hunters 2 during a famine or the food_low pre-alarm (Run 11), else 1 in PEACE from P1 while bone, shell or leather is below the mood stock (live L3: 0 of each, 9 of 10 moods failed); fisherdwarves one per 15 citizens (max 3) while food is short and a fishing zone exists, never outside PEACE/RECOVERY (live L5); every count capped by usable picks, axes or bows. Growth is immediate, shrinking waits 3 days. A dwarf is in at most one tool detail. In modern mode labormanager manages them itself and economy writes nothing.
- **KPI:** starving postings = 0, parsed from `labormanager status` once per game day.
- **Idle (D-03):** act only if idle >40 % for 3 game days **and** the useful backlog is not empty. The backlog holds boulders→blocks (capped), walls and overhangs, smoothing of *used* rooms, capped trade crafts, and `combine`. Never filler digging.
- **Cancel-loop detector:** an order cancelled ≥5 times per day is suspended and reported (Run 4).
- **Wood for rock furniture (live L3):** quickfort `orders` always orders doors, cabinets, coffers, coffins, tables and chairs in rock. Below 20 boulders economy re-enters open one-time orders of these jobs in wood (`act.order_material`, the work orders screen's cancel + re-enter) while logs beyond 30, minus the wood already ordered for them, cover the amount (Castlerisen: 43 buildings waited two years with 8 boulders and 82 logs).
- **Supply alarm thresholds:** thirst 40,000 and hunger 65,000 ticks, 10,000 before DF's "dehydrated" (50,000) and "starving" (75,000); DF's plain "thirsty"/"hungry" made the brake flap (live L1b, L3).

- **Ore search as a plan goal (Run 10, Handlelock: iron stuck at 8 bars for years, three caravans a year brought none, 20 soldiers at 38-53 % worn).** economy's metal route is `explore` while the fort holds no metal ore boulders and the soldiers' metal slots want more bars than it has (`gear.bars_short`) or the bars are below the mood stock (the old rule waited for 0 spare bars and never fired); it asks seasonally (PROJECT_REQUEST explore, B) and yearly (DECISION_NEEDED metal) and publishes state `stock.ore/bars/metal`. `dfllm plan propose` then drafts the `explore` template (`bp/mine.py`: a 1-wide stair shaft `depth` levels down from the deepest public core floor, side tunnels of `arm` tiles W/E/S every `every` levels and at the bottom) as the first new build of every season from the current one, and `bar:iron` in `trade.want`; `plan propose` fits `depth` (12, 9, 6, 4, 2) to the levels the sites ranking must avoid. Fair play: the ranking sees revealed tiles only; the shaft never reaches a level in `p.avoid` (absolute z the player knows as aquifer, from the embark panel's light aquifer and the miners' damp stone) or a level with a revealed cavern, damp or warm mark, never starts on or below the refuge level, and the runner stops it at a damp, warm or cavern report like every dig. **Cavern breach (Run 11, Kilrudrabed: the shaft 136,73 broke into a cavern lake of 1146 visible water tiles on z127 and was reported as `damp`; Run 3 fell to forgotten beasts through an opened shaft):** a damp/water/cavern stop is held against the revealed tiles at the breach (`runner.opened`): a connected body of ≥ `lake_min` (30) revealed water tiles outside the project's own tiles with a revealed cavern tile (or none of it under the open sky) is `cavern_lake` (on the surface: `water`), a revealed cavern tile beside it `cavern`, else it stays damp (aquifer seepage); a stop from before (or a lake that shows later) is looked at again daily. An explore shaft open to a cavern is plugged at once by a `plug` project (prio 1, every mode, never stopped by a hazard): its top stair tile and the one below get a constructed wall each, a stair channelled into open space first because walls cannot stand on stairs (quickfort `is_valid_tile_construction`); the lower one is built first (reached through the upper one) and given up when a step of it waits a day; CAVERN_PLUG (A) names the shaft and the walls (`queued`, `done`, `failed`; `none` for other templates, whose stairs may be the fort's own: by hand). Until the top wall stands readiness keeps R0 `caverns` (`runner.cavern_open`) and threat counts hostiles within 30 tiles of the open shaft below the fort's z band. `dfllm plan check` refuses a plan with neither an explore build nor a `bar:*` want while the ore goal holds (state `stock.ore` 0 and `stock.metal` explore, or worn < 80 %), and warns when only the trade want covers it.

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
- All 12 moodable workshop types in **P1** (live L1b: two dwarves died after fey moods failed for want of a workshop): fortcore stage 1 builds carpenter, mason, craftsdwarf and mechanic, the `workshops` template the rest (it skips the types the fort already has or has planned). The deliverable counts the manifest and every built workshop.
- A mood stock of cloth, leather, bone, shell, gems and bars ≥10 each from P1 on (STOCK_LOW per key, a cloth supply order).
- On MOOD_START, care unforbids and un-dumps the needed materials and emits MOOD_NEED if a material is missing.
- `act` has **no** job-removal function except `cancel_own_lever_job`. Lint enforces this.
- **Leather as a goal (Run 10, Handlelock: a fey mood died for two leather; no tannery stood, the hunters had no bolts).** economy keeps a standing floor of 2 leather against its own leather gear (`reserve.leather`), remembers every class care's `mood_wants` named for a year (`leather.memory_days`, state `stock.mood_miss`), hunts like an open need while such a class is leather and the fort has none (through the no-game pause, capped by crossbows and bolts) and, without a tanner's shop while hides lie or a mood missed leather, asks for the `workshops` project (PROJECT_REQUEST why=tannery, follow places the missing shops; every 14 days at most). MOOD_RISK names the route (`economy.route`: `route leather: no tannery (asked), hunt: no bolts, butcher, trade.want leather`); `plan propose` puts `leather` first in `trade.want` and `plan check` warns without it.
- **Glass for moods (Run 11, Kilrudrabed: no gem vein; every year the first mood that wanted gems died).** Raw glass serves a glassmaker's base and the extra raw glass, cut glass the extra "cut gems" (SMALLGEM of any material); no glass serves rough gems, bars, blocks, leather or cloth (`reserve.glass_ok`, DF's mood rules). economy's glass chain (`economy.glass`): a mood wants raw glass or cut gems, or no natural gem lies in the fort while a mood missed gems within a year or (from P3) the gems are below the reserve's gems target: PROJECT_REQUEST workshops why=glass (no glass furnace or jeweler's), one 1x1 sand collection zone on a revealed sand floor (snapshot's `sand` marks; act.sand_zone), ConstructBag from spare cloth/leather, charcoal (no magma glass furnace), then CollectSand, MakeRawGlass and CutGlass (green glass); GLASS_BLOCKED (B) once per set of blockers (no sand revealed, no bags, no fuel); MOOD_RISK names the route (`route gems: cut glass: ...`, `rough gems: mine a gem vein or trade.want gem (glass is no rough gem)`).
- **Mood survival (FR-44, Run 9: a Possessed dwarf without materials died of thirst at 75,001).** When the needs of a mood are first known and any is missing, care raises MOOD_RISK (A) with the missing classes; when the moody dwarf passes thirst 30,000 or hunger 50,000 it raises MOOD_RISK again every 2 days. **Decision:** care never cancels the mood job. The UI has no cancel for a strange-mood job (the claimed workshop cannot be removed either), act has no job removal, and a removed job crashed DF in Run 9; the loud event asks for the material instead.

**5.10 Burial.**
- One 1x1 tomb zone per coffin, with free tombs ≥ open corpses + 6; otherwise care requests a `tombs` project (without the coffin provisioner below).
- **Coffin provisioner (FR-61, Run 9: 25 unburied, `243 coffins, 0 free`, `no_coffin 22`, soft sedimentary stone that made no coffin; Runs 8 and 9 were lost to unburied dead and ghosts).** Care keeps free usable coffins ≥ unburied citizen bodies without a usable tomb + `coffin_reserve` (10). Slots = free + planned (unbuilt) + built unzoned coffins; for the slots missing it searches dug space that stands in PEACE (no tombs project pending, `coffin_retry` after a failed search or a placement): around the crypt, the core (Z4) and the citizens, the seed level and one up and down, `coffin_scan_r` tiles each way, revealed floor (snapshot.tile) without a designation, building, zone or stockpile, roofed (snapshot.outside_near), on the citizens' walk group (snapshot.far) and farther than `coffin_entrance_r` from the entrances (seal.entrances, manifest approach). In free rectangles of at least 4x4 it lays rows of coffins with an aisle every third line inside a free one-tile ring (ways through the hall stay open), the smallest fitting rectangle nearest the seed first, at most 4 rectangles and `coffin_batch` coffins, queued through `runner.coffins` (coffins, then 1x1 tomb zones; no quickfort orders). No space: `PROJECT_REQUEST tombs why=no_space` (follow digs a tombs room) and DECISION_NEEDED `coffin_space` after `coffin_wake`. Planned coffins get ConstructCoffin orders (`act.workorder`, tag `dfllm:coffin`) for the items missing beyond free coffin items and open orders that can run: non-economic hard stone with a mason's workshop (masons refuse soft stone such as chalk, mudstone, shale and claystone for furniture: economy's census `rock` minus ores, flux and `rock_bad`), else wood beyond `coffin_wood_keep` logs with a carpenter's workshop; neither: DECISION_NEEDED `coffin_material`. Not in SIEGE/BREACH. `status` and `inspect what=tombs` (`prov`) show want, short, stock, orders and the project.
- autoslab, burial, preserve-tombs.
- KPIs: 0 ghosts, 0 corpses older than 3 days.
- **Tomb repair (FR-27/41/42, Run 9: 22 dead unburied for months, 10 ghosts).** Each care run outside SIEGE/BREACH (`tomb_repair`; the verb `tombs.repair` forces one run in any mode): one zone per coffin tile (stacked 1x1 zones removed, the zone of the body inside or of an unburied body kept), 1x1 zones without a coffin removed (not while a tombs project is pending), zones of bodiless or elsewhere-buried dead freed, zones of unburied dead over an unusable coffin (none, taken, shared, inside a Bedroom zone) freed, free zones opened to citizens, and every unburied citizen without a usable zone assigned a free one (`act.tomb_zone`). A free tomb is a built empty coffin under exactly one active zone and no other zone.
- **Burial jobs (FR-45).** Assigning a zone made no PlaceItemInTomb job live; care runs DFHack `entomb --unit <id> --haul-now` (the UI's burial assignment plus its hauling jobs) for each unburied body with a usable zone and no job, inside Kern+ (or at clean-up time), and counts the PlaceItemInTomb jobs; a body still without a job after 2 days is `no_job` (3 tries; `tombs.repair` restarts them).
- **GHOSTS (A, FR-04/26)** as soon as a citizen ghost exists or a citizen body lies unburied longer than 3 days, with the cause per body (no_coffin, no_zone, coffin_taken, zone_shared, bedroom, zone_owner, unflagged, unreachable, in_stockpile, undiscovered, no_job; no_body for a ghost without remains); `inspect what=tombs` lists coffins, zones, bodies and causes.
- **Doctors (FR-48):** at least 4 living adult civilians with DIAGNOSE, SURGERY and BONE_SETTING (`act.medic`); hospital posts that are vacant or held by the dead go to doctors (`act.hospital_post`).
- No second tomb zone on a coffin (live L3, FR-27): `bp.place` cuts tomb cells with any tile already in a tomb zone (a document with no other is refused); at apply time the runner leaves out tomb cells with any tile in a tomb zone and bedroom/office cells whose tiles all lie in a zone of that type, and care runs `burial -c` only when no zoned coffin lacks its `relations` link (burial.lua zones every coffin with empty relations; four coffins got a second zone, DF gave the dead those "free" zones on occupied coffins).
- A berserk citizen leaves the own group (live L3): care still counts it as a fort member through its histfig link (MEMBER or FORMER_MEMBER) to the site government, so its death is recorded and its corpse buried, and sense never counts a ghost of the fort's civilization as a hostile (a berserker's ghost held the fort in BREACH: civilians in Tiefe+, no lever pulled, 21 thirsty).

**5.11 Food and drink.**
- **Days of stock:** stock divided by a 7-day moving consumption average, seeded with Run 6 rates (0.053 drinks and 0.024 meals per dwarf per day). Targets: drink ≥170, food ≥60, ≥5 meal kinds.
- **Kitchen:** `ban-cooking booze honey milk oil tallow` plus one `kitchen.addExclusion` for PLUMP_HELMET (Gordon's rule; no `brew` ban).
- `seedwatch` only on farmed crops, at 12.
- **Food follows the population (live L5).** Castlerisen y295: migrants took the fort from 41 to 53 citizens on the same 80 farm tiles, autofarm's default threshold (50) stopped the plump helmets at 40 in stock, nobody fished, and food fell from 105 to 15 days. economy now wants `cit x per_dwarf / yield` farm tiles (defaults 3 plants per citizen and season, 1 crop per tile and season: 159 tiles for 53) and asks for a `farms` project (PROJECT_REQUEST why=food, plots of 35 tiles, at most 4; follow places it at prio 1) while food is below 90 days or fell over 14 days, no farms project is pending and the last request is 14 days old. The food crops' autofarm thresholds are `cit x 4` (steps of 10, between autofarm's default and 400). One fisher per 15 citizens (max 3, `Fisherdwarves`) while food is below 90 days and a fishing zone exists, only in PEACE/RECOVERY. The `dfllm:food` meal order keeps 2 meals per citizen from cookable stock that is not plump helmet (meals keep, gathered fruit and meat rot), its job cap grows with the fort, and a PrepareRawFish order holds up to one fish per citizen. Below 30 food days a class-A pre-alarm (DECISION_NEEDED `food_low`) names the blockers and options; the famine wake stays below 10 days. Gather zones stay LLM/runner actions.
- **Fishing, fishery and the kitchen's real blockers (Run 11).** Kilrudrabed y432 (pop 54, food 24 days): no meat or fish, no farm soil, both kitchens idle with ORDER_STUCK PrepareMeal `no cook` (that was economy's input key `cook`, read as a missing cook), nobody fished (the kernel only read zones); in y433 883-4532 raw fish lay uncleaned for want of a fishery and food fell to 5 days. Now: the census counts cook ingredients the way a kitchen does (`cook_in`: EDIBLE_COOKED and not on the Cook ban, `cook_ban`, `food_inedible`, `food_far`), and ORDER_STUCK says `no cook ingredient (883 raw fish need a fishery, 1566 inedible (OAK:LEAF), ...)`; raw fish or fishers at work without a fishery ask `workshops why=fishery` (follow places only the fishery; fortcore stage 1 builds one); while fishers are wanted and no fishing zone stands (PEACE/RECOVERY, at most weekly) economy paints a 3x3 `dfllm-fish` zone (act.fish_zone) on revealed water of depth >= 2 around the citizens (their levels and the one below, the fortcore surface): never cavern water (caverns stay sealed) or ice (winter; `snapshot.liquids` lists it apart), a standable bank on the citizens' walk group (same level, or above over open space or a brook top), never on the attack path (Z1/Z2, killboxes), a roofed bank before an open-sky one, then the nearest; none: `no safe fishing water (n frozen, n cavern, ...)`. The food_low (< 30 days; util/cadence: again only with a new blocker or below 20 days, after max(7 days, 10 min)) and famine decisions name the numbers, the blockers (`block`: fishery, kitchen, cook, fish_zone, hunt, farms, butcher) and the options (`opts`; always trade.want food, butcher, gather, popcap.lower). Hunters (2) hunt from the food_low pre-alarm on, like in a famine; cookable growths on a kitchen ban are let go once per episode (`ban-cooking fruit --unban`; plump helmets stay banned, D-09).
- **Core stock (BUG-028, Run 10 y419: 60 days of drink inside the core, 3093 units outside O1).** seal reports the days of drink and food inside Kern+ and the refuge (state `alert.core_d/core_f`); the target is ≥ 90 days (`plan.CORE_DAYS`). The `stockroom` room template (`rooms.stockroom`, sited in Z4 like every room) holds food stockpiles named `dfllm-stock` with one barrel or pot per tile (quickfort `barrels=`; drink is food-pile goods) and, with `still=1` (default), a still at its far end. `dfllm plan propose` drafts a stockroom first while either value is below 90 (food only: `still=0`) and none is applied; `dfllm plan check` warns (`core stock: add tpl stockroom ...`), and once the fort has seen a siege (a SIEGE_START/SIEGE_END/BREACH event or a MODE change to SIEGE/BREACH in the log, or the mode now) the low value is the doctrine minimum: an error until a stockroom is planned or exists.
- **Guards:** forbidden-barrel guard (Run 5), barrels allowed in food piles, hospital water check (Run 6).
- **Hospital water is the game's condition (FR-31/33a/34/47, Runs 7-9).** Only a built well with water down its shaft or an active Water Source zone with water ≥ 4/7 on its own level counts; 1/7 seepage does not (GiveWater was cancelled "No water source" in a ward beside 190 days of drink). A hospital location (or a pending hospital project with no accepted water anywhere) without such a source within 30 tiles raises HOSPITAL_DRY (A) with a one-line recipe from the water sources scan (`inspect what=water_sources`: deep water per level, a reachable bank, else the shortest dig through revealed rock); patients over thirst 30,000 raise `patient_thirst` with the recipe ("delete the hospital zone or carry water"), the caregivers with FEED_WATER_CIVILIANS and the buckets.

**5.12 Phases** (`plans/year1.json`, advanced by the kernel when deliverables pass; ★ = LLM approval):

| Phase | Deliverables |
|---|---|
| P0 | baseline; probe stair (damp → stop); fortcore stage 1 |
| P1 | dining, office, all 12 moodable workshops + still + kitchen, mood stock goals (the well and the depot are fortcore stage 1) |
| P2 | trap hall, B1, barracks, squad A |
| P3 | smelter + wood furnace, hospital, orders basic + rockstock |
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
- **A** wakes the LLM: SIEGE_END, GATE_FAIL, BREACH, DEATHS_3PLUS/day, DRILL_FAIL×2, KERN_FAULT, PERF_DEGRADED, DECISION_NEEDED, PLAN_EXHAUSTED, PROJECT_BLOCKED>2 days, YEAR_REVIEW; since Run 9 also SIEGE_START, INVASION and the reflex events ARRIVAL, INTRUDER, PREDATOR, NO_DEPOT, LOCKDOWN (CONTRACTS §12; interrupts wake at once).
- **B** goes into the digest: ALERT_*, MOOD_*, CARAVAN, MIGRANTS, PETITION, STOCK_LOW, CANCEL_LOOP, CAPTURE, BREACH_STOP, KERNEL_SLOW, WEALTH.
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
- **Python** (`python -m dfpilot`, alias `dfllm`):

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
- **Rate limit** (in `follow`): ≤1 wake per type per 5 min, bursts merged within 60 s, ≤6 wakes per hour; BREACH, SIEGE_START, INVASION, LOCKDOWN and the interrupts wake at once (≤1 per type per 60 s). Notifications go to chat only, never push.
- **Client guidance (Run 9, FR-53):** never run a tool call longer than ~20 s while the game runs at timestream speed (the 23:13 dragons came in during a 4-minute call); use `dfllm wait --until-interrupt --timeout 15`, background tasks and Monitors (re-arm after 30 min); keep routine lines out of the alarm stream (`alarm.txt` holds interrupts only); `dfllm ack` each interrupt, or the kernel applies its lockdown default after `ack_timeout_s`.
- **Budget:** ≤3 M input tokens per real hour (alarm at 5 M; v1 74 M) and ≤30k output tokens per hour.
- **Without an LLM** the kernel keeps running safety and supply and finishes the approved plan. It never starts ★ items.

## 9. Repository layout and migration
**Repo A** (`dfpilot-public`, GordonMohrin/dfpilot) is the single source. Work happens on branch `v2` after tag `v1-final`, and `v2` merges to main only after A3 passes. Commits are authored by Gordon with Co-Authored-By and always pushed.
```
RULES.md (≤300 lines)  README.md  docs/v2/{DESIGN,CONTRACTS,DECISIONS,DOCTRINE,QUICKSTART,STATUS,V1-LEGACY,ASIS-ANALYSIS}.md
lua/dfllm.lua   lua/dfllm/{kern,io,act,sense,snapshot,persist,arbiter,perf,threat,gate,siege,military,readiness,drill,
                runner,baseline,economy,care,water,reserve,trade,selftest}.lua  lua/dfllm/util/{json,contract,geom,k_mock}.lua
dfpilot/{__main__,cli,paths,files,schema,wake,brief,plan,cmd,doctor,events,supervise,fairplay,lint,hook}.py
dfpilot/bp/{primitives,fortcore,rooms,validate,emit,render,topo,sites}.py
plans/year1.json  config/{baseline.json,allowlist.json,decisions.yaml}
tools/{luahost.py,migrate_v2.py,embark/,win/{vdesk_move,start_df_desktop1}.ps1}
tests/ (pytest; tests/lua/*.lua via luahost; tests/fixtures/v2 recorded from the new fort)  fixtures/v2 (decision vectors)
.claude/settings.json (PreToolUse → dfllm lint --hook)
```
**Removed from `v2`** (kept in `v1-final`; done 2026-10-11, list in [V1-LEGACY.md](V1-LEGACY.md)):
- `dfpilot/*` except `lint`, `fairplay` (rules) and `planners/blueprint.py` (which became `bp/validate.py`); `stalllog` and `clock` went too, because no v2 module imports them;
- `dfpilot/`, `Bugs/`, `Features/`, `fixtures/` (except `fixtures/v2`), `scenarios/`, `runtime/`, `lua/claude`, `lua/pilot_*.lua`, `data/`, `examples/`, `blueprints/`, `config.yaml(.example)`, `COMPANION.md`, `tools/luacheck_min.py` and the v1 tests;
- `docs/manual-v3`, `specs-v2`, `specs-v3` and the v1 docs (MANUAL, INTEGRATION, OVERVIEW, SPEC, AGENT-PROMPT, PLANNERS, LINT-FINDINGS).

**Repo B** (`dwarf-fortress`):
- Tag `run6-final`.
- `git rm` `lua/claude` (161 scripts), `dfpilot/`, `tools/aufsicht` (after neustart/sicherung are ported), `tools/gen_bau*.py`, `tools/*.flag` and the loop files.
- Keep `POSTMORTEM-run2..6.md`, `ERFAHRUNGEN.md` (archive), `BAUANLEITUNG.md` and `runs/run7/`. `CLAUDE.md` becomes a 30-line pointer to RULES.md.

**DF install** (`tools/migrate_v2.py`; everything is moved, nothing deleted):
1. Stop the waechter, the repo B supervisor and the DF-Aufsicht task.
2. In `script-paths.txt`, replace the repo B lua path with `+…\dfpilot-public\lua`.
3. `onMapLoad.init` = `dfllm boot`.
4. Move `hack/scripts/claude` → `<DF>/_archive-v1/`; move the automelt, channel-safely and confirm DLLs → `hack/plugins/_disabled/`; move `df-llm-helper-runtime/` → `_archive-v1/`.
5. Repoint DF-Aufsicht to `pythonw -m dfpilot supervise --once`.
6. Embark, then `dfllm adopt`.

Prefs files are **not** edited.

## 10. Speed and CPU plan
- **Targets:** PEACE ≥450 calendar ticks/s at pop ≤55 (timestream 500; Run 3 measured 458; try 700 after A2). SIEGE and DRILL ≥100 ticks/s with timestream off and FPS_CAP 250. Kernel ≤25 ms per second, 0 frame gaps >3 s per hour outside autosaves, autosave freeze ≤15 s.
- **Per-save runtime profile** (applied at boot; originals saved to `restore.json` and the save; restored at SC_MAP_UNLOADED; a crash is healed at the next boot of any save): timestream fps by mode; `enabler.gfps` 30; `d_init.feature.autosave` YEARLY [S8: enum name]; population cap back to its pre-boot value (pop-control leak); headless overlay profile with everything but notify disabled (overlays cost 3.6-6.4 % of real time; old state re-enabled on unload); `visitor_cap` 30 and weather only per D-07.
- **Load:** 3x3 or 4x4 embark, low autobutcher targets, caverns sealed, goblin gear melted, bins and `combine`, no filler digging.
- **Never:** `items.all`, `buildings.all` or `reqscript` inside loops; the quickfort CLI (use `apply_blueprint` in chunks of ≤40 tiles); JOB_* or CONSTRUCTION hooks; in-game BFS (Python does it on snapshots); Lua quicksaves.
- **Measurement:** a frame-gap meter blames each gap on the last module or on "external"; perf.csv every 30 s holds ticks/s, pop, units, items and ms per cost owner; `doctor` aggregates. The `repeat` column is DFHack's own timing of the whole kernel callback (unpaused frames, coarse clock), a cross-check of the total, not a module (FR-62).
- **What limits PEACE ticks/s (FR-62, Run 9: 430-435 at timestream 500):** timestream can only add calendar ticks to the frames DF itself simulates, so ticks/s falls with DF's own cost per frame (units pathing, items, fluids; Run 9 had 402 units and 18.7k items for 5 citizens) and with every ms DFHack hooks take from each real second. The kernel took 82-90 ms/s there (8-9 % of real time): seal 37, sense 16, economy 13, kern 11 (the `repeat` 69 was the same time counted again). Paced to its budget the kernel gives back about 6 % of real time, roughly the gap to 450; the rest is DF's own load, which only fewer units and items reduce (butchering, `combine`, melting, dumping).
- **DEGRADED** fires when rolling 10-min ticks/s falls below 60 % of the post-load baseline (same mode and target) or an autosave freeze exceeds 20 s. The supervisor restarts DF **only in PEACE right after an autosave**: kill DF → Steam start → `vdesk_move.ps1` to desktop 1 (no focus steal) → `dfhack-run load-save <folder>` (port of neustart.py) [S9]. It never loads an older save. Liveness: heartbeat file (frames, so it also beats while paused) older than 120 s.

## 11. Fair-play guarantees
1. **Reads.** Only `sense.lua` and `snapshot.lua` read units and tiles. Units count only if `isVisible ∧ ¬isHidden`; tiles only if revealed (hidden tiles become `?`). No `water_table`, prospect or locate-ore. Damp, warm and cavern knowledge comes only from vanilla cancel reports and revealed-tile flags (BREACH_STOP); a cavern lake is a body of ≥ 30 revealed water tiles outside the project's own dug tiles that connects to the breach, with a revealed cavern tile (`designation.feature_global`, the export's cavern mark) there or none of it under the open sky (Run 11). onInvasion only arms the scan.
2. **Writes.** Only `act.lua` assigns to `df.*` or calls mutating APIs, and each function maps to a UI action: designations (dig, smooth, engrave) and quickfort apply (dig, build, place, zone, burrow); work orders and `orders import`; stockpile, kitchen and seedwatch settings; forbid, dump and melt flags; squad create, assign, routine index, orders and uniform; civ alert and alert burrows; lever pull job and cancelling our own queued pull; `pop-control set`; timestream, gfps and runtime vanilla settings; dismissing whitelisted popups.
3. **Lint** (pre-commit and pytest, `dfllm lint`) rejects any `df.` assignment or vector insert/erase outside `act.lua`; unit or tile iteration outside sense/snapshot; `createItem`, `removeJob` (except in `act.cancel_own_lever_job`), `.hidden=`, `water_table`, `--instant`, `teleport`, and writes to skills, body, pos or timers.
4. **Commands.** `act.run` uses an **explicit allowlist** (`config/allowlist.json`), cross-checked at boot against `helpdb.get_tag_data('armok')`: an allowlisted entry with an armok tag must be a listed exception (`lever` is reachable only through `act.pull`). Always blocked: `digv`, `digvx`, `digtype --hidden`, fastdwarf, `caravan extend|happy`, autodump, locate-ore, prospect, showmood, reveal, createitem, dig-now, build-now, `fix/retrieve-units`.
5. **Hook.** A PreToolUse hook on Bash and PowerShell runs `dfllm lint --cmd`. It allows `dfhack-run dfllm …`, `load-save` and read-only `dfllm inspect`, and blocks `claude/*`, inline `lua` and anything on the blocklist. `DFLLM_DEV=1` enables `dfllm selftest --exec <file>` (linted, logged), which is refused while the save's `acceptance` flag is set.
6. **Register.** The exception register is retired. decisions.yaml holds only Gordon's answers, and the default until he answers is off or unchanged.

## 12. Work packages and waves
Wave 0 freezes the contracts. Waves 1 and 2 code in parallel against mock-K and fixtures. The **single live slot** is serialized through `dfllm-runtime/live.lock` (holder, purpose, expiry ≤30 min).

| WP | Goal | Files | Interface contract | Size | Deps | Tests | Done when |
|---|---|---|---|---|---|---|---|
| **WP0** (W0) | Freeze contracts; Lua testable offline | docs/v2/CONTRACTS.md, dfpilot/schema.py, lua/dfllm/util/{json,k_mock}.lua, tools/luahost.py, tests/lua/test_json.lua | Module `{name, every={ticks=N} or {ms=N}, init(K), step(K,budget_ms), on={EV=fn}, state(K)}`; K = `now() emit(type,cls,msg,d) census mode act persist plan cfg log`; JSON schemas for state, event, inbox, outbox, plan, manifest, snapshot | 300 Lua + 300 Py | — | luahost runs Lua tests on lua53.dll; JSON round-trip (ints, umlauts, comma locale) | Tests green; schemas validate the §6 examples; CONTRACTS frozen (changes go through the orchestrator) |
| **WP1** (W1) | Kernel: dispatcher, IO, persist, opt-in, arbiter, act core, perf | lua/dfllm.lua, lua/dfllm/{kern,io,persist,arbiter,act,perf,selftest}.lua | Implements K; a/b state, events, outbox; boot is a no-op without the marker; arbiter.apply(mode) idempotent; restore on unload; pcall per module | 800 Lua | WP0 | luahost: tick deltas with 9-tick skips, demotion, fault isolation, a/b writer. In-game: S1, S4, S8 | ≤25 ms/s with 5 dummy modules; heartbeat while paused; 0 dfhack-run in steady state; Inchcraft-style unmarked save untouched |
| **WP2** (W1) | Python CLI, follow and wake | dfpilot/{__main__,cli,paths,files,wake,brief,plan,cmd,doctor,events}.py | `files.read_state()` (best seq, retry); wake classes and limits; `plan check` = schema + validators + fair play + `pop_ceiling ≤ R-level cap` | 800 Py + 300 tests | WP0 | Torn-read fixtures, rate limits, brief ≤1.5k tokens, plan rejections | All §7 commands work on the fixture runtime; follow lines ≤150 tokens |
| **WP3** (W1) | Templates, validators, emitter, topo audit, site finder | dfpilot/bp/*.py (port planners/blueprint.py), tests/bp/, golden JSON | `emit(tpl,params,site) → {stages:[{label,mode,data,chunks≤40}], manifest, materials}`; `topo.audit(snap,manifest) → {ok, fails, min_traps, bypass, refuge_sep, civ_sep, caverns}`; `sites.rank(snap,tpl) → top 3` | 1,200 Py + 400 tests | WP0 | Flood-fill closure, diagonals, 2 stairs, shortcut bridge, trap-hall-removed BFS, golden data | fortcore stages 1-3 + 7 room templates (dining, bedrooms, tombs, hospital, temple, tavern, workshops) valid; audit ≤2 s on 100×100×12 |
| **WP4** (W1) | Fair play: lint, allowlist, hook, decisions | dfpilot/{fairplay,lint,hook}.py, config/{allowlist.json,decisions.yaml}, docs/v2/DECISIONS.md, .claude/settings.json | `lint.lua(paths)`, `lint.cmd(str)`; `decisions.get(id)` with defaults | 400 Py | WP0 | Positive and negative cases, including v1 snippets | 0 findings on lua/dfllm; hook blocks `lever pull --instant`, `claude/x`, fastdwarf |
| **WP5** (W2) | Threat, gate, siege FSM, BREACH, RECOVERY, captives | lua/dfllm/{sense,threat,gate,siege}.lua, tests/lua/test_siege.lua | `sense.census` (cit, adults, outside_kern, hostiles_vis[]); `gate.want(bridge, 'up' or 'down', why)` with the single-pending invariant; modes and events per §3/§4 | 800 Lua | WP1 | luahost table-driven scenarios: no flapping, raised bridge ≠ RECOVERY, no double toggle, BREACH at T+900. Live drill L3 | 20/20 synthetic scenarios pass; drill KPIs of §14 met |
| **WP6** (W2) | Military, readiness, drill | lua/dfllm/{military,readiness,drill}.lua | `military.posture(P)`, P ∈ TRAIN, STATION_B1, READY_STATION, B2_HOLD; worn % and combat value; read-only recruit filter; `readiness.level` → `act.popcap`; `drill.run()` | 700 Lua | WP1, WP5, WP3 (audit) | luahost worn % on fixtures; S2 live | 3 squads; routine resolved by name; worn ≥90 %; cap changes only through pop-control |
| **WP7** (W2) | Project runner + capacity keepers | lua/dfllm/runner.lua | Project `{id,tpl,site,stage,chunk,pct,blocked}`; dig → build → place → zone/burrow → finish; `command='orders'` once per stage; BREACH_STOP; deregister at 100 % | 500 Lua | WP1, WP3 | luahost with fake quickfort; S6; live L2 | fortcore stage 1 built on the new fort with only the site picked by the LLM |
| **WP8** (W2) | Baseline, economy, care | lua/dfllm/{baseline,economy,care}.lua, config/baseline.json | `baseline.apply()` idempotent; stock days, staged imports, cancel-loop detector, labormanager parse; care: moods, tombs, corpses, captives → pit, hospital water, barrel guard, stress and naked sampler | 700 Lua | WP1 | luahost fixtures; S5; live L1 | Baseline active after adopt; supply KPIs in state; 0 mood jobs removed |
| **WP9** (W3) | Trade port | lua/dfllm/trade.lua | CARAVAN_ARRIVAL → broker job → trade screen; `plan.trade`; O1 window through `gate.want` | 600 Lua | WP1, WP5 | goodflag audit; luahost ratio math; live when a caravan comes | 1 caravan traded with ratio ≥1.5 and no LLM |
| **WP10** (W1 offline / W3 live) | Supervisor, restart, backup, migration | dfpilot/supervise.py, tools/migrate_v2.py, tools/win/vdesk_move.ps1 | Liveness = heartbeat age; DEGRADED rule; restart only in PEACE after an autosave; backup copy after an autosave; migrate is idempotent and reversible | 400 Py | WP2 | Fake clocks, dry-run migrate; S9 live | One supervised restart onto desktop 1 with no focus steal |
| **WP11** (W1 embark / W3 docs) | Embark, year-1 plan, RULES.md, repo cleanup | tools/embark/* (port), plans/year1.json, RULES.md, docs/v2/MIGRATION.md (written as QUICKSTART.md + V1-LEGACY.md), repo B CLAUDE.md | Embark checklist (§5.1) from the vanilla screen; phases P0-P7 as data | 400 mixed | WP0 (plan schema) | Site checklist against vanilla finder output | Fort embarked per §5.1; RULES.md ≤300 lines; v1 code removed in `v2`; repo B tagged and cleaned |

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
| Two writers on work details (all three) | one writer per detail: labormanager, except the builtin tool details (economy, only while labormanager is not modern); military read-only filter |
| Lua untestable outside DF (all three) | `tools/luahost.py` on `hack/lua53.dll` (verified) + mock-K + in-game selftest |
| Acceptance needs sieges (all three) | drill-based acceptance with real levers and routines (§14) |
| os.rename is not atomic on Windows (kernel) | a/b slots with seq; new-name renames only (verified) |
| JOB_COMPLETED/CONSTRUCTION hooks and frequency 1 (kernel) | only INVASION 10, REPORT 10, UNIT_DEATH 100 |
| 20k-tile BFS slices against a 2 ms budget (doctrine) | BFS runs in Python on sliced snapshots |
| Scope too large (doctrine) | about 4.4k Lua + 3.8k Py (incl. 0.7k tests) + 0.4k mixed, near native's size; MVP cut (WP9 deferrable); no legacy wrapping, no hot reload |
| Auto-unpauser (native) | unpauses only popup-caused pauses; honours manual pauses |
| FPS cap 100 in SIEGE (native) | timestream off, FPS_CAP 250 (superseded after Run 9 by FR-51: siege cap 30, CONTRACTS §18.12) |
| No site rule (doctrine, native) | §5.1 site checklist |
| Unsupported wealth pause (kernel) | D-13, logging only |
