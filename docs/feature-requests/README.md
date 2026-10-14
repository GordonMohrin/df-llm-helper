# Feature requests (tools I missed while playing)

Each entry: what was missing, what it cost, what the tool should do. Written during the Paddletribes run
(site 94, fallen spring y382). Keep adding to this list whenever play hits a gap (RULES §1.7: no new tooling in
play, so a gap becomes a note here, not a script in the running game).

| # | Tool | Why (cost in Paddletribes) |
|---|------|-----------------------------|
| FR-01 | Order sanity check | A PrepareMeal order stood valid for months with no Kitchen; 133 orders without material cancelled endlessly |
| FR-02 | Stuck-construction watch | Kitchen, still, bridges, traps stayed at stage 0 or vanished; nobody noticed for weeks |
| FR-03 | Reachable-stock report | Food in cut-off caves counted as stock (fixed in economy.lua); report stock per walkable group for water, wood, stone too |
| FR-04 | Burial/ghost monitor | Loose corpses 70-120 and ghosts 30-41 grew for a year; alarms only at the end |
| FR-05 | Job-pickup diagnostic | 22 ConstructBuilding jobs unworked while 6 masons idle; no way to see why a job is not taken |
| FR-06 | suspendmanager control verb | It re-suspended construction; baseline re-enables it; `set preventblocking` is allowlisted but no verb |
| FR-07 | Hostile-visibility explainer | Which unit holds the fort in ALERT/BREACH? Needed ad-hoc Lua twice (underworld demons, cave crocodile) |
| FR-08 | Embark site finder with waiver | Helper rejects every site it finds; no way to accept a known trade-off (old_sites, scarce trees) |
| FR-09 | Embark: Prepare carefully | Still not drivable; points stay unspent, player must do it by hand |
| FR-10 | Orders without material pruner | EngraveSlab/web/silk orders spam cancels; kernel should drop orders that cannot start |
| FR-11 | Early-warning dashboard | Population fell 55 -> 46 -> 0 over a year; a trend line "pop, food, drink, stress, corpses" per season |
| FR-12 | Rebuild-lost-buildings helper | Traps 31 -> 0 and bridges lost; no verb to re-place a list of lost buildings |

| FR-13 | Plan check before the fort manifest exists | `plan check` rejects every plan with room templates (farms, cistern, ...) until fortcore is placed; even the default draft is rejected on a fresh fort. Workaround: place fortcore with `bp.place`, then propose/check/apply |

| FR-14 | Aquifer pass-through / drain template | Fortcore stops at the first damp tile (breach:damp) and never resumes; Gordon's rule is to dig through and smooth quickly, or dig ~10 levels deeper and excavate a large drying chamber. No verb or template does either; 3 fort starts stalled at damp stone with no boulders, no still, no office |
| FR-15 | Duplicate fortcore guard | The applied default plan also places fortcore stage 1; placing it by hand creates two projects on the same site |

| FR-16 | Plant-gatherer / hunter assignment and suspended-construction release | Gatherers detail stays empty (famine at 5 days with 12 idle); all 13 construction jobs suspended by suspendmanager; I had to use Lua workarounds (outside the door) |

| FR-17 | Fill every season slot of every farm plot | autofarm left 2 of 4 season slots empty on 10 underground plots; plots idle half the year, food swung 4-44 days; I filled the slots with Lua |

| FR-18 | Show the caravan's goods before setting wants | Four caravans (ratios 1.7-2.2) delivered drink/wood but never metal; wants are set blind. A `trade.offer` read verb lists what the civ brings, so wants and sell lists can be chosen |

| FR-19 | Weck-Meldungen fuer einzelne Hungernde/Durstige und Buerger ausserhalb der Fort-Zone | zwei Zwerge verhungerten in Hoehlen, nur 'starving N' in der Statuszeile |
| FR-20 | Handelsfenster nutzen | Karawane scheiterte 'time' und 'nothing_listed'; Verkaufsliste vor Ankunft, Depot frei, Handel sofort beim Eintreffen |

