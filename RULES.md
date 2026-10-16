# RULES: dfpilot v2 (the only always-read doc)

Binding sources behind it: `docs/v2/DESIGN.md` (why), `docs/v2/CONTRACTS.md`
(exact formats), `docs/v2/DOCTRINE.md` (gameplay). Do not read those on a wake; read them only to
change the system. Never read ERFAHRUNGEN.md, transcripts or v1 docs as working memory.
**The player** is the human you play for (in the author's runs: Gordon). Setup and the start prompt:
`docs/v2/QUICKSTART.md`.

## 0. What runs where
- **In game:** the kernel `lua/dfllm` (one frame dispatcher plus modules). It defends the fort,
  runs the approved plan and writes files under `<DF>/dfllm-runtime/<save>/`. Every reaction
  needed within one game day happens in game, without you.
- **Python** `python -m dfpilot <cmd>` (written `dfllm` below; run it from the repo, with
  `DFLLM_DF` set to the DF folder or `--df <DF>`) only reads those files and writes the inbox. It
  never calls DF in steady state. `dfhack-run` means `<DF>/hack/dfhack-run.exe`.
- **You (orchestrator):** the main Claude Code session, at most 60k context. You run `Monitor` on
  `dfllm follow` and spawn one fresh Sonnet subagent per wake line (Opus only for the year-1 plan
  and postmortems); another agent keeps `follow` running in the background and handles each line
  in a short, fresh context. You are a yearly planner and an exception handler, never a tactical
  controller: a game month passes in about 75 s.

## 1. Hard rules
1. **Fair play.** Only UI-equivalent actions. Never: createitem, dig-now, build-now, reveal,
   teleport, fastdwarf, `--instant`, `digv`/`digvx`, `digtype --hidden`, `caravan extend|happy`,
   autodump, locate-ore, prospect, showmood, `fix/retrieve-units`, reads of hidden tiles or
   `water_table`, edits of units, skills, items, positions or timers.
2. **One door into the game.** Change the game only with `dfllm cmd <verb>` (closed verb set, §5)
   or `dfllm plan apply`. No inline `lua`, no `claude/*` scripts, no `dfhack-run` except the
   allowed forms (`dfhack-run dfllm …`, `load-save`, the embark helper before adopt). The
   PreToolUse hook (`dfllm lint --cmd`) blocks the rest; never work around it.
3. **Pause and tempo belong to the arbiter, with one exception (Gordon, 13.10.2026):** when the game is paused
   by DF (after a load, a restart or a popup) and nothing in the arbiter's own pause reasons holds it, you may
   resume it (`pause_state = false`, or Space on the main screen). Never pause to "help"; you may only send
   `pause` with a TTL of at most 600 s when you must think about a running crisis.
4. **Never load an older save** (no save-scumming). Never kill DF yourself; the supervisor restarts
   only in PEACE right after an autosave.
5. **Opt-in per save.** The kernel acts only on saves with the `dfllm` marker (`dfllm adopt`).
   Adopt only a fort the player gave you for this; the player's own forts stay untouched (Gordon:
   never Inchcraft).
6. **Growth is earned.** Never raise the pop cap, start beauty or wealth projects, or open caverns
   outside the readiness gate (§8). Approve ★ phases only when the gate is green.
