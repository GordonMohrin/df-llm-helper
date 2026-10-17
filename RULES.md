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
   `water_table`, edits of units, skills, items, positions or timers. One exception (Gordon, 16.10.2026, BUG-023):
   `tools.equip_update` lets `act.work_detail` set a tool-detail member's equipment update request
   (`uniform.pickup_flags.update`), so the dwarf fetches a pick or axe himself; moving a tool into a hand stays forbidden.
2. **One door into the game.** Change the game only with `dfllm cmd <verb>` (closed verb set, §5)
   or `dfllm plan apply`. No inline `lua`, no `claude/*` scripts, no `dfhack-run` except the
   allowed forms (`dfhack-run dfllm …`, `load-save`, the embark helper before adopt; a quicksave
   only as `dfllm save`). The PreToolUse hook (`dfllm lint --cmd`) blocks the rest; never work around it.
3. **Pause and tempo belong to the arbiter, with one exception (Gordon, 13.10.2026):** when the game is paused
   by DF (after a load, a restart or a popup) and nothing in the arbiter's own pause reasons holds it, you may
   resume it (`pause_state = false`, or Space on the main screen). Never pause to "help"; you may only send
   `pause` with a TTL of at most 600 s when you must think about a running crisis.
4. **Never load an older save** (no save-scumming). Never kill DF yourself; the supervisor restarts
   only in PEACE right after an autosave.
5. **Opt-in per save.** The kernel acts only on saves with the `dfllm` marker (`dfllm adopt`).
   Adopt only a fort the player gave you for this; the player's own forts stay untouched (Gordon:
   never Inchcraft).