| FR-21 | Stockpiles without fortcore | The fort ran 10 years with 0 stockpiles because fortcore never finished; items lay scattered. A `stockpiles` template that needs no manifest, placed by default before pop 10 |

## Details
**FR-01 Order sanity check.** `dfllm cmd orders.check`: for each manager order, verify the workshop type exists
and is built, the material exists on the reachable walkable group, and a worker with the labor exists; report
orders that cannot run for N days and drop or pause them.
**FR-02 Stuck-construction watch.** Per planned building: stage, days since placement, held item, worker. Alert
class A if a building is at stage 0 for more than 30 days or disappears.
**FR-03 Reachable-stock.** `inspect what=census` split by walkable group; mark items in other groups as
`unreachable`.
**FR-04 Burial/ghost monitor.** Goals-style thresholds in the kernel: loose corpses > 20 or ghosts > 5 raises a
class A event and an automatic coffin/tomb project.
**FR-05 Job-pickup diagnostic.** For one job id: labor needed, units who could take it, why each does not
(labor off, no path, burrow, busy). Read only.
**FR-06 suspendmanager verb.** `dfllm cmd suspendmanager preventblocking=false` through the allowlist, and a
baseline option that stops forcing it on.
**FR-07 Hostile explainer.** `dfllm cmd inspect what=threat` listing the units counted as hostile, with race, z,
walkable group and why.
**FR-08 Embark waiver.** Allow `--accept <criterion>` for failed (not only unshown) criteria with a logged
reason, and a "relax old_sites" rule when the old fort is ruined.
**FR-09 Prepare carefully.** Drive the skill rows (known blocker: clicks ignored, see embark README).
**FR-10 Pruner.** Kernel drops manager orders that cancelled more than N times for "Needs ..." reasons.
**FR-11 Trend dashboard.** Season-by-season table in `dfllm brief`.
**FR-12 Rebuild helper.** Keep a manifest of placed buildings; `bp.restore` re-places the missing ones.

**FR-13 Plan check without manifest.** Accept room templates after a fortcore stage in the same plan (dry-run the manifest), or have `plan propose` emit a first plan with fortcore only and a note to re-propose after placement.

**FR-14 Aquifer pass-through.** New template `aqshaft`: a sealed 1-wide shaft through damp layers (dig down, smooth walls at once, optional channel chamber 10 levels below). `fortcore` should accept `aquifer=pass|above|drain` and resume after the shaft is sealed.
**FR-15 Duplicate guard.** `bp.place` refuses a template that the active plan already places on the same site, and `plan apply` skips a build entry whose project already exists.

**FR-16 Work detail + unsuspend verbs.** `economy` assigns Plant gatherers, Fisherdwarves and Hunters when food < 20 days and idle > 30 %; add a verb `jobs.release` for suspended ConstructBuilding jobs with a reason report, and stop baseline from forcing suspendmanager on.

**FR-17 Farm season slots.** The economy module should set a crop for all four seasons per plot (underground plots grow all year), preferring a crop already in stock as seed; add a census line 'farm plots with empty slots'.

**FR-18 Caravan offer.** `inspect what=trade` lists the merchants' goods (types, counts, prices) once the depot is open, `trade.want` can then name items that exist; report unmet wants per caravan.

**FR-22 Reachability audit.** `inspect what=reach`: walkable groups of citizens, food, seeds, farm plots, wells, depot and exit; flags any item class whose group differs from the main citizen group, and any STAIR_UP/STAIR_DOWN without a counterpart. Run it before and after any construction that could close a path (walls, doors, bridges). Run 9 lost 43 of 56 citizens to a self-built wall ring plus an entrance stair without a counterpart (see memory feedback_df_abriegelung_connectivity).

