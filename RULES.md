# RULES: df-llm-helper v2 (the only always-read doc)

DRAFT (WP11, wave 1). Binding sources behind it: `docs/v2/DESIGN.md` (why), `docs/v2/CONTRACTS.md`
(exact formats), `docs/v2/DOCTRINE.md` (gameplay). Do not read those on a wake; read them only to
change the system. Never read ERFAHRUNGEN.md, transcripts or v1 docs as working memory.

## 0. What runs where
- **In game:** the kernel `lua/dfllm` (one frame dispatcher plus modules). It defends the fort,
  runs the approved plan and writes files under `<DF>/dfllm-runtime/<save>/`. Every reaction
  needed within one game day happens in game, without you.
- **Python** `python -m df_llm_helper <cmd>` (alias `dfllm`) only reads those files and writes
  the inbox. It never calls DF in steady state.
- **You (orchestrator):** the main Claude Code session, at most 60k context. You run `Monitor` on
  `dfllm follow` and spawn one fresh Sonnet subagent per wake line (Opus only for the year-1 plan
  and postmortems). You are a yearly planner and an exception handler, never a tactical controller:
  a game month passes in about 75 s.

## 1. Hard rules
1. **Fair play.** Only UI-equivalent actions. Never: createitem, dig-now, build-now, reveal,
   teleport, fastdwarf, `--instant`, `digv`/`digvx`, `digtype --hidden`, `caravan extend|happy`,
   autodump, locate-ore, prospect, showmood, `fix/retrieve-units`, reads of hidden tiles or
   `water_table`, edits of units, skills, items, positions or timers.
2. **One door into the game.** Change the game only with `dfllm cmd <verb>` (closed verb set, §5)
   or `dfllm plan apply`. No inline `lua`, no `claude/*` scripts, no `dfhack-run` except the
   allowed forms (`dfhack-run dfllm …`, `load-save`, the embark helper before adopt). The
   PreToolUse hook (`dfllm lint --cmd`) blocks the rest; never work around it.
3. **Never pause, never unpause** to "help". The arbiter owns pause and tempo; you may only send
   `pause` with a TTL of at most 600 s when you must think about a running crisis.
4. **Never load an older save** (no save-scumming). Never kill DF yourself; the supervisor restarts
   only in PEACE right after an autosave.
5. **Opt-in per save.** The kernel acts only on saves with the `dfllm` marker (`dfllm adopt`).
   Gordon's own forts (e.g. Inchcraft) stay untouched: never adopt them.
6. **Growth is earned.** Never raise the pop cap, start beauty or wealth projects, or open caverns
   outside the readiness gate (§8). Approve ★ phases only when the gate is green.
7. **No new tooling in play.** If something is missing, write a short note for Gordon; code changes
   go through the repo (tests, lint, commit as Gordon with Co-Authored-By, push).

## 2. Talking to Gordon
- German, informal ("du"), short and honest: what happened, what you did, what is open.
- Chat only. Never send push notifications.
- Decide small things yourself; ask only for big risks and for the D-decisions (§7).

## 3. Run v2
```
dfllm doctor                 # ticks/s, kernel ms per module, frame gaps, stalls
dfllm status                 # <= 300 tokens: mode, phase, pop/cap, readiness, alarms
dfllm brief                  # <= 1.5k tokens: digest for a decision
dfllm follow                 # Monitor target: one wake line per event that needs you
dfllm events --cls A [--since N]
dfllm plan propose|check|apply
dfllm cmd <verb> '<json args>'
dfllm bp list | bp preview <tpl> | bp sites <tpl>
dfllm supervise --once       # Windows task DF-Aufsicht runs this every minute
```
In game (via `dfhack-run`): `dfllm boot|adopt|stop|status|selftest|restore`. `onMapLoad.init`
runs only `dfllm boot`; without the marker it does nothing.

**Session start:** `dfllm doctor`, then `dfllm status`, then start `Monitor` on `dfllm follow`.
Do nothing else until a wake line arrives.

## 4. New fort (embark, once)
Procedure and fair-play limits: `tools/embark/README.md`. In short:
1. Title → new game in the existing world: `python tools/embark/embark.py newgame`.
2. Shortlist world tiles from the vanilla world map (not world data), then
   `embark.py scan WX,WY[,LX,LY] …`: it places the rectangle, reads the warning popup and the
   embark panel and ranks the sites against the DESIGN §5.1 checklist (Dark Fortress and old forts
   ≥ 10 world tiles, not evil, savagery low/medium, trees, flowing water, aquifer none (light only
   with the probe protocol), flux/ore if shown, shallow soil, temperate, 3x3 or 4x4).