6. **Growth is earned.** Never raise the pop cap, start beauty or wealth projects, or open caverns outside the readiness gate (§8). Approve ★ phases only when the gate is green.
7. **No new tooling in play.** If something is missing, write a short note for the player; code
   changes go through the repo (tests, lint, commit and push by the repo's rules), never into the
   running game.

## 2. Talking to the player
- In the player's language (Gordon: German, informal "du"), short and honest: what happened, what you did, what is open.
- Chat only. Never send push notifications.
- Decide small things yourself; ask only for big risks and for the D-decisions (§7).

## 3. Run v2
```
dfllm doctor                 # ticks/s, kernel ms per module, frame gaps, stalls
dfllm status                 # <= 300 tokens: DEFCON, mode, clock, lockdown, pop/cap, readiness, alarms
dfllm brief                  # <= 1.5k tokens: digest for a decision
dfllm follow                 # Monitor target: one wake line per event that needs you (--no-auto: no
                             # automatic placements; the path audit still runs)
dfllm audit [--snap ID]      # the path audit now (fresh audit snapshot -> bp.topo.audit -> verb audit)
dfllm events --cls A [--since N]
dfllm wait --until-interrupt [--timeout 15]   # returns at once on an unacked interrupt; keep calls short
dfllm ack [--n N]            # you saw the interrupts up to N (else the kernel applies their lockdown default)
dfllm plan propose|check|apply
dfllm cmd <verb> '<json args>'
dfllm bp list | bp preview <tpl> | bp sites <tpl>
dfllm supervise --once --dry-run   # liveness report (the restarting task is optional, not live-tested)
dfllm save                   # DFHack quicksave, verified by the save folder (not in SIEGE/BREACH/DRILL, <= 1 per 10 min)
```
In game (via `dfhack-run`): `dfllm boot|adopt|stop|status|selftest|restore` (`stop` in SIEGE/BREACH/ALERT keeps
the FPS clamp and leaves the popup guard until `boot`; never `stop --restore-fps` in a fight). `onMapLoad.init` runs only `dfllm boot` (`tools/migrate_v2.py --apply` sets it up); without the marker it does nothing.

**Session start:** `dfllm doctor`, then `dfllm status`, then start `Monitor` on `dfllm follow`. Do nothing else until a wake line arrives (right after a fresh adopt: §4 step 5 first).

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
- **New building:** `bp sites <tpl>`, pick S1-S3, `dfllm cmd bp.place '{"tpl":…,"site":"S1"}'`. ≤ 5 turns per building.
- **Without you** the kernel keeps safety and supply running and finishes the approved plan; it never starts a ★ item.

## 6. Inbox verbs (closed set; `dfllm cmd <verb> '<json>'`)
| Verb | Args | When |
|---|---|---|
| `plan.reload` | `{}` | after `plan apply` (apply sends it) |
| `bp.place` | `{tpl, site, p?, prio?}` | place a template at a ranked site |
| `bp.cancel` | `{proj, undo?}` | stop a project |
| `drill` | `{why?}` | PEACE only; the reflex acceptance test |
| `snapshot` | `{bbox?, purpose?}` | export revealed tiles (audit runs automatically); goes ahead of the kernel's exports; a refusal names the queue |
| `audit` | `bp.topo.audit` result | sent by `follow` or `dfllm audit` (they compute it), never `dfllm cmd audit` |
| `popcap.lower` | `{cap}` | lowers only |
| `tempo.lower` | `{fps, ttl_s}` | lowers only, never above the mode value |
| `pause` / `unpause` | `{ttl_s ≤ 600, why?}` / `{}` | rarely; `unpause` releases only an inbox pause. A pause by the player, by DF (save loaded paused) or by a popup is released in DF, by the player |
| `trade.want` | `{want?, sell?}` | tokens like `bar:iron`, `anvil`, `cloth` (any), `cloth:plant`/`silk`/`yarn` (also `thread:`), `armor:metal` (`:metal` = a metal material) |
| `trade.retry` | `{civ?, want?, sell?}` | PEACE; a second trade in the same visit: caravan at the depot, ≥ 3,000 ticks left |
| `squad.sortie` | `{squad, target, approve:true, gate?}` | ALERT/SIEGE/BREACH/RECOVERY; rare, `approve:true` is a deliberate, logged decision; target = kill box id or position. `gate:"O1"` (SIEGE only): out through O1 to a position outside: gather in the bailey (B1 up behind), O1 down, kill, recall, O1 up, back; refused below `sortie.worn` or when its cv < the hostiles near the target x `foe_cv` (the reply compares them) |
| `lever` | `{bridge, want}` | PEACE only |
| `inspect` | `{what, key?}` | read-only, ≤ 8 KB; `what=reach`, `entrances`, `defense`, `perimeter`, `refuge` (seal), `what=tombs`, `water_sources`, `what=orders` (blocked orders), `workload` (idle adults, unclaimed jobs, cancel reasons, free picks/axes), `trade` (merchant goods at the depot, last trades) |
| `tombs.repair` | `{}` | GHOSTS: the next care run repairs the tombs (any mode) and retries entomb |
| `order.add` | `{job, amount, item_subtype?, material?, material_category?, reaction?, frequency?}` | one manager order; make-item jobs need `item_subtype` (`ITEM_…`), else DF 53.16 crashes (refused) |
| `jobs.release` | `{all?, preventblocking?}` | resume suspended constructions; `preventblocking` is a lasting fort decision |
| `perimeter.record` | `{}` | no fortcore manifest: record the walls, doors and gates that seal the fort now, so PERIMETER_BROKEN can diff them after a siege |
| `bridge.rebuild` | `{bridge}` | the player's answer to DECISION_NEEDED `bridge_rebuild`: rebuild that gate anyway (in quiet PEACE; asked again after `perimeter.stop_after` more losses) |
| `selftest` | `{suite?}` | quick or full |
| `module.enable` | `{module}` | re-enable a module the kernel backed off (KERN_FAULT) before its backoff ends, only once the cause is fixed |
| `ack` | `{n?}` | interrupts seen up to n (default all); `dfllm ack` sends it |
There is no arbitrary Lua. Every reply lands in `outbox/<id>.json`; `dfllm cmd` prints it.

## 7. Class-A events and the first move
| Event | First move |
|---|---|
| SIEGE_START / INVASION / ARRIVAL | the kernel locked down (gates up, doors forbidden, alert, clock 30 t/s) before contact; citizens outside the alert's burrow are called home at once (`recall: 16 outside Kern+`; RECALL (B) says when all are in, `stuck` names who cannot come and why: tell the player). `dfllm ack`, read `status` (`clock`, `lever_latency_s`, eta); do nothing tactical; tell the player |
| INTRUDER / PREDATOR | a hostile can walk to the citizens (gate open or a leak) / a wild danger inside Kern+ or within `predator_near` (40) tiles of a citizen outside it (farther ones are only PREDATOR_FAR, class B). `dfllm ack`; read `status` and the brief; tell the player. An INTRUDER with `far: N tiles` gets no lockdown default (alarm.txt `far`); it comes again once the unit is within `lockdown_near` |
| LOCKDOWN | an interrupt stood unacked and the kernel applied its default. `dfllm ack`; read `status` |
| LOCKDOWN_PARTIAL | an entrance door does not hold its forbidden flag (named with what lies on its tile); the kernel tries it once more itself. Read `status` (`doors`, refused); tell the player; a wall or a second door for that opening (`bp.place tpl=seal at="x,y,z floor wall"`) |
| NO_DEPOT | `dfllm ack`; place a trade depot (`bp sites`, `bp.place`) |
| SIEGE_END | read the summary; if losses > 10 % of citizens, write a postmortem note and lower `pop_ceiling` in the next plan |
| GATE_FAIL / BREACH | the fort already sealed itself (BREACH: the refuge alert (one without drink only once Kern+ is breached or open), B2 up, melee at B2; why `destroyed`: an outer/inner bridge is gone, an open way, at once). Do not lower bridges. Check `status` again after 600 ticks; tell the player. Once every gate is up, the outside verified sealed and nobody hostile inside, BREACH falls back to SIEGE by itself (BUG-028) |
| BRIDGE_DESTROYED | a manifest bridge is gone from its footprint (building destroyers, or removed; BUG-030): the kernel stopped every pull, want, GATE_FAIL and STRANDED for it, `status` shows `DESTROYED`, in SIEGE a lost O1/B1 is a BREACH at once; `d.n`/`d.bd` = its losses / with building destroyers. Tell the player; nothing tactical; the kernel rebuilds it in quiet PEACE only (never in a fight or lockdown) until `perimeter.stop_after` (2) losses to building destroyers, then DECISION_NEEDED `bridge_rebuild` |
| SIEGE_DEEP | the deep defense (BUG-030; `why`: `destroyers` building destroyers in sight, bridges are no barrier; `army` hostiles > `stations.core_ratio` (3) x soldiers; `weak` worn < `stations.worn`): civilians confined to the separated refuge (BREACH level), every squad at the core station, no kill orders, no intake waves. Read `status`; tell the player; nothing tactical; after the siege: soldiers, metal, a stocked refuge |
| STRANDED | citizens cut off from drink/food by our raised gates (BUG-028): `hold` a raise waits for them (until a hostile is within 30 tiles), `forced` it went ahead, `rescue` the kernel lowered the named inner/core bridges (never O1) and raises them again when they are through (`done`, `abort`), `refused` no rescue and why (O1 down, not sealed: the leak tile, a hostile), `relax` the alert's burrow held them from drink/food (BUG-031: the kernel moved or ended the alert; in SIEGE/BREACH only once dehydrated or starving, REFUGE_SWITCH (B) names every switch): tell the player at once; never lower bridges yourself |
| SUPPLY_OUTSIDE | most of the drink or food stock lies outside Kern+ and the refuge (`d.days` inside): tell the player; the next plan builds `stockroom` (barrel food stockpile + still in the core; `plan propose` drafts it, after a siege `plan check` refuses a plan without it while < 90 days lie inside) |
| BRIDGE_CRUSH | a unit died on or next to a bridge just pulled or moving (bridge, unit, the pull's tick, how it was matched): tell the player at once; `events` for the GATE lines of that bridge (who waited, GATE_FORCED); the bug goes to the repo (BUG-027) |
| WAVE_FAIL | an intake wave or a sortie through O1 went wrong (`why`: losses, past_b1, breach, stuck = the field not clear, left_outside = O1 raised with soldiers outside); the kernel closed O1 / recalled the squad: tell the player; `events --type INTAKE`/`SORTIE`; no lever by hand |
| GATE_FORCED | a SIEGE/BREACH raise went ahead onto the named units because a hostile stood at the gate (`force_near`, BUG-027); expect their DEATH; tell the player. A `blocked` GATE_FAIL names who holds a bridge (never raised onto them): tell the player to move them (a soldier at his squad's station: military re-stations the squad itself, STATION_MOVED (B), BUG-032) |
| DEATHS_3PLUS | the line names the causes; the brief lists the season's deaths by cause; fix the cause in the plan |
| DEATHS_PREVENTABLE | ≥ 2 citizens dehydrated or starved within a month (stock days, units, patients in the line): `inspect` `what=reach` (forbidden or cut-off drink/food), `what=refuge`; patients → `what=water_sources` (hospital water); tell the player; fix access in the plan |
| DRILL_FAIL (2nd in a row) | read `ready.fail`; fix gear, squads or geometry; never raise the cap |
| SIEGE_UNREADY | readiness is R0 in PEACE (monthly while it fails): the line names the blockers (§8), the audit's bypass / refuge route with its fix, the ways in without door or bridge and the traps. A route with `(fix: seal at=audit)`: follow already placed that seal (PEACE, not with `--no-auto`: then `dfllm cmd bp.place tpl=seal site=S1 at=audit`); `(no wall tile: ...)`: `inspect` `what=entrances` and tell the player. `inspect` `what=entrances`; close each open way in with `dfllm cmd bp.place tpl=seal site=S1 at=last` (door on a floor, wall on the ramp top, hatch on a stair; a shrub carries its piece (BUG-041: no gather first), a sapling or a door the route passes beside gets the neighbour that closes it; openings a seal builds or built are left out, ≤ 6 per seal: place it again for the rest; one `seal:piece` line each, `seal:note` for what it left out, in cli.log), put the missing fortcore pieces into the plan; then `dfllm audit`; tell the player |
| KERN_FAULT | a module is backed off (`d.backoff_s`; the kernel re-enables it afterwards); note module and error for the repo; do not hot-patch; `module.enable` only after the fix |
| PERF_DEGRADED | `dfllm doctor` (`top cost:` names the owner and its K.calls; a `snapshot exports starve` problem names who holds the queue, BUG-033); the supervisor restarts DF only in PEACE after an autosave |
| DECISION_NEEDED | ask the player the question once; the default applies until they answer. `food_low`/`famine`: the line names what the kernel did itself (`auto`: fishery asked/queued, gatherers added; BUG-038: not the player's choice), the blockers (`block`: kitchen, cook ingredient, fish_zone, hunt, farms, gather, a fishery before its request) and the options (fishing zone by hand, `trade.want` food, butcher, gather, `popcap.lower`). `build_blocked`: `inspect` `what=workload` (`construction.blocked`: kind, pos, fails, why); the kernel already unforbade the items on the site; corpses wait for burial; else `bp.cancel` and place it elsewhere. `manager_absent`: the manager is injured/in a mood/gone and orders wait unvalidated: ask for an acting manager (nobles screen; the kernel never replaces a holder). `manager_office` (BUG-042: orders unvalidated 2 days, an able manager): the reason; his office lacks a chair/table: the kernel placed them (MANAGER_OFFICE, B), `not built: no free chair` = add the task at a workshop by hand, no office zone = `bp.place office`. `drink_low` (< 60 drink days): `block` (`unvalidated` brews wait for the manager, still, plants, barrels, brewer), `auto` `bridge_rebuild` (BUG-030): a gate building destroyers broke `stop` times is not rebuilt (the line: losses, races, years, rebuilds, items, links): ask: rebuild (`dfllm cmd bridge.rebuild '{"bridge":"O1"}'`), walls on its footprint + a door entrance or a second outer gate (plan), or leave it (default; the deep defense holds) |
| PLAN_EXHAUSTED | year review now (`plan propose`) |
| PROJECT_BLOCKED | `bp preview`, then `bp.cancel` and place at another site, or fix the material; `build_lost` names the missing pieces (`B1`, traps) and the kernel retries the stage itself (`retry n/8`): wait for it unless the line says the retries are spent. A seal's `(no material for door: no rock, no logs)`: economy orders its doors/hatches in the stone or wood the fort has and retries once one can be made (MATERIAL_SHORT, B, says what is missing): tell the player (logs, stone: follow places the bedrooms dig). `door unsuitable at x,y,z: wall instead` (`walled`): a door needs a wall beside it, the kernel built a wall there (it shuts that way for good): tell the player. `parked` (BUG-037: blocked for good >= `queue.park_days` 30): no slot, pause, keeper or PLAN_EXHAUSTED waits for it, the kernel never cancels it: ask the player, then the line's `bp.cancel` (no undo). `status` `queued: N behind <slot holders>` / `runner: no run ended for N d`: `dfllm doctor`, `inspect` `what=modules` |
| YEAR_REVIEW | §5 year review |
| GHOSTS | `inspect` `what=tombs` (causes per body); `tombs.repair`; `no_coffin` → the kernel provisions coffins (`inspect tombs` `prov`: want/short/stock/order/proj); `bp.place tombs` only when `prov` reports no space and no project; `no_body` → a memorial slab |
| HOSPITAL_DRY / HOSPITAL_REMOVED | follow the recipe in the line (`inspect` `what=water_sources`: a bank to zone or a dig; a standing cistern: what its well lacks, BUG-031; cavern water never). A dry hospital is worse than none: once a patient passes thirst 25,000 the kernel removes its zones itself (HOSPITAL_REMOVED: zones, patients; BUG-034): tell the player; water before a new hospital (`plan check` refuses one without accepted water near it, `plan propose` drafts a cistern; BUG-040: `bp sites hospital` offers only sites within 30 tiles of accepted water and says which; a bucket-fed cistern needs revealed open water in reach, CISTERN_DRY (B) names a done one that stays dry) |
| MOOD_RISK | supply the missing class now along the named `route` (dig, trade, butcher; leather: tannery, hunters' bolts; raw glass and cut gems: economy's glass chain, sand zone + bags + glass furnace + fuel, GLASS_BLOCKED (B) names what stops it; rough gems, bars, leather: never glass); a mood job is never cancelled |
| QUICKSAVE_FAILED | `dfllm save` found no new save folder (follow's own wake): the game is not saved; tell the player at once, `dfllm save` again in 2 min or save by hand |
| ORDER_BAD | a make-item order without `item_subtype` (DF crash) was removed; never queue such orders, use `order.add` with `item_subtype` |
| DEPOT_MISSING | a caravan came and no depot stands; the kernel queued a `depot` project (after a siege: in RECOVERY/PEACE, the line says so; its building material as for walls, `no material for depot: ...` = tell the player): check `status`/`proj`, keep O1 down for builders in PEACE. "does not progress: why" = the planned depot is stuck; without a fortcore depot the kernel moves it inside the entrance after 5 failed resumes (`inspect workload` `depot_move`) |
| CUTOFF | citizens lost the walk group of their food, drink or beds (confirmed on groups read again, BUG-021); the msg names the tile, a cut-off citizen and a stock tile with their groups. `inspect reach`; a project still building there: `bp.cancel {proj, undo:true}`; a built wall or raised bridge: tell the player at once (no deconstruct verb) |
| CAVERN_PLUG | a dig broke into a cavern (BREACH_STOP `cavern`/`cavern_lake`; `damp` is aquifer seepage only), or the daily shaft check found an explore shaft open to one in any state (`state`: running, stalled, done, cancelled ...; kern.log `cavern check:` names each shaft and why it is or is not plugged). `queued`: the kernel plugs the explore shaft (its two top stair tiles channelled, then a constructed wall each; the lower one is given up if DF does not reach it within a day); `done`: the walls stand; `failed`/`none`: tell the player at once, a constructed wall on the named tile by hand. A hatch or door is no plug (the kernel walls below it or removes it in PEACE). R0 (`caverns`) until the wall stands; `bp.cancel` the explore without undo (unless done or cancelled) |
| SEAL_STUCK | an open seal or plug built nothing for `seal_first.stuck_days` (3, config/baseline.json `runner`): it stops pausing the other projects; the line names the open pieces and why (`mat`, `blocked`, BUG-041 `wait`: a job nobody has the labor for, a piece no citizen reaches); `plan check` shortens it after 28 days. Tell the player the open way in; no material: logs, a stone dig (follow places it); a refused tile: `bp.cancel`, then `seal at=last` again, or a wall by hand. Seal first (Run 11 siege 8): a seal or plug always runs first (first slot, dig priority 1, its work orders on top) and in PEACE pauses housing/work projects until done (`status` `seal open: N pieces (id), others paused`; never defense, tombs, the depot, repairs, food/drink in an emergency); `plan check` warns when other new builds come before a seal or an open seal pauses them |
| SEAL_LEAK | the gates are up and a route remains: `inspect entrances` names the leak (tile, door/bridge state); tell the player; `dfllm cmd bp.place tpl=seal site=S1 at=last` walls it (walk groups pass doors; an open route without a roofed tile gets a wall on its first tile that cuts it from the map edge; a leak through a door is left out with a note: decide by hand), never lower the bridges |
| PERIMETER_BROKEN | the kernel re-queued the lost walls/doors (`rp…` project); a lost bridge waits for quiet PEACE (`wait`, its own peace-only `rp…`) or the player (`held`); `inspect perimeter` after a day; tell the player about pieces it could not re-queue |
| AUTOLABOR_LEGACY | autolabor ran in legacy mode (the engine of the Run 9 crashes) and the kernel could not set it to monitor (`fixed=0`; a switch that worked is only a kern.log line): tell the player at once (disable autolabor by hand) |
| TOOL_BLOCKED | Miners/Woodcutters members hold no pick/axe while their jobs wait; `d.bk`/`d.blk` name the blocker (`inspect` `what=workload key=tools`: every tool and member record). The kernel repairs `labor`, `tool2`, melt marks and forbidden tools itself; `reserved` → military weapons; `alert`/`burrow`/`walk`/`jobs` → which burrow or walk group keeps them from the tools or jobs; `pair`/`pool`/`upair`/`fetch`/`pending`/`none` → DF's equipment state: tell the player with the records (no verb fixes it). `tools.equip_update` on since Gordon's yes (16.10.2026); moving a tool into a hand stays forbidden (fair play) |
| REFUGE_FAIL | the civ alert refused a burrow: an entrance reaches it without a door/hatch/bridge (`open to N entrances x,y,z ...`) or a hostile stands in it (BUG-018), or it lacks drink/food (beds only rank: `beds 18<23 (25% of 90 citizens)`; `Tiefe+: no drink`: a dry refuge holds only a breached or open fort, 7 days: its drink store `refuge_drink` (FR-69) or a well/cistern there); the fallback is `Innen+`, the refuge or the dead end `Tiefe+` without counts (BREACH level, 7 days), or none (`flee`: alert off, citizens flee on their own). `inspect refuge` (`open`, `hint`); tell the player; close the named entrances with the line's `seal at=...` (BUG-031: the tiles beside a door that leaves them open; `dfllm cmd bp.place` tpl seal, or `at=last`; `at=refuge` adds the hatch at the refuge's stair head); the next plan puts the refuge pieces first (beds: `refuge_beds`, §8 refuge gate) |

## 8. Readiness gate (only readiness raises max-pop)
- **R0:** cap 55 (pop-control `max-pop 55`, `wave-size 8`).
- **R1 sealed:** worst-case audit passes (all bridges lowered, doors open, trap hall removed: no
  edge→Z3 path; refuge reachable without Z2/Z3; civilian path ≠ attacker path; caverns sealed);
  Kern+ and Tiefe+ (with drink) exist; 2 levers per bridge.
- **R2 grow to ≤ 75:** R1 + drill passed ≤ 100,800 ticks ago (bridges up ≤ T+900, worn ≥ 90 %,
  nobody outside at T+1,200, 0 double toggles) + soldiers ≥ 15 % of adults and ≥ 8 with combat
  value ≥ `cv_min` + ≥ 30 armed traps on every attacker path + food ≥ 60 days, drink ≥ 170 days.
- **R3 ≥ 80:** only with D-01 = B and ≥ 20 % of soldiers in iron or steel.
- Readiness red: max-pop freezes at the current population and beauty pauses.
- R0 blockers (`ready.fail`; full table DESIGN §5.4): `audit`/`audit_old` no or stale audit → `dfllm audit`;
  `audit_fail`, `bypass` (a way in skips the trap hall), `refuge_sep` (refuge missing or on the attack path),
  `civ_sep` (no separate civilian/military stair), `caverns` (open, or a shaft not yet plugged: CAVERN_PLUG) → the
  audit's own reasons (AUDIT `fails`, SIEGE_UNREADY `afails`); `no_kern`/`no_refuge` burrow missing; `refuge_dry` the refuge has no drink (stock < citizens, no wet well; Run 11; the text names where it lies and its nearest accepted water, BUG-040) → its drink store `{"tpl":"refuge_drink","site":"S1","p":{"n":N}}` (FR-69: dug off the refuge room, a drink-only pile with N barrels from the citizens that takes from `dfllm-stock`; `plan propose` drafts it, `plan check` warns; no site: the line names a smaller one) or a well/cistern with a fill source; `hospital_out` a hospital zone outside Kern+/Tiefe+ (BUG-036) → a hospital inside Tiefe+ next to water (Kern+ next to it when Tiefe+ has none); `no_outer`/
  `no_inner` no O1/B1, `bridge:B` not built, `levers:B` < 2 linked levers → fortcore pieces; `lost:B` a gate given up after building destroyers → the player's answer (DECISION_NEEDED `bridge_rebuild`). `status` says `UNREADY`
  while R0 fails (SIEGE_UNREADY monthly); `drill never (auto: <why>)` → fix `<why>` or `dfllm cmd drill`.
- Audit `fails` name the fix (table DESIGN §5.4): `bypass: wall x,y,z floor -> X` / `refuge: on the attack path,
  wall x,y,z floor` = a constructed wall on that tile closes the route (`ramp`: on its top; `(+more)`: other routes
  remain): `dfllm cmd bp.place tpl=seal site=S1 at=audit`, then `dfllm audit`. Doors never fix an audit route.
- **Bypass gate (Run 10):** while the last audit names such a wall that no seal project builds, readiness stays R0 (`status`: `audit route: ...`), follow
  places `seal at=audit` itself in PEACE (not with `--no-auto`) and `dfllm plan check` refuses (ERROR) raising phase_target or adding builds unless a new
  build due now is `{"tpl":"seal","site":"S1","p":{"at":"audit"}}` (`plan propose` drafts it first). No wall tile, or its seal pending: a warning.
- **Refuge gate (Run 10):** `plan check` refuses phase_target P3+ while the refuge (Tiefe+, state `alert.ref`, `inspect what=refuge`) is missing, reached by
  an opening without a door (`sep` 0, or a current REFUGE_FAIL names open entrances) or has beds < ceil(citizens x `refuge.bed_pct` %) (config/reflex.json, 25), unless new builds or projects under way
  fix it: `{"tpl":"fortcore","site":"same","p":{"stage":3}}` (no refuge), a seal (`p.at` refuge: the hatch at the refuge's stair head, BUG-031, and REFUGE_FAIL's `fix` tiles; `p.at` last: doors), `{"tpl":"refuge_beds","site":"S1","p":{"n":N}}` (N <= 30 per room), no later than the plan's first other new build.
  Run 11: below P3 the same once the refuge burrow exists (raising phase_target or adding builds is refused, else a warning; no refuge_beds site or nothing `seal at=last` can close: a warning). `plan propose` drafts them first, after the audit's seal.
  `traps N` with a bypass is counted as if its walls stood; `traps 0` beside an armed hall without a bypass = a
  way into the hall's trap-free end: `dfllm audit` names the tile where the route enters the hall.

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
gatehouse and barracks + military stair → B2 core seal. From P5 also `gallery_o1` (fortifications in the O1
tunnel wall, reached through the inner gallery; `plan check` warns without it): an army waiting at a raised O1 is
shot from there (`squad.sortie` of squad C to its middle tile, after asking the player)
→ civilian core (own stair, farms, workshops, stockpiles, well, hospital with own water, tombs,
dining, bedrooms). Refuge Tiefe+ ≥ 3 z below the core with its own drink (`refuge_drink` or a wet well), food and beds.
**Barriers** are only raised bridges and walls; doors count for nothing. Smooth outer natural
walls. No shortcut bridges. Metrics use the real state of every bridge and door. **Refuge (BUG-018):** the civ
alert confines only to a burrow no entrance reaches without a door, hatch or bridge, one with drink first, and (Run 11) in a fight leaves it only when it is breached, open, dry or for the deeper refuge; else the dead end behind the
deepest stair (seal paints `Tiefe+` when missing), else nobody is confined and the citizens flee.
**Siege reflex (in game, you only read it):** visible invaders → SIEGE in the same step, timestream
off, FPS cap 30, civ alert on Kern+, squads Ready at their stations, bridges up by T+600 when nobody
is outside, BREACH fallback at T+900 (at once for a destroyed bridge). **Deep defense** (BUG-030): building destroyers
in sight, an army > 3x our soldiers or weak squads: civilians to the separated refuge, every squad at the core station; a gate they break twice is not rebuilt without the player. RECOVERY only on 0 visible invaders for 2,400 ticks; bridges
are lowered stepwise. **Arrival lockdown** (no manifest needed): an arrival popup or report, INVASION
or the first armed hostile in sight raises every lever-linked bridge, forbids the entrance doors,
holds the clock and, once its lever pulls are done (≤ 2x the lever latency, 450-1500 ticks; at once while citizens are outside Kern+: the doors wait up to 2,400 ticks for them), sounds the alert, listing
the lever tiles (`Hebel+`) while pulls are pending; until threat 0 for 2 days, or (Run 11) 2 days with every invader in sight beyond `lockdown_near` (40) of the citizens outside Kern+ and the entrances (LOCKDOWN_END `cause` far names them; they count for nothing until one comes that close, which re-arms it; an invader the raws call an animal, a mount left behind, is a wild danger). **Intake waves** (Gordon 16.10.2026,
`config/reflex.json` `intake`, on): in SIEGE the squads stand inside B1 with drink (BUG-029); when soldiers, worn, army
size, traps and the field allow it, B1 lets them into the killing field, rises, O1 lets up to 6 hostiles into bailey and
trap hall, rises, the field is cleared, the squads go back; INTAKE (B) per phase, WAVE_FAIL (A) when it goes wrong.
**Military:** squads A, B melee, C crossbows, ≤ 10 each; stations > 2 tiles from every bridge (BUG-032); in a siege a melee squad below half is refilled from healthy core civilians, never the refuge; melee squads fill only to the armor+weapon+shield sets (≥ 2; the siege refill to 5 goes beyond; metal short: the rest to C); Constant training, never Off duty;
Replace clothing + full metal + shield; KPI is worn %, never "assigned". Kill orders only inside
manifest kill boxes, never into shafts or stairs. No civilian reserve squads.
**Captives:** haul inside at once, then a pit zone; comrades free caged invaders.
**Economy:** natives first (orders library, labormanager monitor, suspendmanager, buildingplan,
autochop wood ≥ 14, autobutcher low, tailor, seedwatch on farmed crops at 12). KPI = 0 starving
postings, not idle %. Idle > 40 % for 3 days → useful backlog only, never filler digging. Run 11: what planned buildings wait for (doors, hatches, furniture) is ordered in the stone or wood the fort has; stone short with idle miners: a bedrooms dig (PROJECT_REQUEST why=rock, follow); picks short without bars: `pick` in trade.want (economy asks the caravans itself); metal short (no ore, bars short, worn < 80 %): economy asks every caravan for picks, axes, bars, metal gear and sells crafts for it, melts the invaders' gear.
**Moods:** all 12 moodable workshop types in P1; stock ≥ 10 cloth, leather, bone, shell, gems, bars
from P1; never cancel a mood job. No ore: `plan propose` drafts `explore` each season (`plan check` refuses metal unplanned, and soldiers with no metal route at all). No gems: green glass from revealed sand.
**Labor:** labormanager monitor; economy staffs the Miners (dig backlog, 2-4), Woodcutters (logs) and
Hunters (famine and `food_low`; 1 for a short bone/shell/leather mood stock, 2 after a mood missed leather), Fisherdwarves and, at `food_low` with
unclaimed GatherPlants jobs, the plant gatherers (4, off again at 60 food days; BUG-038; BUG-042: also below 60 drink days while the brewable plants are short) itself; you never change work details.
**Dead:** one 1x1 tomb per coffin, free tombs ≥ open corpses + 6; autoslab, burial, preserve-tombs.
**Rebuild (Run 11):** below `rebuild.pop` (10) citizens in a fallen fort (past P1 or once ≥ 12) only seal, plug, tombs, food/drink, beds, wall repairs and the depot run in PEACE/RECOVERY until 12 (`status` `rebuild: pop N < 10, ...`); `plan propose` drafts only those (no phase raise), `plan check` warns on the rest.
**Food/drink:** drink ≥ 170 days, food ≥ 60, ≥ 5 meal kinds; plump helmets are brewed, never cooked; fruit is brewed too (BUG-042). Farms,
autofarm thresholds, fishers, the fishing zone (safe water, never cavern or ice), a fishery for raw fish (asked again after a siege destroyed it) and meals follow the citizens (economy; `food_low` wakes below 30 days).
**Happiness:** dining hall → own bedrooms (≥ 500) → general temple (≥ 2,000 on petition) → tavern →
library. 0 naked. Stress KPI: share with category ≤ 1.
**Beauty:** only `used` rooms, only in PEACE with R1 green; artifacts and masterworks on pedestals.
**Water and caverns:** light aquifer only via the probe stair (damp report → stop, never re-designate); a dig that
breaks into a cavern (lake) is plugged by the kernel (CAVERN_PLUG); planned breaches via a 2-wall airlock; caverns stay sealed.
**Trade:** depot in the bailey, O1 down only while no hostile is visible; ratio ≥ 1.5. Goods come
from stockpiles named `dfllm-trade` (logistics autotrade; fortcore stage 1 builds one next to the depot,
plus the `dfllm-melt` automelt pile).
**Speed:** PEACE timestream 500; ALERT FPS cap 100; SIEGE/BREACH/DRILL and any lockdown timestream off,
FPS cap 30; no Lua quicksaves (only `dfllm save`, verified); DF autosave yearly.

## 11. Phases (`plans/year1.json`; the runner advances when all deliverables pass)
| Phase | Deliverables |
|---|---|
| P0 | baseline; probe stair (damp → stop); fortcore stage 1; farms (own template, soil sites) |
| P1 | dining, office (manager: chair + office zone), all 12 moodable workshops (`workshops`) + still + kitchen, mood stock goals |
| P2 | killing field, gallery, B1, barracks (fortcore stage 2), captive pit (`captives`), squad A |
| P3 | smelter + wood furnace (`furnaces`), hospital, orders basic + rockstock |
| P4 | 1 caravan traded, bedrooms, tombs, tavern, temple |
| P5 | fortcore stage 3, squads B and C, drill 1 passed, R1, drink ≥ 170 d, food ≥ 60 d (since Run 10 the refuge of stage 3 comes before any phase_target P3+: §8 refuge gate) |
| P6 ★ (Y2) | military orders, trap hall armed (fortcore stage 4), metal ≥ 80 %, ≥ 300 bolts, R2 cap raise |
| P7 ★ | beauty in used rooms; R3 only with D-01 = B |
★ = entered only when your plan's `phase_target` reaches it.

## 12. Token budget
≤ 3 M input tokens and ≤ 30k output tokens per real hour (alarm at 5 M). ≤ 6 wakes per hour. Brief ≤ 1.5k, status ≤ 300, wake line ≤ 150. If a wake needs more than 5 tool calls, stop, write one line for the player and wait for the next wake.

## 13. When something looks wrong
- `dfllm status` says `follow: OFF` (or `follow: OLD CODE`: restart it after a pull, BUG-042): start `Monitor` on `dfllm follow` again; silence from a dead follow is not "all is well".
- `dfllm status` stale or no heartbeat for 120 s: read `dfllm supervise --once --dry-run` and tell
  the player (a scheduled supervisor, if set up, handles it); do not restart DF by hand.
- A command was refused: read the outbox `msg`, fix the args; never retry with another verb to get around it.
- The fort is in SIEGE/BREACH: do nothing tactical. Read `status` every few minutes; act after SIEGE_END.
- Unsure whether something is fair: it is not. Ask the player.