**FR-23 Forbidden seed bags.** The census should report seeds that are unusable (forbidden item or forbidden container) separately from usable seeds; `economy` unforbids seed containers. Symptom was `Needs plump helmet spawn` cancel spam and zero PlantSeeds jobs.

**FR-24 Lever vs bridge truth.** `inspect what=defense` prints each bridge's `gate_flags.raised` and the walkable result through it, next to the lever's linked state; the lever list alone mislead us.

**FR-25 Starvation handler.** At food_days 0 and hungry citizens, mark every reachable visible edible plant for gathering (`dfhack.designations.markPlant`), set Gatherer and Planter details, unforbid food, and report who cannot reach food.

**FR-26 Ghost and corpse escalation (Gordon 14.10.2026: "ich sehe Geister rumfliegen, welches Tool hätte dir Bescheid sagen sollen?").** `status` and `brief` already print `ghosts N corpses N`, and the kernel raised `PROJECT_REQUEST tombs` 40 times (class B), but nothing escalated: no class A event for ghosts, and the repeated request was never turned into a diagnosis. Wanted: class A `GHOSTS` as soon as a citizen ghost exists or a citizen corpse lies unburied longer than N days, with the cause per corpse: no coffin, coffin held by someone else, tomb zone shared with another zone, zone assigned to a unit that is not the corpse's owner, unreachable coffin, corpse in a stockpile, death not discovered. And `follow` must say loudly when it is not running (see FR-29).

**FR-27 Tomb zone hygiene.** Repeated `bp.place tombs` / quickfort runs stacked up to 3 tomb zones on one coffin tile (each assigned to another dead citizen) and left zones on tiles without coffin; 22 dead stayed unburied for months and 10 turned into ghosts. `bp.place` must refuse a second zone on a tile that already has one, and `inspect what=tombs` should list tile, zones, assigned unit, coffin, occupant. Add verb `tombs.repair` (keep one zone per coffin tile, drop empty zones, reassign unburied dead to free coffins; tools/run_release.lua has a working version).