3. `embark.py embark WX,WY[,LX,LY]` refuses a rejected site and any criterion the panel did not
   show, unless that one id is named with `--waive ID` after checking it by eye (no blanket
   waiver). It spends every embark point: 3 picks, 2 axes, anvil,
   bars, wood, plump helmet and surface seeds, 1-2 breeding pairs; skills 2 miners,
   mason/engraver, carpenter, brewer/grower, mechanic, cook/doctor.
4. In the fort: `dfhack-run dfllm adopt`. This sets the marker, loads `plans/year1.json` and boots.

## 5. Wake protocol
- `dfllm follow` prints one wake line (≤ 150 tokens) per class-A event, rate-limited: ≤ 1 per type
  per 5 min, bursts merged within 60 s, ≤ 6 per hour. Class B goes into the brief, class C is a log.
- Per wake line spawn **one fresh Sonnet subagent**. Give it this file plus `dfllm brief`. It may
  make at most 5 tool calls and returns at most 100 tokens: what it saw, the one command it sent,
  what to watch next.
- **Exception:** `dfllm events --cls A --since N`, then at most one `dfllm cmd`.
- **Year review** (YEAR_REVIEW, about every 13-15 min real time): `plan propose`, edit a few fields
  (phase_target, seasons[].build, military, supply, trade), `plan check`, `plan apply`. One review
  approves 4 season plans.
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
| `pause` / `unpause` | `{ttl_s ≤ 600, why?}` / `{}` | rarely; `unpause` releases only an inbox pause. A pause by Gordon, by DF (save loaded paused) or by a popup is released in DF, by Gordon |
| `trade.want` | `{want?, sell?}` | tokens like `bar:iron`, `anvil`, `cloth` |
| `squad.sortie` | `{squad, target, approve:true}` | ALERT/SIEGE/BREACH/RECOVERY; rare, `approve:true` is a deliberate, logged decision; target = kill box id or position |
| `lever` | `{bridge, want}` | PEACE only |
| `inspect` | `{what, key?}` | read-only, ≤ 8 KB |
| `selftest` | `{suite?}` | quick or full |
| `module.enable` | `{module}` | re-enable a module the kernel backed off (KERN_FAULT) before its backoff ends, only once the cause is fixed |
There is no arbitrary Lua. Every reply lands in `outbox/<id>.json`; `dfllm cmd` prints it.

## 7. Class-A events and the first move
| Event | First move |
|---|---|
| SIEGE_END | read the summary; if losses > 10 % of citizens, write a postmortem note and lower `pop_ceiling` in the next plan |
| GATE_FAIL / BREACH | the fort already sealed itself (BREACH: Tiefe+ alert, B2 up, melee at B2). Do not lower bridges. Check `status` again after 600 ticks; tell Gordon |
| DEATHS_3PLUS | read the brief: cause (combat, thirst, mood, cave-in); fix the cause in the plan |
| DRILL_FAIL (2nd in a row) | read `ready.fail`; fix gear, squads or geometry; never raise the cap |
| KERN_FAULT | a module is backed off (`d.backoff_s`; the kernel re-enables it afterwards); note module and error for the repo; do not hot-patch; `module.enable` only after the fix |
| PERF_DEGRADED | `dfllm doctor`; the supervisor restarts DF only in PEACE after an autosave |
| DECISION_NEEDED | ask Gordon the question once; the default applies until he answers |
| PLAN_EXHAUSTED | year review now (`plan propose`) |
| PROJECT_BLOCKED | `bp preview`, then `bp.cancel` and place at another site, or fix the material |
| YEAR_REVIEW | §5 year review |

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

## 9. Decisions (Gordon's answers in `config/decisions.yaml`; defaults until he answers)
D-01 cap option A (≤ 75) | D-02 difficulty unchanged | D-03 idle rule (> 40 % for 3 days, useful
backlog only) | D-04 work-now off | D-05 agitation-rebalance off | D-06 tailor confiscate and
cleanowned off | D-07 visitor cap, weather, baby caps unchanged | D-08 caravan `flags1.left` edit
dropped (use `fix/stuck-merchants`) | D-09 never cook plump helmets, not even in a famine |
D-10 emigration, deteriorate off | D-11 timestream accepted | D-12 army 15 % at pop ≤ 55, 20 %
from 60 | D-13 no automatic beauty pause (wealth is logged).
Only Gordon changes these. Never store a "consent" for anything on the §1 blocklist.

