# dfpilot v2: decisions for Gordon

Gordon answers each decision once. The answer goes into `config/decisions.yaml` and stays there. Until he answers, the default applies, and the default is always "off" or "unchanged" (DESIGN §11.6, §15). The old exception register is retired: there are no cheat consents, and nothing in this file can allow an armok tool.

## How it works
- **File:** `config/decisions.yaml`, one line per decision: `D-NN: value  # comment` (CONTRACTS §9.16). Only bare words or integers, no nesting, no quotes. The Python reader (`schema.parse_decisions`, `fairplay.get_decision`) and the kernel's Lua reader use the same line regex.
- **Answered or not:** a comment that starts with `default` marks an open decision. `fairplay.pending()` lists the open ones. A module that needs an open answer emits `DECISION_NEEDED` (class A) with the id; the LLM passes the question to Gordon in chat.
- **Only Gordon writes the file.** The LLM never edits it, not even to record an answer Gordon gave in chat; Gordon edits it himself or tells the orchestrator to write his exact words. An invalid value falls back to the default, and `python -m dfpilot.lint --config` reports it.
- **Allowlist coupling:** some answers only take effect when `config/allowlist.json` also gains a command. The allowlist ships at the defaults, so a forgotten allowlist change fails safe (act.run refuses the command).

## Decisions