**FR-28 Intruders.** Wild animals (giant rats) walked around inside the fort for days; `threat` stayed 0 because only hostile classes are counted. Add `inspect what=intruders` (non-tame, non-citizen units on the citizens' walkable group, visible tiles only, race ids) and let the military module give the fort squads a kill order on them and withdraw it afterwards (run_release.lua does it with `squad_order_kill_listst`).

**FR-29 Follow/wake watchdog.** Silence from `follow` looked like "all is well" while it was simply not running (I replaced it by my own watcher and never re-armed it). `status` should print `follow: OFF (last heartbeat Nd)` and `dfllm doctor` should warn; the run watcher must not replace the kernel's class A stream.

**FR-30 Military coverage.** `status` shows soldiers and `worn`/`cv`/`drill` only. Add per citizen adult: equipped (weapon + armor), squad, training months this year; and the elite share (Gordon rule 5: every adult equipped, >= 3 months training per year, elite trains all year except 3 months, 10 % elite). tools/run_probe.lua now reports `equipped_adults` / `squad_adults` as a stopgap.

**FR-31 Hospital water before the first patient.** A bedridden patient died of thirst (75000) minutes after the hospital location existed: the kernel's `patient_thirst` class A event came at 40000 with "no wet well or Water Source zone", the `cistern` project request was only class B, and the GiveWater job sat unclaimed with no position. Creating a hospital location (`bp.place hospital` or quickfort `m{location=hospital}`) must also place a Water Source zone / well within 30 tiles (or fail loudly), and the patient-thirst event should list the caregivers with FEED_WATER_CIVILIANS and the buckets, not just say "present".

**FR-32 Trade ledger.** `CARAVAN traded with Muboomon, ratio 1.71` says nothing about what was bought or sold. Wants listed iron/copper/bronze bars, picks, axes, anvils, leather and thread, yet afterwards the census shows 1 bar, 0 weapons, 0 leather. Log per trade: items sold (type, count, value), items bought, wants unmet and why (merchant had none / not enough value / not wanted), so the next caravan's wants can be tuned instead of guessed.

**FR-33 Alert scope.** `ALERT` (22 days) was triggered by four dingoes on the open surface; the civ-alert confined all 33 citizens to the 4-tile `Kern+` burrow, idle went to 95 %, and the lever jobs I had queued could not be reached. The alert should depend on invaders/dangerous units (and large predators within N tiles of an entrance), the burrow must be the whole fort interior (or the alert must not apply while `Kern+` has fewer than ~200 tiles), and `status` should print how many citizens are confined. tools/run_release.lua now drops the civ-alert when no invader/danger is visible.

**FR-33a Alert confinement kills by thirst.** Two bedridden citizens (23433, 21542) died of thirst at the hospital while the kernel's civ-alert (4-tile Kern+ burrow, no drink inside) was on for many game days: they had no wounds, only `rq_diagnosis, should_not_move, needs_healthcare` after fainting from thirst, and every `GiveWater` job was cancelled with `No water source` (a Water Source zone on 1/7-deep seepage tiles does not count for the game, although `inspect` reports "water and buckets present"). Wanted: (1) never confine citizens without drink/food inside the alert burrow, (2) `patient_thirst` must test the game's own condition (deep water tile >= 4/7 in a Water Source zone or a working well), not just the presence of tiles, (3) `DiagnosePatient` needs a doctor: baseline must enable DIAGNOSE/SURGERY/BONE_SETTING for a few adults (65 labor flags were off).

**FR-34 Hospital gate.** `bp.place hospital` / the hospital location must be refused (or removed again) until the game itself accepts the water: run a `GiveWater` self-test or require a well over water >= 4/7 or a pond/cistern with deep water. Six patients died of thirst in a ward with 190 days of drink in stock; deleting the hospital zone made the survivor stand up, drink and eat at once. Also: hospital patients with thirst > 30000 should raise a class A event with a one-line recipe ("delete the hospital zone or carry water").

**FR-35 Mood material pipeline.** Every failed strange mood costs a citizen (Fey/Possessed/Secretive moods failed on missing leather, yarn cloth, bone, bars; one failed mood = one lost dwarf, 5 so far in Run 9). The kernel only reports `MOOD_NEED`. Wanted: a standing pipeline per scarce material class (leather/bone: kill order on harmless grazers with the crossbow squad + butcher + tan; yarn: keep one shearable animal alive; plant cloth: gather and process pig tails; bars: trade) with a class A warning when the 20-piece buffer of any class is below 5 before a mood starts. tools/run_release.lua now gives the squad kill orders on grazers when no large predator is visible.

**FR-36 Threat popups.** `Snatcher! Protect the children!` (two goblin kidnappers inside the fort, one next to the shaft) froze the game for minutes: DF 53.16 halts on an announcement popup while `pause_state` stays false, the arbiter dismisses only whitelisted popups and the pause (class B `PAUSE`) never reached the operator. Wanted: threat popups (snatcher, ambush, siege, beast) are class A with their text, and the arbiter dismisses them after the threat reflex (alert, kill order, burrow) has been issued, instead of waiting for a person. tools/run_release.lua now logs and dismisses any popup except the embark intro.

**FR-37 Alert burrow size.** The civ-alert burrow `Kern+` had 4 tiles (no fortcore, manifest boxes empty). Each goblin wave confined all citizens to it for days without drink or food; a child and a leatherworker died of thirst, bedridden citizens crawled too late. The alert must refuse to switch on while the burrow does not contain a drink/food stockpile and enough beds for the population (or fall back to "stay inside the fort"), and `status` should print burrow size and how many citizens are inside. tools/run_release.lua now fills `Kern+` with the whole interior (z108-z116, 6000 tiles).