## 10. Doctrine in 30 lines
**Site and start** (§4). Year 1 follows `plans/year1.json` (§11).
**Geometry (fortcore).** Outside → O1 3-wide drawbridge with 2 levers inside → walled bailey with
depot and 2-tile overhang → trap hall (1 wide, ≥ 40 tiles, ≥ 3 bends, weapon traps ≤ 10
components, stone-fall filler, no cage traps on the main path) → 7x7 killing field under a roofed
crossbow gallery at z+1 → B1 inner bridge → gatehouse and barracks + military stair → B2 core seal
→ civilian core (own stair, farms, workshops, stockpiles, well, hospital with own water, tombs,
dining, bedrooms). Refuge Tiefe+ ≥ 3 z below the core with its own well, food and beds.
**Barriers** are only raised bridges and walls; doors count for nothing. Smooth outer natural
walls. No shortcut bridges. Metrics use the real state of every bridge and door.
**Siege reflex (in game, you only read it):** visible invaders → SIEGE in the same step, timestream
off, civ alert on Kern+, squads Ready at their stations, bridges up by T+600 when nobody is outside,
BREACH fallback at T+900. RECOVERY only on 0 visible invaders for 2,400 ticks; bridges are lowered
stepwise.
**Military:** squads A, B melee, C crossbows, ≤ 10 each; Constant training, never Off duty;
Replace clothing + full metal + shield; KPI is worn %, never "assigned". Kill orders only inside
manifest kill boxes, never into shafts or stairs. No civilian reserve squads.
**Captives:** haul inside at once, then a pit zone; comrades free caged invaders.
**Economy:** natives first (orders library, labormanager monitor, suspendmanager, buildingplan,
autochop wood ≥ 14, autobutcher low, tailor, seedwatch on farmed crops at 12). KPI = 0 starving
postings, not idle %. Idle > 40 % for 3 days → useful backlog only, never filler digging.
**Moods:** all 12 moodable workshop types by the end of Y1; stock ≥ 10 cloth, leather, bone, shell,
gems, bars; never cancel a mood job.
**Dead:** one 1x1 tomb per coffin, free tombs ≥ open corpses + 6; autoslab, burial, preserve-tombs.
**Food/drink:** drink ≥ 170 days, food ≥ 60, ≥ 5 meal kinds; plump helmets are brewed, never cooked.
**Happiness:** dining hall → own bedrooms (≥ 500) → general temple (≥ 2,000 on petition) → tavern →
library. 0 naked. Stress KPI: share with category ≤ 1.
**Beauty:** only `used` rooms, only in PEACE with R1 green; artifacts and masterworks on pedestals.
**Water and caverns:** light aquifer only via the probe stair (damp report → stop, never
re-designate); every breach of water or caverns through a 2-wall airlock; caverns stay sealed.
**Trade:** depot in the bailey, O1 down only while no hostile is visible; ratio ≥ 1.5. Goods come
from stockpiles named `dfllm-trade` (logistics autotrade; no template builds one yet: ask Gordon).
**Speed:** PEACE timestream 500, SIEGE/DRILL off; no Lua quicksaves; DF autosave yearly.

## 11. Phases (`plans/year1.json`; the runner advances when all deliverables pass)
| Phase | Deliverables |
|---|---|
| P0 | baseline; probe stair (damp → stop); fortcore stage 1; farms (own template, soil sites) |
| P1 | dining, well, depot, offices, craftsdwarf, carpenter, mason, still, kitchen |
| P2 | trap hall, B1, barracks (fortcore stage 2), squad A |
| P3 | all moodable workshops (incl. forge), hospital, orders basic + rockstock (no smelter template yet) |
| P4 | 1 caravan traded, bedrooms, tombs, tavern, temple |
| P5 | fortcore stage 3, squads B and C, drill 1 passed, R1, drink ≥ 170 d, food ≥ 60 d |
| P6 ★ (Y2) | military orders, metal ≥ 80 %, ≥ 300 bolts, R2 cap raise (smelting returns with a smelter template) |
| P7 ★ | beauty in used rooms; R3 only with D-01 = B |
★ = entered only when your plan's `phase_target` reaches it.

## 12. Token budget
≤ 3 M input tokens and ≤ 30k output tokens per real hour (alarm at 5 M). ≤ 6 wakes per hour.
Brief ≤ 1.5k, status ≤ 300, wake line ≤ 150. If a wake needs more than 5 tool calls, stop, write
one line for Gordon and wait for the next wake.

## 13. When something looks wrong
- `dfllm status` stale or no heartbeat for 120 s: the supervisor handles it; check
  `dfllm supervise --once` output, do not restart DF by hand.
- A command was refused: read the outbox `msg`; fix the args; never retry with a different verb to
  get around a refusal.
- The fort is in SIEGE/BREACH: do nothing tactical. Read `status` every few minutes; act after
  SIEGE_END.
- Unsure whether something is fair: it is not. Ask Gordon.