7. **No new tooling in play.** If something is missing, write a short note for the player; code
   changes go through the repo (tests, lint, commit and push by the repo's rules), never into the
   running game.

## 2. Talking to the player
- In the player's language (Gordon: German, informal "du"), short and honest: what happened, what
  you did, what is open.
- Chat only. Never send push notifications.
- Decide small things yourself; ask only for big risks and for the D-decisions (§7).

## 3. Run v2
```
dfllm doctor                 # ticks/s, kernel ms per module, frame gaps, stalls
dfllm status                 # <= 300 tokens: DEFCON, mode, clock, lockdown, pop/cap, readiness, alarms
dfllm brief                  # <= 1.5k tokens: digest for a decision
dfllm follow                 # Monitor target: one wake line per event that needs you
dfllm events --cls A [--since N]
dfllm wait --until-interrupt [--timeout 15]   # returns at once on an unacked interrupt; keep calls short
dfllm ack [--n N]            # you saw the interrupts up to N (else the kernel applies their lockdown default)
dfllm plan propose|check|apply
dfllm cmd <verb> '<json args>'
dfllm bp list | bp preview <tpl> | bp sites <tpl>
dfllm supervise --once --dry-run   # liveness report (the restarting task is optional, not live-tested)
```
In game (via `dfhack-run`): `dfllm boot|adopt|stop|status|selftest|restore`. `onMapLoad.init`
runs only `dfllm boot` (`tools/migrate_v2.py --apply` sets it up); without the marker it does nothing.

**Session start:** `dfllm doctor`, then `dfllm status`, then start `Monitor` on `dfllm follow`.
Do nothing else until a wake line arrives (right after a fresh adopt: §4 step 5 first).

## 4. New fort (embark, once)
Simplest: the player embarks (or loads a fort) by hand and tells you; go on with step 4. The embark
helper is experimental; procedure and fair-play limits: `tools/embark/README.md`. In short:
1. Title → new game in the existing world: `python tools/embark/embark.py newgame --world <name>`.
2. Shortlist world tiles from the vanilla world map (not world data), then
   `embark.py scan WX,WY[,LX,LY] …`: it places the rectangle, reads the warning popup and the
   embark panel and ranks the sites against the DESIGN §5.1 checklist (Dark Fortress and old forts
   ≥ 10 world tiles, not evil, savagery low/medium, trees, flowing water, aquifer none (light only
   with the probe protocol), a metal ore listed and a hard stone layer within reach (no deep soil),
   flux if shown, temperate, 3x3 or 4x4).
3. `embark.py embark WX,WY[,LX,LY]` refuses a rejected site and any criterion the panel did not
   show, unless that one id is named with `--waive ID` after checking it by eye (no blanket
   waiver); a failed criterion only with `--accept ID --reason "…"` (logged, ask the player
   first). Prepare carefully cannot be driven yet (live L0): pass `--play-now` (DF's default
   seven) or ask the player to spend the points by hand: 3 picks, 2 axes, anvil, bars, wood, plump
   helmet and surface seeds, 1-2 breeding pairs; skills 2 miners, mason/engraver, carpenter,
   brewer/grower, mechanic, cook/doctor.
4. In the fort: `dfhack-run dfllm adopt`. This sets the marker, loads `plans/year1.json` and boots.
   Then `dfhack-run dfllm selftest full` (0 fail) and `dfhack-run dfllm status` (no `DISABLED`).
5. Start `follow` (§3) and resume the game yourself if DF paused it (DF loads paused; rule 1.3). Then
   the year-1 plan at once (§5 year review): without a plan the fort idles and starves (live L0).

## 5. Wake protocol
- `dfllm follow` prints one wake line (≤ 150 tokens) per class-A event, rate-limited: ≤ 1 per type
  per 5 min, bursts merged within 60 s, ≤ 6 per hour. Class B goes into the brief, class C is a log.
- Per wake line spawn **one fresh Sonnet subagent**. Give it this file plus `dfllm brief`. It may
  make at most 5 tool calls and returns at most 100 tokens: what it saw, the one command it sent,
  what to watch next.
- **Exception:** `dfllm events --cls A --since N`, then at most one `dfllm cmd`.
- **Interrupts** (ARRIVAL, INTRUDER, PREDATOR, DEATHS_3PLUS, NO_DEPOT; also BREACH, SIEGE_START,
  INVASION, LOCKDOWN) wake at once, past the merge wait and the hourly limit, and stand in
  `<save>/alarm.txt`. The kernel already acted (gates up, entrance doors forbidden, civ alert, clock
  30 t/s): read `status`, then `dfllm ack`. Unacked for 60 s, the kernel applies the lockdown default
  itself (LOCKDOWN). Never run a tool call longer than ~20 s while the game runs: use
  `dfllm wait --until-interrupt` with a short `--timeout`, background tasks and Monitors (re-arm a
  Monitor after 30 min).
- **Year review** (YEAR_REVIEW, about every 13-15 min real time): `plan propose`, edit a few fields
  (phase_target, seasons[].build, military, supply, trade), `plan check`, `plan apply`. One review
  approves 4 season plans. To edit, propose into a file outside `dfllm-runtime/` (the hook blocks
  edits there): `plan propose y.json`, edit, `plan check y.json`, `plan apply y.json`.
- **New building:** `bp sites <tpl>`, pick S1-S3, `dfllm cmd bp.place '{"tpl":…,"site":"S1"}'`.
  ≤ 5 turns per building.
- **Without you** the kernel keeps safety and supply running and finishes the approved plan; it
  never starts a ★ item.

## 6. Inbox verbs (closed set; `dfllm cmd <verb> '<json>'`)
| Verb | Args | When |
|---|---|---|
| `plan.reload` | `{}` | after `plan apply` (apply sends it) |
| `bp.place` | `{tpl, site, p?, prio?}` | place a template at a ranked site |
| `bp.cancel` | `{proj, undo?}` | stop a project |
| `drill` | `{why?}` | PEACE only; the reflex acceptance test |
| `snapshot` | `{bbox?, purpose?}` | export revealed tiles (audit runs automatically) |
| `audit` | `bp.topo.audit` result | sent by `follow`, not by you |
| `popcap.lower` | `{cap}` | lowers only |
| `tempo.lower` | `{fps, ttl_s}` | lowers only, never above the mode value |
| `pause` / `unpause` | `{ttl_s ≤ 600, why?}` / `{}` | rarely; `unpause` releases only an inbox pause. A pause by the player, by DF (save loaded paused) or by a popup is released in DF, by the player |
| `trade.want` | `{want?, sell?}` | tokens like `bar:iron`, `anvil`, `cloth` |
| `squad.sortie` | `{squad, target, approve:true}` | ALERT/SIEGE/BREACH/RECOVERY; rare, `approve:true` is a deliberate, logged decision; target = kill box id or position |
| `lever` | `{bridge, want}` | PEACE only |
| `inspect` | `{what, key?}` | read-only, ≤ 8 KB; `what=reach`, `entrances`, `defense`, `perimeter`, `refuge` (seal), `what=tombs`, `water_sources`, `what=orders` (blocked orders), `workload` (idle adults, unclaimed jobs, cancel reasons, free picks/axes), `trade` (merchant goods at the depot, last trades) |
| `tombs.repair` | `{}` | GHOSTS: the next care run repairs the tombs (any mode) and retries entomb |
| `order.add` | `{job, amount, item_subtype?, material?, material_category?, reaction?, frequency?}` | one manager order; make-item jobs need `item_subtype` (`ITEM_…`), else DF 53.16 crashes (refused) |
| `jobs.release` | `{all?, preventblocking?}` | resume suspended constructions; `preventblocking` is a lasting fort decision |
| `perimeter.record` | `{}` | no fortcore manifest: record the walls, doors and gates that seal the fort now, so PERIMETER_BROKEN can diff them after a siege |
| `selftest` | `{suite?}` | quick or full |
| `module.enable` | `{module}` | re-enable a module the kernel backed off (KERN_FAULT) before its backoff ends, only once the cause is fixed |
| `ack` | `{n?}` | interrupts seen up to n (default all); `dfllm ack` sends it |
There is no arbitrary Lua. Every reply lands in `outbox/<id>.json`; `dfllm cmd` prints it.

## 7. Class-A events and the first move
| Event | First move |
|---|---|
| SIEGE_START / INVASION / ARRIVAL | the kernel locked down (gates up, doors forbidden, alert, clock 30 t/s) before contact. `dfllm ack`, read `status` (`clock`, `lever_latency_s`, eta); do nothing tactical; tell the player |
| INTRUDER / PREDATOR | a hostile can walk to the citizens (gate open or a leak) / a wild danger inside. `dfllm ack`; read `status` and the brief; tell the player |
| LOCKDOWN | an interrupt stood unacked and the kernel applied its default. `dfllm ack`; read `status` |
| NO_DEPOT | `dfllm ack`; place a trade depot (`bp sites`, `bp.place`) |
| SIEGE_END | read the summary; if losses > 10 % of citizens, write a postmortem note and lower `pop_ceiling` in the next plan |
| GATE_FAIL / BREACH | the fort already sealed itself (BREACH: Tiefe+ alert, B2 up, melee at B2). Do not lower bridges. Check `status` again after 600 ticks; tell the player |
| DEATHS_3PLUS | the line names the causes; the brief lists the season's deaths by cause; fix the cause in the plan |
| DEATHS_PREVENTABLE | ≥ 2 citizens dehydrated or starved within a month (stock days, units, patients in the line): `inspect` `what=reach` (forbidden or cut-off drink/food), `what=refuge`; patients → `what=water_sources` (hospital water); tell the player; fix access in the plan |
| DRILL_FAIL (2nd in a row) | read `ready.fail`; fix gear, squads or geometry; never raise the cap |
| KERN_FAULT | a module is backed off (`d.backoff_s`; the kernel re-enables it afterwards); note module and error for the repo; do not hot-patch; `module.enable` only after the fix |
| PERF_DEGRADED | `dfllm doctor`; the supervisor restarts DF only in PEACE after an autosave |
| DECISION_NEEDED | ask the player the question once; the default applies until they answer. `build_blocked`: `inspect` `what=workload` (`construction.blocked`: kind, pos, fails, why); the kernel already unforbade the items on the site; corpses wait for burial; else `bp.cancel` and place it elsewhere |
| PLAN_EXHAUSTED | year review now (`plan propose`) |
| PROJECT_BLOCKED | `bp preview`, then `bp.cancel` and place at another site, or fix the material |
| YEAR_REVIEW | §5 year review |
| GHOSTS | `inspect` `what=tombs` (causes per body); `tombs.repair`; `no_coffin` → the kernel provisions coffins (`inspect tombs` `prov`: want/short/stock/order/proj); `bp.place tombs` only when `prov` reports no space and no project; `no_body` → a memorial slab |
| HOSPITAL_DRY | follow the recipe in the line (`inspect` `what=water_sources`: a bank to zone or a dig); until water is accepted, a dry hospital zone is worse than none |
| MOOD_RISK | supply the missing class now (dig, trade, butcher); a mood job is never cancelled |
| ORDER_BAD | a make-item order without `item_subtype` (DF crash) was removed; never queue such orders, use `order.add` with `item_subtype` |
| DEPOT_MISSING | a caravan came and no depot stands; the kernel queued a `depot` project: check `status`/`proj`, keep O1 down for builders in PEACE. "does not progress: why" = the planned depot is stuck; without a fortcore depot the kernel moves it inside the entrance after 5 failed resumes (`inspect workload` `depot_move`) |
| CUTOFF | citizens lost the walk group of their food, drink or beds; the msg names the tile. `inspect reach`; a project still building there: `bp.cancel {proj, undo:true}`; a built wall or raised bridge: tell the player at once (no deconstruct verb) |
| SEAL_LEAK | the gates are up and a route remains: `inspect entrances` names the leak (tile, door/bridge state); tell the player; place a wall there (`bp.place`), never lower the bridges |
| PERIMETER_BROKEN | the kernel re-queued the lost walls/doors (`rp…` project); `inspect perimeter` after a day; tell the player about pieces it could not re-queue (bridges) |
| AUTOLABOR_LEGACY | autolabor ran in legacy mode (the engine of the Run 9 crashes) and the kernel could not set it to monitor (`fixed=0`; a switch that worked is only a kern.log line): tell the player at once (disable autolabor by hand) |
| TOOL_BLOCKED | Miners/Woodcutters members hold no pick/axe while their jobs wait (`inspect workload`: `blocked`, `tools`); `reserved` → squad uniforms hold the tools (military weapons); otherwise tell the player: toggling the detail in the work details screen may make DF hand the tools out (untested); `tools.equip_update` and moving a tool into a hand need his explicit yes (fair play) |
| REFUGE_FAIL | the civ alert left a burrow without drink, food or beds for the fort's interior (`Innen+`) or no confinement; `inspect refuge`; fix the refuge (stockpile, beds, well) in the next plan |

## 8. Readiness gate (only readiness raises max-pop)
- **R0:** cap 55 (pop-control `max-pop 55`, `wave-size 8`).
- **R1 sealed:** worst-case audit passes (all bridges lowered, doors open, trap hall removed: no
  edge→Z3 path; refuge reachable without Z2/Z3; civilian path ≠ attacker path; caverns sealed);
  Kern+ and Tiefe+ exist; 2 levers per bridge.
- **R2 grow to ≤ 75:** R1 + drill passed ≤ 100,800 ticks ago (bridges up ≤ T+900, worn ≥ 90 %,
  nobody outside at T+1,200, 0 double toggles) + soldiers ≥ 15 % of adults and ≥ 8 with combat
  value ≥ `cv_min` + ≥ 30 armed traps on every attacker path + food ≥ 60 days, drink ≥ 170 days.
- **R3 ≥ 80:** only with D-01 = B and ≥ 20 % of soldiers in iron or steel.
- Readiness red: max-pop freezes at the current population and beauty pauses.

## 9. Decisions (the player's answers in `config/decisions.yaml`; defaults until they answer)
D-01 cap option A (≤ 75) | D-02 difficulty unchanged | D-03 idle rule (> 40 % for 3 days, useful
backlog only) | D-04 work-now off | D-05 agitation-rebalance off | D-06 tailor confiscate and
cleanowned off | D-07 visitor cap, weather, baby caps unchanged | D-08 caravan `flags1.left` edit
dropped (use `fix/stuck-merchants`) | D-09 never cook plump helmets, not even in a famine |
D-10 emigration, deteriorate off | D-11 timestream accepted | D-12 army 15 % at pop ≤ 55, 20 %
from 60 | D-13 no automatic beauty pause (wealth is logged) | D-14 peace_gates down (bridges down in
PEACE; the arrival reflex raises them; `up` keeps them up outside caravan/migrant windows).
Only the player changes these. Never store a "consent" for anything on the §1 blocklist.

## 10. Doctrine in 30 lines
**Site and start** (§4). Year 1 follows `plans/year1.json` (§11).
**Geometry (fortcore).** Outside → O1 3-wide drawbridge with 2 levers inside → walled bailey with
depot and 2-tile overhang → trap hall (1 wide, ≥ 40 tiles, ≥ 3 bends, weapon traps ≤ 10
components, stone-fall filler, no cage traps on the main path) → 7x7 killing field beside a roofed
crossbow gallery behind fortifications (same level, reached only from Z3) → B1 inner bridge →
gatehouse and barracks + military stair → B2 core seal
→ civilian core (own stair, farms, workshops, stockpiles, well, hospital with own water, tombs,
dining, bedrooms). Refuge Tiefe+ ≥ 3 z below the core with its own well, food and beds.
**Barriers** are only raised bridges and walls; doors count for nothing. Smooth outer natural
walls. No shortcut bridges. Metrics use the real state of every bridge and door.
**Siege reflex (in game, you only read it):** visible invaders → SIEGE in the same step, timestream
off, FPS cap 30, civ alert on Kern+, squads Ready at their stations, bridges up by T+600 when nobody
is outside, BREACH fallback at T+900. RECOVERY only on 0 visible invaders for 2,400 ticks; bridges
are lowered stepwise. **Arrival lockdown** (no manifest needed): an arrival popup or report, INVASION
or the first armed hostile in sight raises every lever-linked bridge, forbids the entrance doors,
holds the clock and, once its lever pulls are done (≤ 2x the lever latency, 450-1500 ticks), sounds the alert, listing
the lever tiles (`Hebel+`) while pulls are pending; until threat 0 for 2 days.
**Military:** squads A, B melee, C crossbows, ≤ 10 each; Constant training, never Off duty;
Replace clothing + full metal + shield; KPI is worn %, never "assigned". Kill orders only inside
manifest kill boxes, never into shafts or stairs. No civilian reserve squads.
**Captives:** haul inside at once, then a pit zone; comrades free caged invaders.
**Economy:** natives first (orders library, labormanager monitor, suspendmanager, buildingplan,
autochop wood ≥ 14, autobutcher low, tailor, seedwatch on farmed crops at 12). KPI = 0 starving
postings, not idle %. Idle > 40 % for 3 days → useful backlog only, never filler digging.
**Moods:** all 12 moodable workshop types in P1; stock ≥ 10 cloth, leather, bone, shell, gems, bars
from P1; never cancel a mood job.
**Labor:** labormanager monitor; economy staffs the Miners (dig backlog, 2-4), Woodcutters (logs) and
Hunters (famine; 1 for a short bone/shell/leather mood stock) details itself; you never change work details.
**Dead:** one 1x1 tomb per coffin, free tombs ≥ open corpses + 6; autoslab, burial, preserve-tombs.
**Food/drink:** drink ≥ 170 days, food ≥ 60, ≥ 5 meal kinds; plump helmets are brewed, never cooked. Farms,
autofarm thresholds, fishers and meals follow the citizens (economy; `food_low` wakes below 30 days).
**Happiness:** dining hall → own bedrooms (≥ 500) → general temple (≥ 2,000 on petition) → tavern →
library. 0 naked. Stress KPI: share with category ≤ 1.
**Beauty:** only `used` rooms, only in PEACE with R1 green; artifacts and masterworks on pedestals.
**Water and caverns:** light aquifer only via the probe stair (damp report → stop, never
re-designate); every breach of water or caverns through a 2-wall airlock; caverns stay sealed.
**Trade:** depot in the bailey, O1 down only while no hostile is visible; ratio ≥ 1.5. Goods come
from stockpiles named `dfllm-trade` (logistics autotrade; fortcore stage 1 builds one next to the depot,
plus the `dfllm-melt` automelt pile).
**Speed:** PEACE timestream 500; ALERT FPS cap 100; SIEGE/BREACH/DRILL and any lockdown timestream off,
FPS cap 30; no Lua quicksaves; DF autosave yearly.

## 11. Phases (`plans/year1.json`; the runner advances when all deliverables pass)
| Phase | Deliverables |
|---|---|
| P0 | baseline; probe stair (damp → stop); fortcore stage 1; farms (own template, soil sites) |
| P1 | dining, office (manager: chair + office zone), all 12 moodable workshops (`workshops`) + still + kitchen, mood stock goals |
| P2 | killing field, gallery, B1, barracks (fortcore stage 2), captive pit (`captives`), squad A |
| P3 | smelter + wood furnace (`furnaces`), hospital, orders basic + rockstock |
| P4 | 1 caravan traded, bedrooms, tombs, tavern, temple |
| P5 | fortcore stage 3, squads B and C, drill 1 passed, R1, drink ≥ 170 d, food ≥ 60 d |
| P6 ★ (Y2) | military orders, trap hall armed (fortcore stage 4), metal ≥ 80 %, ≥ 300 bolts, R2 cap raise |
| P7 ★ | beauty in used rooms; R3 only with D-01 = B |
★ = entered only when your plan's `phase_target` reaches it.

## 12. Token budget
≤ 3 M input tokens and ≤ 30k output tokens per real hour (alarm at 5 M). ≤ 6 wakes per hour.
Brief ≤ 1.5k, status ≤ 300, wake line ≤ 150. If a wake needs more than 5 tool calls, stop, write
one line for the player and wait for the next wake.

## 13. When something looks wrong
- `dfllm status` says `follow: OFF`: start `Monitor` on `dfllm follow` again; silence from a dead follow is not "all is well".
- `dfllm status` stale or no heartbeat for 120 s: read `dfllm supervise --once --dry-run` and tell
  the player (a scheduled supervisor, if set up, handles it); do not restart DF by hand.
- A command was refused: read the outbox `msg`; fix the args; never retry with a different verb to
  get around a refusal.
- The fort is in SIEGE/BREACH: do nothing tactical. Read `status` every few minutes; act after
  SIEGE_END.
- Unsure whether something is fair: it is not. Ask the player.