| Id | Question | Values | Default | Read by | If not default |
|---|---|---|---|---|---|
| D-01 | Option A (cap ≤75) or B (≥80) | `A`, `B` | `A` | readiness (cap), `plan check` | B: R3 (≥20 % of soldiers in iron or steel) may raise the cap to 80+; plans with `policy.option: B` pass `plan check` |
| D-02 | Difficulty changes (invasion cap, siege frequency) | `unchanged`, or a short word naming Gordon's choice | `unchanged` | nobody (S10 only reads the triggers) | Gordon changes Settings → Difficulty himself; the kernel never writes difficulty settings |
| D-03 | Idle rule | `rule`, `immediate`, `off` | `rule` | economy | `immediate`: act as soon as idle >40 % (Gordon's old memory rule), still only from the useful backlog and never filler digging; `off`: no idle reaction |
| D-04 | `work-now` | `off`, `on` | `off` | baseline | on: add `enable work-now` to `control-panel` (and `enable`) in the allowlist |
| D-05 | `agitation-rebalance` | `off`, `on` | `off` | baseline | on: add `enable agitation-rebalance` to `control-panel` in the allowlist |
| D-06 | tailor confiscate, cleanowned | `off`, `on` | `off` | baseline | off: baseline runs `tailor confiscate false`; on: add `confiscate true` to `tailor` and a `cleanowned` entry to the allowlist |
| D-07 | `visitor_cap` 30, WEATHER off, baby caps (per save) | `unchanged`, `visitor30`, `visitor30_noweather` | `unchanged` | arbiter (`act.setting`) | visitor30: visitor cap 30 at boot; `_noweather`: also weather off. Both are restored on unload; prefs files stay untouched |
| D-08 | caravan `flags1.left` edit | `dropped` | `dropped` | trade | none: stuck caravans use `fix/stuck-merchants` (allowlisted); the unit-flag edit is never offered again |
| D-09 | Cook plump helmets in a famine | `no`, `yes` | `no` | economy | yes: economy may lift the PLUMP_HELMET cook exclusion while food days are below the famine threshold |
| D-10 | emigration, deteriorate | `off`, `on` | `off` | baseline | on: add `enable emigration` and `enable deteriorate` to `control-panel` in the allowlist |
| D-11 | timestream | `accepted`, `rejected` | `accepted` | arbiter, baseline | rejected: arbiter never calls `act.timestream` (game runs at FPS_CAP), baseline does not enable timestream |
| D-12 | Army share | `<low>/<high>` in % | `15/20` | military, readiness | low share applies at pop ≤55, high share from 60 |
| D-13 | Automatic beauty pause at high wealth | `no`, `yes` | `no` | runner | yes: beauty projects pause above a wealth threshold (to be defined); without it, wealth is only logged with every threat event |
| D-14 | `peace_gates`: state of the gate bridges in PEACE (FR-49/55) | `down`, `up` | `down` | gate, siege | up: in PEACE the manifest outer/inner bridges stay up, and so do the lever-linked bridges a lockdown raised; they open only for a window (a caravan on the map, migrants arriving, an inbox `lever` down for that bridge), each while no hostile is visible, and close 600 ticks after it; RECOVERY lowers only the core seal |

### Decided by the development session (2026-10-23, delegated by Gordon: "triff du selber die entscheidungen")
Design questions that stood open between the dev session and the game session. They are not `config/decisions.yaml`
switches (D-01..D-14 stay Gordon's). The packages that carry them out are in `docs/v2/TRIAGE-run11-14.md`.
1. **Fortcore stage 3 (O1, B2, the refuge) comes before P3.** Runs 10, 11 and 13 lost forts between pop 54 and 60 with an
   open or missing refuge. The refuge gate of `plan check` already refuses P3+ without a separated refuge with beds;
   the phase table, the fortcore docs and the plan order now say P3 instead of P5. Stage 4 (the traps) stays P6.
2. **Auto-seal needs auto follow.** `follow --no-auto` stays an explicit opt-out. status and wake say "auto-seal off, N
   openings" instead of staying silent.
3. **Lost bridges (`perimeter.stop_after` stays 2, per bridge).** After the second loss to building destroyers the
   keeper does not ask a question nobody answers (`bridge_rebuild` DECISION_NEEDED): it replaces the bridge by a wall
   and a door (Run 13 lesson: "replace destroyed gates and bridges at once, or close them with wall + door; an audit
   FAIL is a stop signal"), reports it once and keeps the other bridges. A bridge lost to anything else is rebuilt in
   PEACE without the old waits.
4. **Seal first keeps its shape, with one change.** Defense builds (fortcore stages, barracks, gallery) run next to an
   open seal. The ore search does not pause for a seal ("explore never rests", post-mortem run 11).
5. **Recall (BUG-035/036) as built:** a door the lockdown locked may be opened again for a citizen who can only come
   through it (never with a hostile within 15 tiles); the larger "outside Tiefe+" numbers stay; `hospital_out` freezes
   max-pop until the hospital stands in Kern+/Tiefe+ next to accepted water.
6. **The refuge's drink counts wet wells only.** seal's alert rating follows readiness (`water.refuge_ok`): a dry well
   no longer frees Tiefe+ from the `breach_days` window.
7. **One food stockpile per quickfort `place` call.** DFHack's food import copies all raw materials per element (68 s
   for three piles in an old world, BUG-039). The runner splits place stages that hold food piles.
8. **No cavern water, ever.** No well over a lake, no piped cistern from a cavern lake, no opened shaft: the doctrine
   "caverns only behind a doubly sealed lock" stands (Run 3 fell to an opened shaft). Water for Tiefe+ comes from the
   drink store (FR-69) and, later and only if a source is accepted, a bucket-filled reservoir inside the fort.
9. **Parked projects stay parked, nothing is cancelled by the kernel (BUG-037).** One exception: after a `build_lost`
   farms project for lack of soil the kernel requests no further farms project until the cause changes (a new site).
10. **The gather zone covers reachable tiles only** (the citizens' walk group), and a designation that nobody works for N
    days is withdrawn (the 46 "unreachable" and the 250-450 unclaimed GatherPlants jobs).
11. **A fault inside the seal-first count is an event, not only a log line** (it must not hide behind a pcall).
12. **Lone thieves still start a lockdown** (Gordon 2026-10-15: "einzelne Diebe machst du richtig"), but the confinement
    is bounded: it ends by itself after a limit, the brief names the cause (unit, position), and a harmless intruder
    far from the fort is answered with a sortie offer instead of months of confinement.
13. **The kernel acknowledges harmless popups itself** (the game's own dismiss input, a UI action). Built (FR-75): the
    pest (gremlin, thief) and arrival popups, logged per kind; threats, undead and the embark intro are never cleared;
    any other text stays for the player unless `popups.other` is switched on (default off).
14. **Loose tools:** the kernel may give tools a stockpile and make the labor details ask for them the way the game's
    own equipment update does (`tools.equip_update`); it never moves an item itself.
15. **Mood dwarves:** no direct job or item for them (fair play). The levers are an earlier mood check, a drink stockpile
    beside the mood workshop, material delivery first, and an alert that names the dwarf.
16. **Population decline and missing migrants are diagnosed, not steered:** the status says whether children are counted
    as adults, which deaths, and the migration conditions the game documents.

### Confirmed or adjusted by the dev session after the review of the packages (2026-10-23)
17. **Decision 3 as built (A2):** besides the loss to building destroyers, a bridge that vanished `perimeter.vanish_after`
    (3) times with no destroyer in sight is replaced by wall + door too (a loop breaker against a ghost or a tantrum
    tearing the same bridge down; 0 = off). Only the first row or column of a wide footprint is closed.
18. **A stuck seal door becomes a wall (A1, BUG-044):** `seal_first.wall_days` (2) after SEAL_STUCK a door piece that
    cannot be built is replaced by a wall when another way in or out exists; the only way stays a door.
19. **Fort size guards:** the vacant-office blocker (A4) and the open-perimeter hold (A2) apply only from
    `perimeter.hold_pop` (30) citizens, so a young fort is never stopped from growing by what it cannot yet fill.
20. **Autofarm (B1):** the kernel disables `autofarm` below 30 food days or at the first emptied slot it filled (`farms.autofarm`
    'auto'; 'off' and 'keep' are config choices) and enables it again from 90 days. `disable autofarm` is on the allowlist
    (a player may run it). The thread/cloth reserve depends on autofarm's fibers: watch the live log.
21. **Military (A3):** the monthly unstick runs without `--drop`; the drill needs bridges, soldiers and a barracks, no
    longer phase P5, and only danger holds it (not merchants); a fort of 40+ citizens with a barracks staffs squad A before P2.
22. **Reclaimed forts (C2):** from 100 forbidden drink + food units the kernel unforbids them (400 a day, `forbid.burst_min`
    0 turns it off), because a reclaimed fort's whole stock is forbidden.
23. **Known open points (not decided offline, live data named in the bug files):** who removed the hand-added Planters
    members (BUG-057), who closes an opened tomb zone again (BUG-062), the cause of the 10 FPS clamp after a gremlin
    alarm (BUG-065), why the live seal door was suspended (BUG-044), what DF does with a door on a closure that waits
    behind door orders, the metal-gear causes of note 26 beyond the unstick, what DF does with the kit of a leaver in the
    militia turnover (FR-79, built offline for note 64: kern.log follows the worn % after every turnover), the recall
    part of note 23.

### Decided by the orchestrator on Gordon's behalf (2026-10-28, FR-95; Gordon delegated both questions to the orchestrator)
Runs 2, 4, 6, 9 and 14 lost their forts or their cores to aquifers: a level opened before its seal flooded, digs parked at
`breach:damp` for good (Run 14 site90: fortcore, bedrooms, stockroom and tombs). The aquifer research of 2026-10-28 (DFHack
53.16 docs: a natural rough aquifer wall feeds the open tiles beside and below it; a smoothed or constructed wall does not)
decided:
24. **Re-designating a dig after a damp report is allowed, because the lined-shaft procedure seals each level right away.**
    RULES §10 and DOCTRINE §1 change from "stop, never re-designate" to "observe and seal; stop only on visible water in our
    own dug tiles or a heavy aquifer". A damp report starts observe mode (AQ_OBSERVE) instead of a park; an aquifer is passed
    by `aqshaft` (dig, seal, watch per level). The damp acknowledgement is the one the code can set as the player does: the
    DFHack dig tool's damp marker (`dig.warmdamptoolbar`: the mining toolbar's "damp dig" button, Ctrl-D), applied through
    quickfort `marker = {damp = true}` on the designations of an aqshaft and of a dig in observe mode. The vanilla standing
    order of 53.12 ("mining designations ignore new warm/damp stone warnings") is not set: its field is not proven offline,
    and an unproven write is no UI action. Water >= 4/7 or a rising flow in our own tiles stops the dig for good
    (`breach:heavy_aquifer`, AQ_HEAVY, the shaft plugged). The old stop stays as a switch (`aqshaft.CFG.on`).
25. **The kernel may read the aquifer flag (`water_table`) of REVEALED tiles only**: what the vanilla drip icon and DFHack's
    warmdamp overlay show the player. Unrevealed tiles stay forbidden. The only reader is `snapshot.revealed_aquifer`, which
    checks `designation.hidden == false` before it looks at the flag (`snapshot.tile` `aq`); the lint rule hidden-read allows
    `water_table` only inside that function after its hidden check, and tests prove that a hidden tile's flag is never read.

### Answered by Gordon (2026-10-16, chat)
- **`tools.equip_update` on (BUG-023):** yes. A fair-play exception: when `act.work_detail` switches a tool labor on
  (Miners/MINE, Woodcutters/CUTWOOD), it also sets the member's equipment update request (`uniform.pickup_flags.update`,
  `plotinfo.equipment.update.weapon`), so the dwarf walks to a free pick or axe himself. `config/baseline.json` has it on;
  putting a tool into a hand (`moveToInventory`) stays forbidden.
- **`gate.force_near` = 3 (BUG-027):** confirmed. A SIEGE/BREACH raise goes ahead onto units on or next to a bridge only
  with a visible hostile within 3 tiles of its footprint (GATE_FORCED).
- **Lever burrow in BREACH (BUG-027):** confirmed. While no hostile is inside Kern+ and none within 20 tiles of the
  levers, the BREACH alert lists `Hebel+`, so civilians from the refuge may walk to a Kern+ lever.

### Answered by Gordon (2026-10-15, chat)
- **D-14 `down`:** "Brücken im Frieden sollen natürlich unten sein, damit die Zwerge die ganze Zeit diese Shortcuts
  runterlaufen können." The shortcut bridges over the trap corridor stay down in PEACE; the arrival reflex raises them.
- **Reflex triggers (`config/reflex.json`):** a lone thief or a repeated "An ambush!" popup triggering a full lockdown
  is wanted ("einzelne Diebe machst du richtig").
- **Hospital water (`water.zone_below`):** a Water Source zone above water one level down (a brook bed) stays not
  counted until a live test shows that the game accepts it.

### D-14 peace_gates: why the default is `down`
Run 9 (14.10.2026) lost 39 of 48 citizens to an army that walked in over four lowered bridges, and FR-49/55 ask for
gates that are closed in PEACE. The default stays `down` (the PEACE row of the DESIGN §3 mode table, "unchanged" like
every other default here) because closed gates break things the fort lives on, while the danger they guard against
is now covered at the arrival announcement:
- **Caravans.** Merchants enter at the map edge and need a wagon path to the depot. DF decides whether wagons come
  from the depot's accessibility when the caravan enters the map; trade.lua's O1 window opens only after that (it
  reacts to the caravan on the map), and a pull takes 256-400 ticks until a dwarf has walked to the lever (live L2).
  With `up`, wagons may stay home and a caravan may never reach a depot behind a raised bridge ("time" failures,
  FR-20/43). `down` keeps caravan access exactly as it works today.
- **Migrants** walk from the edge to the fort and would wait outside an `up` gate, unprotected, until the migrant
  window opens it.
- **The fort's own work outside:** woodcutters (autochop, wood >= 14), gatherers, hunters, fishers and the depot
  haulers all use the same entrance; fortcore has one (O1).
- **What `down` relies on (FR-49/51/52):** an arrival popup or report, INVASION or the first armed hostile in sight
  raises every lever-linked bridge (no manifest needed), forbids the entrance doors and holds the clock at 30 ticks/s
  in the same step, before the army reaches the entrance. At 30 ticks/s a 256-400 tick pull is 9-13 s of real time;
  `status` shows the measured `lever_latency_s`. An ambush that is seen before it is announced still gets the
  sighting reflex.

Choose `up` for a fort whose wagon path and outdoor work do not run through the gates, or when `lever_latency_s`
stays above the time an army needs from the map edge to the gate. On a fort without a manifest only the bridges a
lockdown raised are held up; the kernel does not know which of them a caravan needs.

## What is never a decision
These stay blocked whatever the file says (allowlist `blocked`, lint, hook): `digv`/`digvx`/`digl`, `digtype --hidden`, `fastdwarf`, `caravan extend|happy`, `autodump`, `locate-ore`, `prospect`, `showmood`, `reveal`, `createitem`, `dig-now`, `build-now`, `fix/retrieve-units`, `teleport`, `lever --instant` (the lever script is used only through `act.pull`, which queues a pull job), every other armok-tagged tool, inline `lua` and the v1 `claude/*` scripts. Reads of hidden tiles (their `water_table` too) and the aquifer APIs are lint errors; the aquifer flag of a revealed
tile is read only by `snapshot.revealed_aquifer` (decision 25).

Actuators with a dedicated act function stay out of the allowlist too (DESIGN §3, one writer each; `fairplay.OWNED`, lint rule `owned-actuator`, hook): `timestream` (arbiter), `pop-control set max-pop` other than the R0 cap 55 (readiness), `overlay enable|disable` (arbiter), `quickfort` (runner, in-memory chunks only), `orders` and `workorder` (economy, `dfllm:` tag), `zone` (care), `burrow` (runner/siege), and disabling `timestream`, `pop-control`, `overlay` or `suspendmanager`.
