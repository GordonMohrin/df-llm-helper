# CHANGELOG dfpilot

## Projects no longer wait for months behind slot holders that build nothing; a stopped runner and terminal blocks are named (BUG-037, 2026-10-17; offline, live-untested)
- **Why (Run 11, y449):** Kilrudrabed site98, y449 spring d46, kernel 784399f, PEACE, ~39 citizens: two bedrooms, a
  stockroom, a tavern, tombs and a prio-2 trade depot stood `queued` at 0 % for months; 15 of 27 adults had no job,
  `inspect workload` said `0 unclaimed jobs`, the game session queued wood crafts as filler. The farms (`build_lost`,
  retries spent since y426) and an explore (`breach:cavern_lake` since y432) stood in the list for good.
- **Causes (from the code; bugs/BUG-037):** an open seal or plug took a pass-1 slot even when stalled and stuck
  (SEAL_STUCK only ended its pause); a dig stage never stalled while another project dug; a fault in the seal-first count
  (`focus`) left `S.active` empty, so every row read `queued` and nothing was applied; `rows()` named no slot holder,
  and nothing showed a runner whose runs had stopped; projects blocked for good kept PLAN_EXHAUSTED, the keepers,
  `runner.pending` and the depot keeper waiting. The live picture (the prio-2 depot `queued` too, no work since y446.3)
  fits a runner whose runs stopped or whose `begin_run` died before the slots; which one is not proven offline.
- **runner:**
  - A slot holder whose own progress (`R.ps`: a chunk applied, manager orders made, measured progress, a stage done;
    waiting for a slot, frozen or paused resets it) is `queue.yield_days` (7) old competes with the stalled projects for
    the slots left over. A seal or plug keeps its pass-1 slot (seal first) only until it is stuck, then it is treated
    like a stalled project (still measured; done once its pieces stand).
  - Rows: `queued behind <first slot holder> +2`, `no progress 9 d: slot yielded`, parked projects last (`parked:
    build_lost`). State `sched.q` (waiting, the holders with their days without progress), `sched.run` (no run ended
    for `run_idle_d` 3 days: the run in hand, its task, slices, age), `sched.pk`.
  - Watchdog: a task that yields `task_slices` (600) slices in a row is skipped for that run (kern.log `runner watchdog:
    task i/n (work <id>) yielded N slices in a row: skipped this run`); a fault in the seal-first/rebuild count leaves
    that run without them (kern.log `seal first/rebuild failed, this run without them: ...`, once per message).
  - Parked: a project blocked for good (`build_lost` with the retries spent, `breach:*`, `apply_fail`, `bp_missing`,
    `plug_refused`) for `queue.park_days` (30) no longer counts for the seal-first pause and state, `runner.pending`, the
    bedrooms/tombs keepers, the depot keeper and PLAN_EXHAUSTED; PROJECT_BLOCKED (A) once with `d.park` and the command
    (`... parked; cancel: dfllm cmd bp.cancel '{"proj":"<id>"}' (no undo: what it built stays)`). The kernel never
    cancels it: an undo removes built work; an explore stays in the audit box and its shaft in the shaft check.
  - `runner.queue()`: the queue in one clause for economy.
- **economy:** `inspect workload` and the idle rule's `useful backlog empty` line end with the runner's clause
  (`; runner: 6 projects queued behind 3 slot holders without progress (...)` or `; runner: no run ended for N days (at
  task i/n ...), N projects wait`), data `runner`.
- **Python:** `dfllm status`/`brief` lines `queued: 6 behind c1a148696a3d6da701 seal, depot7 depot 9 d no progress, ...`,
  `runner: no run ended for 30 d (task 2/9 work ..., 900 slices): dfllm doctor, inspect modules`, `2 parked (blocked for
  good: bp.cancel, PROJECT_BLOCKED)`; the wake line of a parked PROJECT_BLOCKED says `next: tell Gordon; once he agrees:
  dfllm cmd bp.cancel '{"proj":"<id>"}' (no undo) ...`.
- Config: `config/baseline.json` `runner.queue {yield_days: 7 (1-60), park_days: 30 (1-400)}` (`fairplay.RUNNER_LIM`,
  `python -m dfpilot.lint --config`). Contracts: §7 `runner.queue`, `runner.pending`; §9.3 `proj`, `sched.q/run/pk`; §9.8
  slots and parking; §9.17 `runner.queue`; §12 PROJECT_BLOCKED `park` (schema, contract.lua, appendix). RULES
  PROJECT_BLOCKED row in place (300 lines).
- Tests (each fails on 784399f): `tests/lua/test_runner_queue.lua` (three stuck seals held every slot, the yielding dig,
  parked projects with PLAN_EXHAUSTED and `pending`, a parked seal, the seal-first fault, the watchdog, `sched.run` of
  a paced run), `tests/lua/test_economy_jobs.lua` (the workload and idle clause), `tests/test_runner_queue.py`;
  adjusted: `test_runner.lua` (the `queued behind` text; the park announcement is not one of BUG-022's), the seal-first
  slot test, `tests/test_seal_first.py` (the config).
- **Live check (Run 11/12):** after `git pull` and `dfhack-run dfllm reload`:
  - First the old cause, read-only: `dfllm cmd inspect '{"what":"modules"}'` (runner `disabled`, `faults`, `paced`,
    `debt`, `factor`), `dfllm doctor`, kern.log lines of module `runner` since y446 (any `error`), `runner paced` /
    `demoted` / `backed off` lines, `dfllm events --type KERN_FAULT`, the runner's last `act.quickfort` in commands.log.
  - Within a minute: `dfllm status` shows `seal open: 1 piece (c1a148696a3d6da701), others paused` (the new seal pauses
    beds/work in PEACE: expected) and `queued: N behind ...` for the tombs/depot if the slots are full. A line `runner: no
    run ended for N d (task i/n ...)` names the stuck task: note it for the repo; kern.log `runner watchdog: ...` after
    600 slices of it.
  - The depot and the tombs (never paused) get chunks within a few runs (`inspect projects` `chunk` > 0); the
    stockroom, bedrooms and tavern wait as `paused: seal c1a148696a3d6da701` until the door stands, or until the seal is
    stuck after 3 days without a built piece (SEAL_STUCK); then they run. Nothing moving within a day: the old cause
    holds; send the read-only data above.
  - Within a game day: PROJECT_BLOCKED `parked` once each for c1a145d32caa7c6f06 (farms) and y432s1b0 (explore), with
    the bp.cancel command; ask the player, then cancel them without undo; a PLAN_EXHAUSTED may follow (year review).
  - `dfllm cmd inspect '{"what":"workload"}'` ends with `; runner: ...` while projects wait.

## A hospital outside Kern+/Tiefe+ is a readiness blocker; in a fight the patients outside the alert burrow are reported (BUG-036; 2026-10-17; offline, live-untested)
- **Why (Run 11 siege 9, y445):** 10 citizens lost, all in the BREACH; two cave dragons struck down 8, 7 of them
  patients in hospital beds (2 bled out at 115,77,144 and 124,91,144); the wounded soldiers (16 -> 6) lay there and were
  never moved into Tiefe+. A lying patient cannot walk to the refuge; only a rescue or hauling moves him, and the kernel
  never moves units (fair play). `bugs/BUG-036-patients-killed-in-hospital-during-breach.md`.
- **water:** hospital zones with tiles outside Kern+ and the refuge (<= 100 tiles a zone, evenly sampled): state
  `water.hosp_out`, `water.hospital_out()` (zones with their centre), the log line `hospital ok (1 of 2 zones outside
  Kern+/Tiefe+)`. In SIEGE/BREACH, once per fight: PATIENTS_OUT (B) `BREACH: 7 of 7 patients lie outside the alert burrow
  Tiefe+ (...): they cannot walk there, only a rescue moves them; the hospital lies outside Kern+/Tiefe+: move it into
  Tiefe+ next to accepted water` (Kern+/Tiefe+ while the alert is silent).
- **readiness:** R0 blocker `hospital_out` while `water.hosp_out` > 0 (no water state: none); SIEGE_UNREADY `hout`
  `the hospital lies outside Kern+/Tiefe+ (1 of 2 zones; zone 34 at 115,77,144): its patients cannot walk to the refuge;
  move it into Tiefe+ next to accepted water`.
- **Python:** wake `next: the hospital lies outside the core: plan it inside Tiefe+ next to accepted water (bp sites
  hospital; a cistern there first), then remove the old zones`; `status`/`brief` UNREADY `next:`; `plan check` warns
  while the kernel counts zones outside (a new hospital: its site must lie inside Tiefe+/Kern+). Both rules hold: inside
  (BUG-036) AND next to accepted water (BUG-034, still a refusal).
- Contracts: state `water.hosp_out`, event PATIENTS_OUT (B, water), SIEGE_UNREADY `hout`, §7 `water.hospital_out`
  (schema, contract.lua, appendix); RULES §8 R0 list in place (300 lines), DESIGN §5.4, DOCTRINE plan B.
- Tests: `tests/lua/test_water.lua`, `tests/lua/test_readiness.lua`, `tests/test_hospital_water.py`,
  `tests/test_cli_status.py`, `tests/test_cli_wake.py`; each fails on cea6072.
- **Live check (Run 12):** kern.log `water: ... hospital ok|dry (N of M zones outside Kern+/Tiefe+)` names a hospital
  outside; `dfllm status` in PEACE: `SIEGE UNREADY (R0): ...hospital_out...` with the next step; after a hospital inside
  Tiefe+ next to accepted water (and the old zones removed by hand or plan), the blocker goes at water's next run. At the
  next SIEGE/BREACH with patients: `dfllm events --type PATIENTS_OUT` once, with the units; send them and their positions
  a few hundred ticks later (does DF rescue a patient during a civ alert at all?).

## The recall follows the citizens it called and says why one does not come; a door on his only way in opens again; who cannot come holds no door (BUG-035; 2026-10-17; offline, live-untested)
- **Why (Run 11 siege 9, y445: invasion 13, 2 cave dragons, 2 goblins, a snatcher, then an ambush; pop 49 -> 39):**
  ARRIVAL said `recall: 5 outside Kern+`, then `recall: 9 of 5 still outside after 1246 t` (the count grew past its
  start); in the ambush `2 of 2 citizens still outside Kern+` after 2,407 and 4,807 ticks, never `done`, with the alert on
  Tiefe+ and the doors `8 waiting for 1 citizen outside`. The two (28346, 28350) were the same in both lockdowns: idle,
  unhurt, on the citizens' only walk group. `bugs/BUG-035-recall-count-grows-and-two-never-come.md`.
- **Causes (from the code):** the recall compared the live census total with its start count (reflex.lua:853); the
  census counts "on no Kern+ or Tiefe+ tile" (sense.lua:131), so lever pullers walking to their rooms, a PullLever job in
  Hebel+ and the walk down to Tiefe+ after the switch all raised it; the texts said Kern+ whatever the burrow; a door was
  forbidden although a recalled citizen's only way in crossed it (`seal.door_outside` counts the doorway, open sky of its
  walk group and the opening's porch, a walk that stops at every door and after 200 tiles; seal's entrance doors include
  the first door on the route to the nearest citizen, his own room's door); a citizen who cannot come (lying, caged, held
  at a lever by gate) held the doors for 2,400 ticks.
- **The recall (reflex, sense):** measured in the burrows the alert really confines to (its own, plus Kern+/Tiefe+/Innen+
  when listed; `sense.recount`, census `away`/`away_ids`/`away_to`) and by id: `left` = the called citizens still out,
  `nnew` = those out since (named once in kern.log), a switch of the alert's burrow re-targets it (kern.log `the civ alert
  moved from Kern+ to Tiefe+ ...`). Texts: `recall: 3 of 5 still outside Tiefe+ after 1246 t, +4 more out since, 2
  cannot come`. Gate's lever pullers (`gate.puller_of`) stay by their levers on purpose: never counted as still out.
- **The diagnosis (read-only, by census id):** kern.log at the start `reflex: recall: out at the alert: 28346:idle@135,77,137
  ...`; per citizen still out a key: gone, caged, chained, carried, mood, down, patient, sleep, `puller:<room>`,
  `burrow:<name>`, walk, `job:<type>`, away, idle (`/res` a resident). RECALL_PATH (600) ticks after the alert seal's path
  check (`seal.recall_path`, urgent, sliced, <= 6,000 tiles of his walk group, forbidden doors crossable at a cost) for
  one who could come: through doors this lockdown forbade only: they open again for him and wait until he is in (kern.log
  `reflex: recall: door N (x,y,z) opened again: citizen ...`), never with a hostile within 15 tiles; a door the player
  forbade or a hostile at it `locked:<id>`; `group`; `path`.
- **Doors:** a citizen who cannot come holds no door (`seal.door_outside(ids, skip)`); RECALL (B) why `stuck` once per
  lockdown names them (`recall (arrival:ambush): 2 of 2 citizens outside Tiefe+ cannot come, the doors do not wait for
  them (...)`), later ones in kern.log.
- **Water and readiness:** `water: ... refuge dry (13 wells, 0 in Tiefe+), 1 wet sources` (kpi `rwells`, `rwet`);
  `refuge_dry` says `no well in Tiefe+` or `its 2 wells are dry`.
- Contracts: RECALL `why` stuck, `reasons`, `stuck`, `pull`, `nnew`, `newu`; ARRIVAL/LOCKDOWN `rc_new`; state `alarm`
  `rn`, `rleft`, `rnew`, `rstuck`, `rto` (`dfllm status`/`brief`: `recall: 2 of 5 still outside Tiefe+ (2 cannot come:
  RECALL stuck names them), +4 more out since`); census §6.1 `away*`; §7 `sense.recount`, `seal.recall_path`,
  `seal.door_outside` skip, `gate.puller_of`, `readiness.refuge_dry` (schema, contract.lua, appendix). RULES §7 ARRIVAL in
  place (300 lines), DESIGN §4.
- Tests: `tests/lua/test_recall.lua` (10: the corridor `+4 more out since` where the old code says `recall: 7 of 3 still
  outside`, the switch to Tiefe+, an alert on Tiefe+ from the start, a room off the porch behind its own door (the
  entrance door opens again and closes once he is in), a hostile at a reopened door, a citizen lying on the field, a
  lever puller, another walk group, a reload), `tests/lua/test_water.lua`, `tests/lua/test_readiness.lua`,
  `tests/test_cli_status.py`; each fails on 784399f.
- Found, not fixed: soldiers are never waited for (census and `door_outside` leave them out, the civ alert does not call
  them): a squad outside the doors when they are forbidden is locked out (siege 9: soldiers 16 -> 6).
- **Live check (Run 12):** after `git pull` and `dfhack-run dfllm reload`:
  - At each lockdown alert: kern.log `reflex: recall: N citizens outside <burrow> at the alert (...)` and the line after
    it `reflex: recall: out at the alert: id:key@x,y,z ...`: send both for the next arrival.
  - kern.log `reflex: recall: N more citizens out of <burrow> since the alert ...` (who walks out after the alert and
    why: `puller:...`, `job:PullLever`, `walk`, `idle`), `the civ alert moved from Kern+ to Tiefe+`, `door N (x,y,z)
    opened again: citizen ...`, `N more citizens outside <burrow> cannot come`.
  - `dfllm events --type RECALL`: `stuck` once with `d.reasons`, then `done` (`d.nnew`, `d.pull`) or `late`/`end` with
    `d.reasons`; a citizen idle with a way in (`idle`, no `door`/`locked`) after RECALL_MAX is news: send his token, the
    lockdown's door lines and his position.
  - `dfllm status` while it runs: `recall: L of N still outside <burrow> ...`.
  - kern.log `water: ... refuge dry (W wells, R in Tiefe+[, K of them wet])`; SIEGE_UNREADY `refuge_dry` with `no well in
    Tiefe+` or `its N wells are dry`.
  - A door opened again with an enemy near, or a RECALL `stuck` for a citizen who walks in shortly after: note it.

## A refuge without drink is reported before a siege: readiness R0 `refuge_dry` (2026-10-17; offline, live-untested)
- **Why (Run 11 siege 8, y441):** Tiefe+ had no drink; nothing said so before the siege (seal's REFUGE_FAIL comes only
  when the alert is wanted, the refuge gate of `plan check` looks at separation and beds).
- **readiness:** a new R0 blocker `refuge_dry`: the refuge burrow exists and seal's last audit finds drink < citizens
  and no well, or its wells are dry (state `water.refuge_ok` 0: no wet well on a Tiefe+ tile). SIEGE_UNREADY (A, the
  FR-65 cadence: at once 2 days after a load, then monthly and 30 real minutes, 10 with news) names it after the
  blockers: `siege unready (R0: refuge_dry); Tiefe+ has no drink (drink 0<52, no well): build a well/cistern or stock
  drink there; ...` (`d.rdry`). No seal answer (missing, no audit yet) is no blocker (fail-open).
- **seal:** public `seal.refuge_drink()` (`{name, exists, drink, need, wells, wet}` from the last audit).
- **Python:** the wake line of such a SIEGE_UNREADY says `next: the refuge has no drink: next plan a well/cistern there
  (bp sites cistern) or a drink stockpile`; `dfllm status`/`brief` add the same to the UNREADY line's `next:`.
- Contracts: §7 `seal.refuge_drink`, §12 SIEGE_UNREADY `rdry` (schema, appendix); RULES §8 (R1 needs Tiefe+ with drink;
  the blocker; in place, 300 lines), DESIGN §4/§5.4, DOCTRINE plan B.
- Tests: `tests/lua/test_readiness.lua` (R0 `refuge_dry` with the text; a well counts unless water says it is dry; a
  stock clears it; no seal answer: no blocker), `tests/lua/test_seal_refuge.lua` (`seal.refuge_drink` on the real
  audit), `tests/test_cli_wake.py`, `tests/test_cli_status.py`; each fails on 2f6ab27.
- **Live check (Run 12):** `dfllm status` in PEACE: `SIEGE UNREADY (R0): ...refuge_dry...` while Tiefe+ holds no drink
  (Run 11's fort: it had none); after a well over water or a drink stockpile with >= one unit per citizen in Tiefe+,
  the blocker goes once seal's audit has counted it (the item census runs weekly in PEACE, the audit every 3 days). A fort that was R1 with a dry Tiefe+ drops to R0 (max-pop
  freezes at the current population): expected; tell the player why.

## Citizens outside are called home at once; a refuge with drink first; no switch of the alert burrow during a fight without a reason (2026-10-17; offline, live-untested)
- **Why (Run 11, Kilrudrabed site98, siege 8, y441 spring d23: 2 cave dragons, 4 goblins, a jabberer, a snatcher, an
  ambush; pop 52 -> 3 in ~3 days; docs/v2/POSTMORTEM-run11-siege8-y441.md cause 3):** 16 citizens were outside Kern+
  when the arrival came, 7 still outside at the breach; Tiefe+ had no drink; the alert burrow switched between Tiefe+
  and Kern+ during the fight.
- **Causes (from the code):**
  - BUG-013's order: the lockdown's civ alert waited for the lever pulls (up to 2x the lever latency, 450-1500 ticks)
    unless a hostile was within 30 tiles of a citizen outside; an ambush or snatcher arrival with hidden enemies gave
    the citizens outside no call for up to 1,500 ticks. The doors then waited only 450 ticks after the alert for those
    still outside.
  - The refuge choice took a refuge without drink before a burrow with drink: in BREACH and in the deep defense (siege
    asks seal at the BREACH level; Run 11's squads were `weak`, worn 58 %, so every siege was a deep defense) the dry
    Tiefe+ came first, for 7 days.
  - Nothing held the alert burrow during a fight. Every siege step asked seal afresh, so the burrow followed each
    change of the free pick: Kern+ separated again by a finished seal piece or a lever pull, the deep defense ending
    (army/weak gone for 2,400 ticks), the BREACH window spent, or BUG-031's relax (seal.dry at thirst 30,000) moved the
    citizens from Tiefe+ up to Kern+ (or turned the alert off) in the middle of the fight.
- **1. The recall (reflex):**
  - `alert_due`: while a fresh census counts citizens (soldiers excluded) outside Kern+ and the refuge, the lockdown's
    alert sounds at once ('N citizens outside Kern+'); the lever pulls go on under it, gate lists the lever burrow
    `Hebel+` while a pull is pending (BUG-013's live-confirmed path). Units on a bridge footprint still come first
    (BUG-027), nobody outside keeps the old wait for the pulls.
  - The doors wait for citizens outside up to `reflex.RECALL_MAX` (2,400) ticks after the alert (450 when it did not
    really sound: no burrow, they are not called), never with a visible hostile within 15 tiles of the door (unchanged).
  - The recall (`m.reflex.hold.rc`, persisted): kern.log at its start (`reflex: recall: 16 citizens outside Kern+ at the
    alert (arrival:siege), the nearest invader ~600 ticks from an entrance; called into Kern+, the doors wait for them
    up to 2400 ticks`) and at SIEGE/BREACH while some are out (`... 7 of 16 citizens still outside Kern+ at the
    BREACH, 900 ticks after the alert (ids)`); RECALL (B) `done` (all in, with the ticks), `late` (RECALL_MAX passed,
    the ids still out) and `end` (the lockdown ended first). ARRIVAL/LOCKDOWN carry `recall`/`rc_left` and name it
    right after the alert (`alert: Kern+, recall: 16 outside Kern+, doors ...`; later `recall: 7 of 16 still outside
    after 600 t`, `recall: 16 in within 640 t`). The first sighting's ARRIVAL now carries the ETA (computed before it).
- **2. The refuge (seal, siege):**
  - New level WET: separated, reachable, `breach_tiles`, and the SIEGE level's drink rule (drink >= citizens or a
    well); no food, bed or size counts, no window. Order: a BREACH ask (BREACH, the deep defense, a refuge held after a
    BREACH) takes the refuge at WET first; then want -> Kern+ -> Innen+ -> refuge at SIEGE/SOFT, HOLD, the same chain
    at WET; a refuge without drink (BREACH, then DEAD) only when the fort is breached or open (a BREACH ask or an
    entrance reaching the candidates), for `breach_days`. So the deep defense keeps the citizens in a separated Kern+
    with drink when Tiefe+ is dry (REFUGE_FAIL `Tiefe+: no drink (drink 0<52, no well)`), and a gate-fail BREACH keeps
    them there until a hostile is inside Kern+.
  - The switch rule (`seal.alert_burrow(mode, default, hold, cur)`, siege passes the burrow the sounding alert holds;
    after a reload it reads it back from the civ alert's list):
    in SIEGE and BREACH that burrow is kept unless it is gone, marked dry, unseparated (an entrance reaches it; the
    refuge keeps the dead-end tolerance), breached (a visible hostile in it), unreachable, a refuge without drink past
    its window, or the new pick is the refuge (deeper, away from the entrances). A switch is REFUGE_SWITCH (B, once per
    switch: `alert burrow Kern+ -> Tiefe+ during the BREACH: Kern+ breached (a hostile inside)`) and a kern.log warn; a
    kept burrow a kern.log line (`seal: the civ alert stays on Tiefe+ during the SIEGE: a switch to Kern+ would walk
    the citizens through the danger, and Tiefe+ is neither breached nor open`), `short` `Tiefe+ kept (SIEGE)`, the
    state shows it. PEACE/ALERT lockdowns choose freely as before.
  - BUG-031's relax in SIEGE/BREACH marks a burrow dry only over thirst 50,000 / hunger 75,000 (`siege.FIGHT_THIRST/
    HUNGER`, DF's dehydrated/starving lines, ~25,000 ticks before death); below them kern.log names who waits (once
    per set) and the alert stays. The 30,000 mark holds outside a fight.
- Contracts: events RECALL (B, reflex), REFUGE_SWITCH (B, seal); ARRIVAL/LOCKDOWN `recall`, `rc_left` (LOCKDOWN also
  `out`); REFUGE_FAIL level WET; `seal.alert_burrow` `cur`; §9.18 doors/alert; STRANDED relax; §14 deep defense (schema,
  contract.lua, CONTRACTS rows and appendix). RULES §7 (ARRIVAL, BREACH, STRANDED, REFUGE_FAIL) and §10 in place (300
  lines), DESIGN §4, DOCTRINE plan B.
- Tests (k_mock; each fails on 2f6ab27):
  - `tests/lua/test_lockdown_gates.lua`: one citizen outside: the alert at once with 4 pulls pending (old: after the
    pulls), every pull done under it with `Hebel+`, the door open at T+900 (old: alert + 450), forbidden at alert +
    2,400, RECALL late then done; 16 citizens outside: `recall: 16 outside Kern+`, the door waits while 9 and then 7
    come home, kern.log `7 of 16 ... at the SIEGE`, RECALL done, the door forbidden then; nobody outside: the old wait.
  - `tests/lua/test_seal_refuge.lua`: the deep defense with a dry dead end keeps Kern+ (REFUGE_FAIL no drink), a
    stocked dead end is taken without a window; in SIEGE the dead end is kept when a door separates Kern+ again (old:
    back to Kern+), left for Kern+ once a hostile stands in it (REFUGE_SWITCH breached), PEACE picks freely.
  - `tests/lua/test_seal.lua`: BREACH keeps a supplied Kern+ against a dry Tiefe+, a goblin in Kern+ switches (breached),
    the dry refuge is kept after the goblin left and left after `breach_days` (REFUGE_SWITCH window).
  - `tests/lua/test_stranded.lua`: the BUG-031 relax in a BREACH: thirst 41,000 keeps the alert (log), 51,000 relaxes
    (STRANDED, REFUGE_SWITCH dry to Kern+).
  - `tests/lua/test_reflex.lua`: the deferred-alert test with a citizen outside sounds at once.
- **Live check (Run 12):** after `git pull` and `dfhack-run dfllm reload`:
  - The next arrival with citizens on the surface: ARRIVAL `alert: Kern+, recall: N outside Kern+, doors ...`, kern.log
    `reflex: civ alert: Kern+ (N citizens outside Kern+)` and `reflex: recall: N citizens outside Kern+ at the alert`;
    the lever pulls still go up (`gates: ... (levers in Hebel+)`; GATE_FAIL `outside_alert` would mean the lever burrow
    failed: note it). `dfllm events --type RECALL` after a few minutes: `done` with the ticks, or `late` with the ids.
  - Doors: forbidden once the citizens are in, at alert + 2,400 at the latest, at once with a hostile within 15 tiles.
  - A siege with a dry Tiefe+ and the deep defense: REFUGE_FAIL `Tiefe+: no drink`, the alert stays on Kern+; any
    switch during SIEGE/BREACH is a REFUGE_SWITCH (B) in the brief with its reason; `seal: the civ alert stays on ...`
    lines in kern.log otherwise. A REFUGE_SWITCH without a breach, an open entrance or thirst is a bug: note it.
  - Tiefe+ still needs drink: a well, a cistern or a drink stockpile there (plan).

## Seal first: an open seal or plug runs before everything and pauses the housing/work projects; a stuck seal says so (SEAL_STUCK); the rebuild policy below 10 citizens; plan check/propose follow both (2026-10-17; offline, live-untested)
- **Why (Run 11, Kilrudrabed site98, y441 spring d23, siege 8: 2 cave dragons, 4 goblins, a jabberer, a snatcher, an
  ambush; pop 52 -> 3 in about three days; post-mortem `docs/v2/POSTMORTEM-run11-siege8-y441.md`):** root cause 1 was
  the way in 114,73,143 without a door. Its seal (c1a147c261) was placed two days before the attack and was not
  finished: the runner works three projects at once, sorted by prio and age, so a seal placed at prio 4 waited behind a
  prio-1 stone dig and the older projects; its door order queued behind the other rock orders. Afterwards the fort had
  2 citizens (food 845 d, drink 1210 d, 22 coffins, 59 unburied dead, migrants still coming).
- **Seal first (runner):**
  - `seal` and `plug` projects sort before every other project and take a pass-1 slot even when stalled.
  - Their dig designations use priority 1, whatever the project's prio.
  - The manager orders their quickfort `orders` call made move to the top of the work orders. This is the new act
    `order_top(ids)`, the work orders screen's up arrow. kern.log: `<id> seal.build: 1 manager orders moved to the top
    of the work orders (seal first)`.
  - While one is open and not stuck, in PEACE the housing/work projects pause: no orders and no new chunk. That is
    `work` (rooms, workshops, furnaces, explore, fortcore stage 1, beauty), `beds` (bedrooms, refuge_beds) and
    `supply` (farms, cistern, stockroom, a workshops project of only Still/Kitchen/Butchers/Fishery).
  - What a paused project already designated is dug on by the miners. So a paused dig stage with applied chunks is
    still measured (at most `hold_n` 3 a run): a breach stops it, and a finished dig stage completes.
  - **Never paused:**
    - defense projects (fortcore stages 2-4, barracks, captives, gallery_o1, a peace-only bridge repair): they
      close or guard the fort too;
    - `tombs` and care's coffins (GHOSTS: the dead must be buried);
    - the `depot` (a caravan leaves without one);
    - `repair` (lost walls and doors).
  - **Exceptions while paused:**
    - `supply` goes on in a food, water or drink emergency: food or drink days below `seal_first.food_d` /
      `drink_d` (30), or a patient without accepted water (state water);
    - a paused dig stage digs on while the free stone is below what the rock orders and walls want (`stock.rock` <
      `rock_need`): its boulders become the seal's walls.
  - kern.log names each change of the paused set: `seal first: c1a147c261 with 1 piece open (door 114,73,143) runs
    first; paused: bd1 bedrooms, ws1 workshops`, and `paused projects run again (no seal open, no rebuild)`.
  - `dfllm status` rows show `paused: seal <id>`.
- **A stuck seal (SEAL_STUCK, A, new):** a seal or plug whose progress (stage, chunk, pieces not built, measured
  progress) did not move for `seal_first.stuck_days` (3) game days stops pausing the others.
  - The clock waits while the mode freezes the seal (a siege) or seal first is off. m.runner `sf[<proj>]`.
  - The event names the open pieces, economy's material reason and the block: `c1a147c261 (seal) built nothing for 3
    days at seal.build: 1 piece open (door 114,73,143)[; build_lost][; no material for door: no rock, no logs]; the
    other projects run again`. d: proj, tpl, stage, days, n, pieces, mat, blocked.
  - Once per stuck episode; util/cadence per project: an episode within 7 days of the last announcement (after the
    seal moved in between) is only logged.
  - A piece that moves again pauses the others again (kern.log `seal first: <id> moves again`).
- **Rebuild policy (runner, a PEACE/RECOVERY policy, not a mode):**
  - Below `rebuild.pop` (10) citizens in a fallen fort, only seal, plug, tombs/coffins, supply (food/drink), beds,
    wall repairs and the depot run. The mode's class gating still holds (RECOVERY: no living projects).
  - A fallen fort had `rebuild.off` citizens before (m.runner `pk`, this kernel's record) or is past P1. A fresh embark
    of 7 is not rebuilding.
  - It ends at `rebuild.off` (12): hysteresis; m.runner `rb` keeps it across reloads.
  - kern.log `rebuild: pop 2 < 10 (peak 2, phase P4): only seal, plug, tombs, food/drink, beds, wall repairs and the
    depot run until pop >= 12` (the peak is what this kernel saw), the paused set as above, and `rebuild over: pop 12 >= 12: every project runs again`.
- **Status (state `sched`, new):** `seal open: 3 pieces (c1a147c261), others paused` (`runs first` when it pauses
  none now), `seal stuck 3 d: 1 piece (c1a147c261), others run (SEAL_STUCK)`, `rebuild: pop 2 < 10, only
  seal/tombs/food/beds (4 paused, ends at 12)`. The line comes before `proj` in status and brief.
- **Plan (`dfllm plan check` / `propose`):**
  - `check` warns when a new seal build comes after another new build: in an earlier season (`move it to the front of
    seasons[N]`), or before it in its season (`put it first in seasons[N]`).
  - `check` warns when a seal project is open (state `sched.seal`, else a seal bp file without PROJECT_DONE that the
    state's running projects list) and new
    housing/work builds are due now: `seal c1a147c261 (3 pieces open) is open: the runner pauses temple in PEACE
    until it is done (seal first)`. A stuck one: `... is stuck for 4 d (SEAL_STUCK): fix it first`.
  - Under the rebuild policy (state `sched.rb`; a kernel without it: `pop.cit` < `rebuild.pop` in a fort past P1),
    `check` warns on every new build the runner pauses and on a phase raise. The metal route's errors and `add
    explore` warnings (metal_gate, ore goal) give way to one warning then: `metal: waits for the rebuild (pop 2 < 10):
    the runner pauses an explore until pop >= 12; trade.want only meanwhile` (`rebuild_metal`).
  - `propose` puts seal builds first. Under the rebuild it drafts only seal, tombs, food/drink and beds (no explore),
    keeps phase_target and notes `rebuild (pop 2 < 10, until 12): only seal/tombs/food/beds drafted (left out: tavern,
    temple); phase_target stays P4`. With an open seal it notes `seal <id> open: housing/work builds wait for it`.
- **Config (config/baseline.json `runner`, new):** `seal_first: {on: true, stuck_days: 3, food_d: 30, drink_d: 30}`,
  `rebuild: {pop: 10, off: 12}`. `pop` 0 switches the rebuild policy off. `on` false means no pause and no
  SEAL_STUCK (the order and the dig priority stay). `python -m dfpilot.lint --config` checks keys, ranges and off >=
  pop (`fairplay.runner_errors`).
- Contracts: act `order_top` (§5; schema/contract.lua ACT, owner runner), event SEAL_STUCK (§12), state `sched` (§9.3),
  §9.8 seal first and rebuild, §9.17 `runner`, §19 row SF, appendix regenerated; RULES §7 SEAL_STUCK (seal first in
  its row) and §10 Rebuild (300 lines: two wrapped lines joined); DESIGN §4; follow's wake hint and PRIO.
- Tests (each fails on 2f6ab27):
  - `tests/lua/test_runner_seal_first.lua` (new, 8): the siege 8 replay (the seal 4th in the old order runs first,
    its order on top, bd1/ws1 paused with the log line and `sched`, the paused dig measured, no orders or chunks
    for the workshops until the door stands, then they run); dig priority 1 and a stalled seal's slot; the
    exceptions (defense, tombs, depot; farms and the fishery in a food emergency; paused digs while stone is
    short); the plug pauses too, `on` false; SEAL_STUCK after 3 days, once, the others run, done after the build;
    the clock waits through a siege, `mat` and `blocked`; rebuild in PEACE and RECOVERY with the hysteresis; a
    new fort of 7, a fort that had 15, `pop` 0, a reload.
  - `tests/lua/test_act_supply.lua` (order_top: order, owner, refusals).
  - `tests/test_seal_first.py` (new): the event, the state, the status lines, the config, RULES; plan check (a seal
    after other builds, an open or stuck seal, the rebuild warnings), `open_seals`, propose under the rebuild (only
    bedrooms and tombs of P4, target kept, the note, no metal error; a fort of 52 drafts all), the open-seal note,
    `rebuild_state` without the kernel's record and with `rebuild.pop` 0, `build_kind`.
  - `tests/lua/test_runner_cavern.lua` passes unchanged: a paused room dig still finds the cavern lake it dug into.
- **How to use:** nothing to send.
  - `dfllm status`: `seal open: ...` means the seal goes first and housing waits.
  - SEAL_STUCK: tell the player the open way in. No material: logs, a stone dig (follow places it). A refused tile:
    `bp.cancel`, then `bp.place tpl=seal at=last` again, or a wall by hand.
  - Rebuild: the status line says what runs; it ends at 12 citizens by itself. Year review: keep what `plan propose`
    drafts; `plan check` warnings on paused builds mean they wait.
- **Live check (Run 11 site98, 2 citizens, or Run 12):** after `git pull` and `dfhack-run dfllm reload`:
  - Within a game day kern.log shows `rebuild: pop 2 < 10 (peak 2, phase P..)` (the fort is past P1) and the paused
    set. `dfllm status` shows `rebuild: pop 2 < 10, only seal/tombs/food/beds (...)`; tombs/coffin projects keep
    running.
  - The next seal (`bp.place tpl=seal at=last`, or follow's `at=audit`): kern.log `seal first: <id> with N pieces open
    ... runs first; paused: ...`. In DF the seal's door/wall order stands first in the work orders screen and its
    construction gets built before the paused rooms. `dfllm status` `seal open: N pieces (<id>), others paused`;
    after it: `paused projects run again`.
  - If the work orders screen does not show the seal's order on top, `order_top` failed: note the kern.log line and
    DFHack's error in BUG notes. If DF does not take orders in list order, the move changes nothing: note that too.
  - A seal that cannot be built: SEAL_STUCK after 3 days names the piece; the paused projects run again.
  - `dfllm plan propose` on the 2-citizen fort: only seal/tombs/food/beds builds and the `rebuild (...)` note; `dfllm
    plan check` of a plan with a workshop: `rebuild: pop 2 < 10: the runner pauses workshops ...`.
## Metal without an ore find: every caravan is asked for metal, the melt pile gets its fuel, the melee squads follow the gear, plan check wants a metal route (2026-10-17; offline, live-untested)
- **Why (Run 11, Kilrudrabed site98, siege 8 y441, pop 52 -> 10; post-mortem `docs/v2/POSTMORTEM-run11-siege8-y441.md`
  cause 4):** 10 soldiers, worn 58 %, bars 0 for ten game years. No metal ore on the site, the explore never found any,
  the caravans were never asked for iron (trade.want held `bar:iron` among the plan's wants, nothing raised it), and
  the invaders' gear of eight sieges was never melted: with no ore and no bar, economy ordered no charcoal, so the
  smelter's melt jobs had no fuel. Melee recruits without armor or a weapon died first.
- **1. Metal short -> every caravan is asked for metal (economy `M.metal_plan`, config `economy.metal_short`):**
  - Metal is short for the soldiers while soldiers are wanted (military.targets), they wear < `worn` (80) %, no ore
    boulder of a gear metal lies in the fort (steel, iron, bronze, bismuth bronze, copper) and the gear-metal bars are
    below what the metal slots want (`gear.bars_short`). Public `economy.metal()` = `{short, worn, bars, ore, need,
    melt}`; state `stock.mshort` (0/1).
  - Then `economy.trade_wants` (trade puts it after the moods' tokens, before plan.trade.want) holds, marked
    `metal = 1`: `pick` and `axe` up to `tools` (3 each: military's tools-first minimum), then `metal_short.wants`
    in order: `bar:iron`, `bar:steel`, `armor:metal`, `weapon:metal`, `helm:metal`, `shield`, `pants:metal`,
    `gloves:metal`, `shoes:metal`, `bar:bronze`, `bar:bismuth_bronze`, `bar:copper` (n = the bars the metal slots
    miss, or that slot's missing pieces).
  - Pay for it: economy keeps `crafts` (40) crafts (`dfllm:trade_crafts`, MakeCrafts in free stone while the stone
    covers the rock orders, else wood above `idle.wood_min`, at most 10 an order, needs a craftsdwarf's workshop).
- **trade (`trade.lua`):** a new token sub `kind:metal` (`armor:metal`, `weapon:metal`, `bar:metal`, ...) = an item of
  a metal material (IS_METAL; never leather, wood or a training weapon). A metal want is capped at its units up to
  `METAL_CAP` (30), not the kind's default (armor 3, bars 20). While one stands, a non-empty plan sell list gets
  `crafts`, and the crafts go to the depot with the sale items, up to `BRING_METAL` (200) instead of 100. Every
  caravan, since the wants are read per visit.
- **3. Other metal sources (economy):**
  - The census counts metal weapons, armor and ammo marked for melting (`melt`, state `stock.melt`; the invaders'
    gear the `dfllm-melt` automelt pile marks). With a smelter, the charcoal sizing counts their melt jobs (one fuel
    each, up to `metal.max_jobs`), also with no ore and no bar (old: no charcoal at all then).
  - Checked, unchanged: military's loot pass (FR-46) unforbids the invaders' metal gear every 3,600 ticks in PEACE
    and quiet RECOVERY after every siege; baseline registers the melt pile once a smelter stands; melted bars are
    census bars, and the gear orders (`plan_gear`) take the first gear metal with enough bars (steel, iron, bronze,
    bismuth bronze, copper), so copper and bronze come before nothing; bronze is alloyed from tin and copper bars or
    ores while forge jobs want metal.
- **2. The melee squads follow the gear (military, `M.GEAR_FLOOR` 2):**
  - A melee set = a true body armor, a melee weapon (metal melee weapons, then the axes beyond the woodcutters' keep;
    never a pick) and a shield, free or carried by soldiers (census.i `g_body`, `g_weapon`, `w_axe`, `g_shield`).
  - `military.targets()` returns a fifth value `gear` = `{sets, melee, want, xbow, fill, parts}` when the sets do
    not fill every melee position: `per` stays the demand (economy orders the gear for it), the squads are filled to
    `fill` = max(2, sets) in plan order. A census without the gear counts: no cap.
  - Metal short: the melee positions left go to the crossbow squad (C, from P5): `xbow` more in the demand (economy
    makes crossbows, quivers and bolts for them; their armor is counted with the melee positions they stand in for),
    filled as far as the crossbows beyond C's own positions go (`g_xbow`).
  - Excess soldiers leave as before (PEACE, one per upkeep, more than 2 above the fill). kern.log `military: melee
    filled to 3 of 6: 3 gear sets (body armor 10, melee weapons 3, shields 10); metal short: 3 more crossbow
    positions`; state `mil.cap` = `{sets, melee, want, xbow}`; status/brief `melee 3/6 (gear sets 3), +3 crossbow
    (metal short)` and `METAL SHORT melt N`.
  - Decision, the siege refill (Run 11 siege 3): in SIEGE/BREACH the first melee squad is still refilled up to
    `HOLD_MIN` (5) from healthy core civilians beyond the gear: the core choke needs bodies, and a drafted civilian
    stands with the squad at the core station (the deep defense) instead of fleeing. The other melee squads stay
    capped by the gear in a siege too.
- **plan check (`plan.py` `metal_gate`, `metal_short`, `metal_facts`):** while the plan wants soldiers (phase_target
  >= P2 and a melee or crossbow squad) and the fort holds no metal for them (state `stock.ore`/`bars` 0 and
  `stock.mshort` 1; an older kernel: worn < 80 %), a plan with no metal route at all is an ERROR (`metal: no route:
  ...`; no `explore` build and none under way, nothing marked for melting, no trade depot); with only a depot it warns
  (`only the caravans`). It replaces the Run 10 "neither explore nor bar:*" error when both would fire. fort_facts
  gains `metal` = `{depot, explore}`.
- Contracts: `military.targets`, `economy.metal`, `economy.trade_wants` `metal`, state `stock.mshort/melt`, `mil.cap`,
  the `:metal` token (schema, contract.lua, CONTRACTS rows and appendix); config `economy.metal_short`
  (baseline.json = DEFAULTS); RULES §6/§10 (in place, 300 lines), DESIGN §5 (metal without an ore find), DOCTRINE
  (military).
  - `tests/lua/test_economy_chains.lua`: metal short (no ore, no bars, worn 15 %, squad A 5): the 14 wants in order
    with their units (`bar:iron` 55, `pick`/`axe` 3), `economy.metal`, stock.mshort 1, the wood crafts order; an iron
    ore boulder ends it; no soldiers wanted: nothing. Three iron armors marked for melting, no ore, no bar: census
    `melt` 3, charcoal ordered, stock.melt 3; no smelter: none.
  - `tests/lua/test_trade.lua`: the `:metal` matching; a flow with economy's metal wants: 30 iron bars (six stacks)
    and six breastplates bought (the kind caps 20 and 3), no leather armor, `crafts` added to the sell list, 200
    sale items with the crafts brought.
  - `tests/lua/test_military_refill.lua`: 3 spare axes = 3 sets: A 3, B 0, C 2 with the demand 3/3/2, state
    `mil.cap`, the kern.log line; no shield: A 2 (floor); enough gear or an older census: no cap; metal short with 4
    crossbows: 3 more crossbow positions, C filled to 4; SIEGE: A refilled to 5 beyond the gear, B not drafted.
  - `tests/test_plan_supply.py`: `metal_short`, the gate (error, depot warning, explore planned / under way, melt, P1,
    no squad, not short, older kernel), fort_facts `metal`, status/brief lines; `tests/test_wp8_files.py` state keys.
- **How to use:** nothing to send. `dfllm status` shows `METAL SHORT` while it holds; the wake/brief shows the gear
  cap. At a year review with `plan check` `metal: no route`: add `{"tpl":"explore","site":"S1"}` where the miners can
  dig (or a depot). Tell the player that the melee squads stay small until armor, weapons and shields exist, and that
  the crossbow squad takes the rest.
- **Live check (Run 12):** after `git pull` and `dfhack-run dfllm reload`:
  - Without metal ore and bars, within a game day kern.log/state: `stock.mshort` 1, `dfllm status` `METAL SHORT`;
    `dfllm cmd trade.want '{}'` lists `pick`, `axe` (while below 3), `bar:iron`, `bar:steel`, `armor:metal`, ... before
    the plan's wants. Manager orders show `dfllm:trade_crafts` (MakeCrafts) once a craftsdwarf's workshop stands.
  - At the next caravan: kern.log `trade: N sale items sent to the depot (metal short for the soldiers: crafts too)`;
    TRADE_LEDGER lists what was bought, or `bar:iron:none` (the merchants had none). Note in this entry what the
    dwarven and human caravans actually carried (`inspect what=trade` `wanted_matches`).
  - After a siege with dead invaders: `dfllm status`/state `mil.free` grows (loot unforbidden), then `stock.melt`
    (the melt pile's marks) and a `dfllm:charcoal` order while a smelter and a wood furnace stand; bars rise as the
    smelter melts. If `stock.melt` stays 0 with loot lying around, the melt pile takes nothing: note it here.
  - kern.log `military: melee filled to N of M: S gear sets (...)`; the squads A/B hold at most max(2, S); with metal
    short squad C grows by up to the free crossbows. In a SIEGE, A still refills to 5 (kern.log `SIEGE refill`).
  - `dfllm plan check` on a draft without explore while `METAL SHORT`: warning `metal: ... only the caravans`.

## A destroyed bridge is rebuilt only in quiet PEACE, and not again after two losses to building destroyers without the player (2026-10-17; offline, live-untested)
- **Why (Run 11, Kilrudrabed site98, y434-y438 winter):** cave dragons (building destroyers) destroyed the outer
  drawbridge O1 (114,79,142) in all five sieges. The perimeter keeper (seal, FR-56) re-queued it every time: its
  post-siege diff runs when the fort enters RECOVERY (and at SIEGE_END and when it is quiet), so PERIMETER_BROKEN put
  O1 and the walls into one `rp...` repair project in RECOVERY, and the runner builds such a defense project in ALERT
  and RECOVERY. Builders went out to the footprint on the attack path, the next siege broke the gate first, and nobody
  asked the player. Nothing counted the losses (`m.gate.gone` holds only the current one). Siege 5 went well otherwise
  (3 losses; the BUG-032 station fix, the refuge switch and the refill worked).
- **The policy (BUG-030 section "Rebuild policy"):**
  - Never during a fight: a lost bridge is not rebuilt in SIEGE, BREACH, ALERT, RECOVERY or a reflex lockdown. Its
    repair is queued once the fort is quiet again (PEACE, no lockdown), as its own `repair` project the runner builds
    only then. Walls, doors and the other pieces keep the RECOVERY repair.
  - The stop rule: a manifest bridge destroyed `perimeter.stop_after` times (config/reflex.json, default 2; 0 =
    always rebuilt) by building destroyers since the player's last answer is not rebuilt automatically any more.
    DECISION_NEEDED `bridge_rebuild` (A, once per loss count) gives the history and the options: rebuild anyway
    (`bridge.rebuild`), walls on its footprint with a door entrance, a second outer gate further out (plan), or leave
    it (the default). Against destroyers the gate is no barrier; the deep defense (refuge, core station) and the
    BREACH at once for a lost O1/B1 already hold.
  - The player's answer `dfllm cmd bridge.rebuild '{"bridge":"O1"}'` re-enables the rebuild; the count starts again
    from it (asked again after two more losses).
- **gate (`gate.lua`):** a loss history per manifest bridge (`m.gate.lost`, public `gate.losses`): losses `n`, those
  with building destroyers in sight `bd` (`census.h.bd` now or within 2,400 ticks before), their races, the newest six
  losses (tick, year, mode), rebuilds, the construction items of the lost bridges with their material (the building's
  item list, read once when gate first sees it complete) and the lever links queued after a loss. BRIDGE_DESTROYED
  carries `n`, `bd`, `destroyers`, `races`: `O1 destroyed: no bridge on its footprint at 114,79,142 any more (...);
  ...; lost 2x, 2 with building destroyers in sight (DRAGON)`. A moved footprint starts a new record.
- **seal (`seal.lua`):** the bridge queue (`m.seal.gq`). The post-siege diff sends a lost bridge with its build text
  there; PERIMETER_BROKEN says `...; bridge O1 after the fight (quiet PEACE)` (`d.wait`) or `... not rebuilt (building
  destroyers): DECISION_NEEDED` (`d.held`). In quiet PEACE (the episode's last diff, a daily look, the verb) it queues
  the bridge (`runner.repair` `opts.peace`) or holds it and asks. An entry stays until its bridge stands again (the
  retire passes keep its piece and build text) or 60 days after its repair; a footprint the player walled is retired.
  Public `seal.lost_gates()`, verb `bridge.rebuild`; `inspect defense` shows each bridge's `lost` record and `rebuild`
  state (`O1 destroyed/- 0lev lost 2x (2 bd) held`), `inspect perimeter` the queue (`bridges`).
- **runner (`runner.lua`, minimal):** `runner.repair(cells, why, opts)`; `opts.peace` sets `params.peace = 1`, and
  `allowed` freezes such a project outside PEACE and during a lockdown.
- **readiness:** a held bridge is the R0 blocker `lost:<B>` in place of `bridge:<B>` and `levers:<B>`; the brief's
  `next:` names the answer instead of "build the missing fortcore pieces". The wake line of DECISION_NEEDED
  `bridge_rebuild` names the verb; BRIDGE_DESTROYED's hint says the kernel rebuilds in quiet PEACE or asks.
- Contracts: `gate.losses`, `seal.lost_gates`, `runner.repair` `opts`, §9.8 `params.peace`, §9.18 `perimeter`, §12
  BRIDGE_DESTROYED/PERIMETER_BROKEN/DECISION_NEEDED fields, §13 `bridge.rebuild` (schema, contract.lua, CONTRACTS rows
  and appendix); `python -m dfpilot.lint --config` checks `perimeter.stop_after` (0-20). RULES §6/§7/§8/§10, DESIGN
  §4/§5.4, DOCTRINE (plan B).
- Tests:
  - `tests/lua/test_bridge_rebuild.lua` (new, all 4 fail on fcada16): gate's loss history (counts, races, year,
    rebuild, items, lever link, a loss without destroyers in sight, a reload); the Run 11 replay with the real gate and
    seal (siege 1: the wall in RECOVERY, O1 only in PEACE as a peace-only repair; siege 2: held, DECISION_NEEDED once,
    `inspect defense` held; `bridge.rebuild`; the third loss rebuilt, the fourth asked again); ALERT and a PEACE
    lockdown hold it back; a walled footprint, `stop_after` 0, a refused verb, the queue and answer across reloads.
  - `tests/lua/test_runner.lua` (a peace-only repair frozen in ALERT, RECOVERY, SIEGE and a lockdown; a plain repair
    still runs in ALERT), `tests/lua/test_readiness.lua` (`lost:O1`), `tests/test_bridge_rebuild.py` (verb, event
    fields, config, wake line, brief); each fails on fcada16.
- **How to use:** DECISION_NEEDED `bridge_rebuild`: ask the player once. Rebuild: `dfllm cmd bridge.rebuild
  '{"bridge":"O1"}'`. Wall or a second outer gate: a plan build (`bp.place tpl=seal at="x,y,z floor wall"` per footprint
  tile and a door entrance elsewhere). Leave it: nothing to send (readiness stays R0 `lost:O1`).
- **Live check (Run 11 site98):** after `git pull` and `dfhack-run dfllm reload`:
  - The kernel has no history for the five old losses; gate counts from the first loss it sees. The next siege that
    breaks O1: BRIDGE_DESTROYED `lost 1x, 1 with building destroyers in sight (...)` (if it says 0 with the dragons in
    sight, `census.h.bd` does not read the raws: note it in BUG-030).
  - After it: PERIMETER_BROKEN `...; bridge O1 after the fight (quiet PEACE)`, no `rp` project for O1 during RECOVERY;
    in PEACE kern.log `seal: lost bridge O1 at 114,79,142 queued again as rp... (quiet PEACE)`; `dfllm status` shows that
    project `frozen` in any ALERT or lockdown until it is built.
  - The second such loss: no rebuild, DECISION_NEEDED `bridge_rebuild` in PEACE, readiness `lost:O1`, `dfllm cmd inspect
    '{"what":"defense"}'` `O1 destroyed/- 0lev lost 2x (2 bd) held`.
  - To stop rebuilding O1 at once: `"perimeter": {"stop_after": 1}` in config/reflex.json (Gordon's call), then
    `dfhack-run dfllm reload`. An `rp` project an older kernel queued keeps the old gating.
## A lockdown expires when no invader comes near; an invader's animal is a wild danger; no ack default for a far unit (2026-10-17; offline, live-untested)
- **Why (Run 11, Kilrudrabed site98, y439 spring d1):** the kernel stood in ALERT with an `arrival:ambush` lockdown for
  45 days (clock 30 t/s, 6 doors forbidden, idle 68 %, 9 t/s instead of 400). The only threat: ONE invader, ELK_BIRD
  28188 at 184,1,144 (the map edge, walk group 29 = the citizens', 100+ tiles from everybody, status `threat 1 vis`).
- **Causes (from the code):**
  - sense counted the mount the invaders left behind as an invader (`isInvader`), so `census.h.inv` was 1 for good;
  - reflex's quiet clock needed `inv == 0` for `hold_quiet_days` (LOCKDOWN_END), which never came;
  - threat counts invaders map-wide, so siege's ALERT exit (`calm`) never came either (runner builds only
    defense/infra in ALERT, FPS cap 100);
  - the unacked path: every INTRUDER for such a unit (again after a reload or after it was out of sight for 1,200
    ticks) applied its lockdown default after 60 s and restarted the quiet clock.
- **1. The lockdown expires far (reflex, `config/reflex.json` `lockdown_near`, int 0-400, default 40; 0 = off):**
  - An approach = a visible invader within `lockdown_near` tiles (Chebyshev) of a citizen outside Kern+ (sense `dc`)
    or of an entrance (gate.points, the lockdown's doors or the open-sky door scan, seal.entrances; the last known set).
  - In PEACE/ALERT the quiet clock runs on with invaders in sight while every one is listed and beyond it. One closer,
    inside Kern+, of unknown distance or beyond the 40 listed restarts it. Never in SIEGE/BREACH/RECOVERY: a siege
    keeps its own rules.
  - After `hold_quiet_days` (2) the lockdown ends: doors open, clock and alert follow the mode, the gates as before.
    LOCKDOWN_END (B) gets `cause` (`far` | `quiet`), `far` (<= 3 names) and `nfar`:
    `lockdown over (arrival:invader): no invader within 40 tiles of a citizen or an entrance for 2 days, 1 far: inv 300
    GOBLIN at 150,30,10 (98 tiles), 1 doors opened`.
  - The invaders it named become expired far (persisted `m.reflex.far`, <= 40, `reflex.far_ids()`):
    - threat.assess counts them for nothing (`inv`, reach, calm, quiet; `a.far`), so ALERT ends 1,200 ticks later;
    - the sighting skips them (no new ARRIVAL), INTRUDER skips them, the ETA leaves them out;
    - state `alarm.far` counts them; status/brief: `N invaders far (lockdown expired; re-arm within lockdown_near)`.
  - Re-arm: one that comes within `lockdown_near` (or inside) leaves the list at once and counts again. kern.log
    `reflex: inv 300 at 70,20,10 came within 18 tiles of an entrance after its lockdown ended far: it counts again`;
    the sighting raises the lockdown again with ARRIVAL (A) `invader` (text `inv 300 came within 18 tiles of an
    entrance after its lockdown ended far`); threat counts it, so the mode goes ALERT. Dead or gone units leave the
    list daily.
- **2. An invader's animal is a wild danger (sense, threat):**
  - sense reads the caste raws (cached per race/caste with LARGE_PREDATOR): CAN_LEARN and CAN_SPEAK both false (not
    intelligent), or, when those do not read false, MOUNT/MOUNT_EXOTIC without CAN_LEARN/CAN_SPEAK true. A missing
    flag is no evidence: the unit stays an invader. Great dangers and undead are never reclassified.
  - Such an invader is not in `census.h.inv` (counted in `census.h.an`), is listed as k `danger` with `an = 1`, and
    takes the non-invader walk-group rule. It never starts an arrival lockdown by itself.
  - reflex applies the PREDATOR rules to it (roofed tile; inside Kern+ or within `predator_near`, else PREDATOR_FAR).
  - threat counts it only inside Kern+ / past B1 or within `predator_near` (40) of a citizen outside Kern+, never by
    the 100-tile bridge reach, so it keeps no ALERT. `vis` still counts it (it is a visible hostile).
- **3. No ack-timeout default for a far unit (reflex `ack_step`):**
  - An interrupt record keeps its unit (`u`). An INTRUDER/PREDATOR still unacked after `ack_timeout_s` gets no
    default while that unit is expired far or listed beyond `lockdown_near`. kern.log: `reflex: interrupt #N INTRUDER
    unacked for 63 s; its unit 300 is far (98 tiles from the citizens and entrances, lockdown_near 40): no default`.
  - alarm.txt shows `far` in the status column. Such an unacked INTRUDER is no DEFCON 1.
  - INTRUDER names a near unit first, carries `dist` and `far`; for a far one the msg ends `; far: N tiles from the
    citizens and entrances`. It comes again at once when one comes near after an INTRUDER for far ones only; that
    one's default applies as before.
- Contracts: config `lockdown_near` (schema/fairplay `reflex_errors`, config/reflex.json); LOCKDOWN_END `cause far
  nfar`, INTRUDER `dist far` (schema, contract.lua comment); state `alarm.far` (schema, contract.lua); census.h `an`
  and list `an` (§6.2); `reflex.far_ids()` (§7); §9.18, §12 rows and the interrupt paragraph, alarm.txt `far` (§8,
  dfpilot/alarm.py), appendix regenerated; RULES §7 INTRUDER row and §10 arrival lockdown (in place, 300 lines);
  DESIGN §4.
- Tests (k_mock siege world, the real sense, threat, siege, gate, reflex and arbiter):
  - `tests/lua/test_reflex.lua`:
    - the Run 11 replay: ELK_BIRD 28188 (no CAN_LEARN/CAN_SPEAK) at the open map edge, an ambush lockdown: no
      INTRUDER, no ALERT, LOCKDOWN_END after hold_quiet_days (`cause` far, `animal 28188 ELK_BIRD at 184,1,10 (132
      tiles)`), doors open, clock free; near a woodcutter on a roofed tile it is a PREDATOR (ALERT), still no arrival.
      Old code: an `invader` ARRIVAL, INTRUDER, ALERT, the lockdown never ends.
    - one goblin 98 tiles away: far INTRUDER, LOCKDOWN_END cause far, ALERT_END, no re-arm for 3,000 ticks, the list
      persisted; 18 tiles from an entrance: ARRIVAL again, lockdown and ALERT. Old code: no LOCKDOWN_END.
    - guards: a goblin within 40 tiles keeps the lockdown; `lockdown_near` 0 keeps the old rule; six invaders (SIEGE)
      never end it far.
    - the ack timeout: no LOCKDOWN for the far INTRUDER (alarm.txt `far`, kern.log), DEFCON 2; it comes near: a new
      INTRUDER at once and its LOCKDOWN. Old code: LOCKDOWN `unacked:INTRUDER` for a unit 98 tiles away.
  - `tests/lua/test_siege_sense.lua`: the raw rule (animal, goblin, mount flag alone, a mount that can learn, nothing
    known); threat's predator rule for an animal invader and the expired-far exclusion.
- **How to use:** nothing to send. LOCKDOWN_END `cause far` lists what is still in sight. Tell the player the fort
  went back to work with those far away; the kernel re-arms on its own if one comes within 40 tiles. A larger margin:
  raise `lockdown_near` in config/reflex.json (0 restores the old rule).
  - Within 1,200 ticks ALERT_END: the bird no longer counts (an animal), mode PEACE. `threat 1 vis` stays (visible).
  - Within about 2 game days (ARM after the last trigger, then hold_quiet_days) LOCKDOWN_END `lockdown over
    (arrival:ambush): threat 0 for 2 days, 1 far: animal 28188 ELK_BIRD at 184,1,144 (N tiles), 6 doors opened`; the
    six doors unforbidden, clock free, timestream back (~400 t/s), idle falls as the runner builds again.
  - If its raws can learn or speak, it stays an invader (ALERT holds, the LOCKDOWN_END names `inv 28188 ELK_BIRD`):
    the far rule ends both all the same, ALERT_END 1,200 ticks after LOCKDOWN_END, `status` `1 invaders far`.
  - No LOCKDOWN_END after 3 days: kern.log `came within` (it walked near an entrance or a citizen), or a new
    ARRIVAL/INTRUDER restarted the clock; `dfllm events --type LOCKDOWN` must show no `unacked:INTRUDER` for it.
## The snapshot queue no longer starves: a K.call is the caller's cost, inbox exports go first; the runner's shaft check sliced and cheaper; doctor names a starving queue and the top cost (BUG-033; 2026-10-17; offline, live-untested)
- **Why (Run 11, Kilrudrabed site98, y438 winter, kernel e3a62ab), for months:** `dfllm bp sites <tpl> --fresh --timeout
  150` -> `no snapshot within 150s`; `dfllm audit` -> `snapshot refused: export queue full`; readiness `audit_old` (4.5
  years); `plan check` on a stale snapshot (`explore: only 0 free site(s)`), so no explore while the fort had no iron and
  0 bars. `dfllm doctor` in PEACE: kernel 54 ms/s on average, runner 35 ms/s, max 447 ms (limit 25), frame gap 21 s.
- **Cause 1 (proven offline):** kern booked every `K.call` to the callee. The other modules' `snapshot.tile`,
  `liquids` and `far` queries (runner probes and shaft check, economy's census and fishing search, water, care,
  military, reflex) went into snapshot's pacing debt. Its export slices wait while that debt is over one second of its
  share (6 ms/s, halved in the PEACE pool), so once the queries cost about that much, the running export never got
  another slice. Test: 1,500 tile reads per runner run keep an 81,920-tile export from finishing for 10 min on the old
  kernel; it finishes in about a minute now.
- **Cause 2 (proven offline):** nothing ever left the queue. No age limit, no dedup by purpose or box, no priority.
  readiness asked for a new audit every game month (about 75 s real time) whether its last one was exported or not, so
  a stalled queue filled up (4 waiting + 1 running) and refused everything after it, naming nobody.
- **Checked, not the cause:** trade's busy boost (BUG-026) is released (30 s TTL, unboost at LEAVE/IDLE, mode change,
  back-off); an export now waits for it at most 3 min. A faulting export would also have held the queue (now dropped).
- **Cause 3 (the runner's cost; suspected for the live numbers, measured offline as work):** the daily shaft check
  (8cc2e8e) decoded every bp file of the fort after each boot, the non-explores twice, 8 files a run. Every look at a
  finished explore decoded its file again. Up to 4 shafts ran in one slice, each wet candidate with a 25 x 25 x 3 water
  read, every day, for every shaft. Offline (12 finished explores beside seepage): 16,064 tile and water reads a game
  day before, 1,970 now.
- **kern:** a `K.call` from one module into another is the caller's cost: booked and paced in the caller's step. A slow
  call is judged on the module's own code, so such a call demotes neither side (the service was demoted for its
  callers' queries before); KERNEL_SLOW/KERN_FAULT `slow` name the callee: `economy demoted x2 (+6 ms in snapshot
  calls)`. The callee's part is kept as the edge `caller>callee`: perf.csv `mods` entries (no owners, not
  added to `ms_s`), `inspect what=modules` `svc`, state `k.top` (`runner 35 (snapshot 20)`: the top owner of the last
  minute and the module its calls spent the most in). Faults still count against the callee; a call from kern itself
  (inspect) stays with it. A site-data record of 64 KB or more is named once a boot in kern.log (`persist m.runner: N KB
  encoded (its owner pays each write, at most every 60 s)`); `inspect what=persist` adds `bytes`.
  - Side effect: modules that query a lot (runner, economy's census and fishing search) are now paced for those
    queries, so their passes take more real time; the totals stay within the shares and the pool.
- **snapshot:** the queue now works as follows.
  - Every request names who asked (`by`: `readiness`, `economy`, `inbox:cli`, `inbox:follow`, ...).
  - An inbox request (a CLI or follow waits for its file) goes ahead of the kernel's own and runs boosted
    (`sched.BOOST.shares.snapshot` 12 ms/s, never busy). A running kernel export waits at its row and resumes after it.
  - In a full queue, an inbox request pushes the newest kernel request out.
  - A request for the same purpose whose box equals, contains or lies in a waiting one joins it. One scan covers the
    union box; each request id still gets its own file and SNAPSHOT_READY.
  - `any` (economy's sand) is satisfied by any export queued or running.
  - Dropped, with a kern.log warn `snapshot: dropped <ids> (...): <why>`: a request waiting longer than 15 min (inbox)
    or 30 min (kernel), a running export without a slice for 10 min, an export whose slice failed twice.
  - Refusal: `export queue full: running <id> <purpose> by <by> P% for T (<why it waits>); queued N: <id> <purpose> by
    <by> T, ...`. Reply when queued: `queued snapshot <id> (next | in line N behind ... | joins <id> (...))`.
  - kern.log when written: `snapshot: <ids> (<purpose>, N tiles, by <by>) written T after the request (T scanning)`.
  - State `snap` = {q, old_s, done, drop, run, p, by, pct, wait}.
- **readiness:** the monthly audit waits while its last audit snapshot is still queued or exporting (`snapshot.pending`,
  kern.log `readiness: monthly audit waits for snapshot <id> ...`).
- **runner, shaft check:** now its own task, sliced: the stopped digs and the bp scan in the first slice, then one shaft
  a slice.
  - Only an explore's bp file is decoded (the compact JSON names `"tpl":"explore"`), and once a boot.
  - The water box grows 3x3, 9x9, 25x25 only while the flood reaches its edge. A candidate inside a flood already read
    is skipped, and the candidates share their reads.
  - A finished shaft whose last look found water in reach but no cavern (m.runner `xs.q`) is looked at every
    `fin_every` (8 days). Dry ones and live explores stay daily; looks run at the run's start tick.
  - Also: `own_tiles` is cached per project (damp reports, breach tests); `M.remake` checks its budget before it reads
    the cells.
- **doctor/status:**
  - doctor line `top cost: runner 35.0 ms/s (snapshot 20.0 of it, in its calls)`.
  - doctor line `snapshot queue: 5 waiting, oldest 12 min; first <id> audit by readiness 40% (paced 9 min)`.
  - doctor problem `snapshot exports starve (...)` once the oldest request waits 5 min while the first one gets no
    slices (`busy`, `paced N min`, `not started N min`); status then shows the queue line, and `top ...` in its kern line.
- Contracts: CONTRACTS §3.3.8-9 (caller pays, edges, snapshot boost), §4 `K.call`, §7 `snapshot.export` (opts, note,
  queue rules, refusal text) and `snapshot.pending`, §9.3 `k.top` and `snap` (schema, contract.lua, appendix), §9.11
  perf.csv edges, §12 CAVERN_PLUG shaft check (`xs.q`), §13 `snapshot` verb, §19 SQ. RULES rows `snapshot` and
  PERF_DEGRADED (no new lines).
- Tests (fail on the old code):
  - `tests/lua/test_snapshot_queue.lua` (new, 9 of 10 fail on e3a62ab; the fault case is a guard): the live starvation
    on the real kernel; caller pays with perf.csv/inspect/state traces; the boosted inbox export ahead of a kernel one;
    joins; the full queue; age/stall/fault drops and the busy cap; `any`, `pending` and state; readiness' monthly wait;
    the persist size line.
  - `tests/lua/test_runner_load.lua` (new, all 3 fail): the bp folder after a boot, the daily check's reads and slices,
    the remake budget.
  - `tests/test_doctor_load.py` (2 new): the edges are no owners, the top cost line, the starving queue line and problem.
  - Adapted: `test_snapshot.lua` (a full queue of distinct boxes, the refusal text), `test_readiness.lua` (`by`),
    `test_runner_shaft.lua` (each shaft keeps its own day phase).
- **How to use:** nothing to send.
  - A `snapshot refused: export queue full: ...` now names the running export, who asked and why it waits. Tell the
    player; nothing to cancel by hand (it drops itself after its age or stall limit).
  - `dfllm doctor`: read `top cost:` and the `snapshot queue:` line.
- **Live check (Run 11 site98):** after `git pull` and `dfhack-run dfllm reload`, in PEACE:
  - `dfllm audit` writes its snapshot within its 60 s. kern.log shows `snapshot boosted: export aud... for inbox:cli`,
    then `snapshot: aud... (audit, N tiles, by inbox:cli) written T after the request`, then `snapshot boost ended`.
    The audit is sent; `dfllm status` drops `audit_old` once readiness has it.
  - `dfllm bp sites <tpl> --fresh --timeout 150` lists sites within about a minute; `plan check` sees free explore sites
    again.
  - `dfllm doctor` after 10 min: `top cost: ...` names the owner and its calls, perf.csv rows carry `runner>snapshot=`,
    and no `snapshot exports starve` problem. runner should be within its share (about 4 ms/s, or 16 ms/s outside
    PEACE).
  - `dfllm cmd inspect '{"what":"modules"}'`: snapshot `svc` (ms served to others) and runner `debt`/`paced`/`factor`;
    `{"what":"persist"}` `bytes`. A `persist <key>: N KB encoded` line in kern.log names a big record (m.runner: report
    its size).
  - kern.log `cavern check:` lines keep coming (one shaft a slice); `N more next run` should vanish after the first game
    days; `readiness: monthly audit waits for snapshot ...` only while one is pending.
  - If `snapshot exports starve` remains: read the `snapshot: ...` lines (who asked, why it waits) and `inspect modules`
    for snapshot's `debt`, `paced`, `disabled`, and report them.

## A dry hospital loses its zones before its patients die; a hospital is planned only near accepted water (2026-10-17; offline, live-untested)
- **Why (Run 11, Kilrudrabed site98, y439 spring d28, BUG-034):** DEATHS_PREVENTABLE: 5 bedridden patients died of thirst
  (75,000), 8 more were over 40,000. The hospital (4 locations 6/8/10/17, 5 zones) had no accepted water (`water NO`);
  HOSPITAL_DRY had said so for a long time and its recipe asked to "delete the hospital zone", which nothing in the kernel
  could do. The game session removed the 5 zones by hand: GiveWater jobs brought water again (4 at once). The plans kept
  drafting `hospital` (y439 s2).
- **Kernel (`water.lua`, new act `hospital_remove`, owner water):** while a patient's thirst is over `water.patient_thirst`
  (config/baseline.json, 25,000), every zone of a hospital location none of whose zones has an accepted source within
  `near` (30) tiles is removed (zones screen > remove, one zone by id, only zones linked to a HOSPITAL location, never the
  zone open on the zone sheet), at most `remove_per_run` (8) a run; a location with one served zone keeps all of them.
  - HOSPITAL_REMOVED (A): `removed 5 dry hospital zone(s) 61,62,63,64,65 (location 6,8,10,17): 8 patient(s) over thirst
    25000, unit 10 at 48000; nearest accepted water 60,12,5 (46 tiles); water before a new hospital` (d: zones, locs,
    units, n, thirst, patients, give, failed, near, src, d). No patient_thirst or HOSPITAL_DRY in that run.
  - kern.log: the removal (warn, with the GiveWater jobs running then) and, a day later, `water: a day after the hospital
    removal (tick T): N GiveWater job(s), ...` (`inspect water_sources` `removed`): the next live removal measures the DF
    rule it rests on (BUG-034 lists what is established and what is not).
  - HOSPITAL_DRY's recipe tail is now `until then the kernel removes it at thirst 25000`; patient_thirst's recipe says
    `(GiveWater resumes or patients fetch their own drink)`. `water.hosp_remove` false keeps the old report-only way.
  - water.conf ignores a config value of another type than its default; `python -m dfpilot.lint --config` checks the
    `water` keys and ranges (`fairplay.WATER_LIM`, mirrored from water.lua by a test).
- **State `water` (owner water):** `{patients, thirst_max, hosp_ok, refuge_ok, buckets_free, hosp, src}`, `src` = up to 8
  accepted sources [x,y,z] nearest the hospital (else the citizens) first. The brief/status line shows it as
  `hospital ok|DRY|none src N patients N (thirst N)` instead of care's narrower `water ok|NO` (`stock.hosp_water`).
- **Plan:** `plan check` refuses a plan that adds a `hospital` while no accepted source lies within `near` tiles of the
  hospital's site (the S1 anchor of `bp sites hospital`) or the state lists none; the error names the fix (a cistern
  first, or the cistern under way must hold water). No sites snapshot: a warning (distance not checked). An older kernel
  without the `water` key: not checked. `plan propose` holds the hospital back under the same rule and drafts
  `cistern@S1` in its place once (not while a cistern project or room exists), with a note; so the hospital is no longer
  drafted each review while the fort has no water.
- Contracts: ACT `hospital_remove` (water), EVENTS HOSPITAL_REMOVED (A, water), STATE `water.*` (contract.lua, schema.py,
  CONTRACTS §5/§7/§9.3/§9.17/§12 and the appendix), RULES §7 `HOSPITAL_DRY / HOSPITAL_REMOVED`, DESIGN §5 hospital water,
  FR-34 status, follow's wake hint.
- Tests (fail on fcada16): `tests/lua/test_water.lua` (Run 11 replay, a served location keeps its zones, the mark and the
  config knobs, remove_per_run, a refused removal, `water.src`), `tests/lua/test_kern_act.lua` (hospital_remove),
  `tests/test_hospital_water.py` (schema, config, plan check/propose, fort facts, status). Existing water tests that are
  about patient_thirst run with the removal off; the HOSPITAL_DRY recipe tests expect the new tail.
- **How to use:** nothing to send. HOSPITAL_REMOVED: tell the player which zones went and why; the next plan puts water
  first (`plan propose` drafts the cistern; `plan check` refuses a hospital without water near it). Once real water stands
  near the old room, re-zone it as a hospital by hand or place a new one (`bp sites hospital`).
  - `state.a.json`/`b.json` carry `water` (`hosp`, `src`); `dfllm status` shows `hospital DRY src 0 ...` or `hospital
    none ...` (the zones are already gone by hand).
  - If a hospital zone stands dry and a patient's thirst passes 25,000: within a game day HOSPITAL_REMOVED wakes, the zones
    are gone from the zones screen, kern.log has `water: removed hospital zone(s) ...`; a day later `water: a day after
    the hospital removal ...: N GiveWater job(s)`. N > 0 with thirst falling confirms the rule; N 0 with patients still
    thirsty: read the patients' job lines and the gamelog (`Give water: ...`) and add it to BUG-034.
  - `dfllm plan propose`: no `hospital` in the draft while `water.src` is empty or far, `cistern@S1` instead (unless a
    cistern stands or is under way) and the note `hospital held back (BUG-034): ...`; `dfllm plan check` on a plan that
    still adds the hospital prints `ERROR hospital (seasons[N]): ...`.
  - `python -m dfpilot.lint --config` prints `config ok`.
## A seal door that cannot stand becomes a constructed wall: the template checks the door rule, the runner walls a door quickfort refuses (2026-10-16; offline, live-untested)
- **Why (Run 11, Kilrudrabed site98, y435 autumn, kernel c75b7c0):** the seal piece door 128,121,143 (project
  c1a147087d) stayed `build_lost` although the fort had 26 boulders and 171 logs. quickfort `#build d` on that tile by
  hand: `Unsuitable tiles for building: 1`, buildings designated 0. The tile is a revealed GrassDarkFloor2 FLOOR (no
  plant, building, unit or item, outside=false); a door already stands on its neighbour 127,121,143. `Cw` on the same
  tile designated at once. The runner counted the refused door as lost, placed it again (the one re-apply, then
  `remake_max` more since economy could make a door) and blocked `build_lost`; its retries repeat the door.
- **The door rule (read from DFHack's `internal/quickfort/build.lua`):** `d` uses `is_tile_generic_and_wall_adjacent`.
  The tile must be generic (floor, boulder, pebbles, twig, sapling, shrub; revealed, flow <= 1, no building), and at
  least one of its four orthogonal neighbours on the same z must have the tile shape WALL or FORTIFICATION. In the
  snapshot legend: `#`/`S` natural wall, `C` constructed wall, `F` fortification, `T` tree trunk. A door or hatch
  beside it (a floor under a building), a bridge, another building, open space, ramps, stairs and diagonal walls do not
  count. A wall planned in the same stage does not count either: quickfort places the stage at once. Hatches, wall
  grates, vertical bars and floodgates need no support. Uncertainty: quickfort reads a hidden neighbour's real tile
  type, which we may not. Its header says it enforces the in-game rule ("doors have to be adjacent to a wall"); DF's
  own build menu was not checked. So a hidden neighbour, or no snapshot, keeps the door, and quickfort decides.
  `validate.py` and the as-built simulation assumed nothing here before; the simulation now applies the rule.
- **Template and CLI (`bp/defense.py`, `cmd.seal_openings`):** `defense.door_stands(char_at, pos)` returns True (a
  wall beside it), False (all four neighbours revealed, none a wall) or None (the snapshot cannot tell).
  - A door piece (auto, door or hatch on a floor-like or shrub tile, with the seal's `close`) on a False tile gets the
    new `at` token `nodoor`. Example: `128,121,143 floor nodoor`, also with `for=`. seal_pieces emits `Cw` for it, so
    `materials` counts a wall.
  - The `seal:piece` line reads `128,121,143 floor: door unsuitable at 128,121,143 (no wall or fortification beside
    it): wall instead`. A `seal:note` reads `... (... on the snapshot): wall instead`.
  - An explicit `door` gets the wall too. `close=grate`/`bars` keep their piece.
  - `at` now stays within `AT_MAX` (200, bp.emit's string limit); the rest goes to `N more for the next seal`. Six
    `for=` openings with `nodoor` would have run past it.
- **Simulation (`bp/render.py`):** `as_built` reports `build d at x,y,z: no wall or fortification beside it (quickfort
  refuses the door; a wall of the same stage is not built yet)`, so validate gives `build_tile`. Every template's
  doors pass it (all stand in rock doorways).
- **Runner (`door_walls`):** after a seal build chunk whose `build_unsuitable` exceeds the occupied tiles, each `d`
  cell with nothing on its revealed tile is planned once as `Cw` on the same tile.
  - The cell changes in `bp.<id>`, which is set again. This is the one exception to "written once"; a seal document is
    small. `materials` changes from door to wall.
  - The tiles go into m.runner `dw[<proj>]` (<= 8), and the chunk is applied again in the next slice. The pieces it
    placed already count as occupied, not lost.
  - kern.log (warn): `c1a147087d seal.build: door unsuitable at 128,121,143: wall instead (quickfort refused the door;
    no wall or fortification beside it)`. The reason is added when the revealed neighbours show it.
  - PROJECT_BLOCKED and PROJECT_DONE carry `walled` (`x,y,z`) and say it in the msg: `... missing Cw; door unsuitable
    at 128,121,143: wall instead; retry 1/8 ...`, or `c1a147087d (seal) done; door unsuitable at 128,121,143: wall
    instead`.
  - A wall refused too ends as before (`build_lost`, missing `Cw`); the door is never tried again.
  - A seal that an older kernel left `build_lost` with such a door (the live c1a147087d) is retried once for it, at
    the daily check. kern.log: `c1a147087d: build_lost at seal.build, retry N/8 from seal.build (its door at
    128,121,143 has no wall or fortification beside it: a wall if quickfort refuses the door)`; m.runner `rty` `dw`.
  - A wall shuts the fort's own way through that tile for good (a door only in a lockdown); CUTOFF still watches the
    walk groups.
- Contracts: PROJECT_BLOCKED and PROJECT_DONE `walled` (schema, contract.lua comment, CONTRACTS §12 rows and appendix);
  CONTRACTS §10 `bp.<id>` exception; seal `at` token `nodoor` (DESIGN §5 seal); RULES §7 PROJECT_BLOCKED.
- Tests:
  - `tests/bp/test_bp_seal_door.py` (new, all 6 fail on 6dd9f2d): the live replay (REFUGE_FAIL fix beside a door ->
    `nodoor`, `Cw`, the piece line, validate clean); the door rule per legend char; explicit door, close, wall beside
    it, hidden neighbour, no snapshot, shrub; the `nodoor`/`for=` round trip; the `AT_MAX` cap; the simulation rule.
  - `tests/lua/test_runner_door.lua` (new, all 4 fail on the old runner): the live tiles (door, then `Cw`, log line,
    persisted cell and `dw`, PROJECT_DONE `walled`, no build_lost); a chunk with a supported and an unsupported door;
    the wall refused too (one door call, PROJECT_BLOCKED text); c1a147087d as kernel c75b7c0 left it (retried within a
    day, walled, done) and the once rule.
  - `tests/lua/runner_world.lua`: the fake quickfort applies the door rule; every existing suite still passes.
- **How to use:** nothing to send.
  - A PROJECT_DONE or PROJECT_BLOCKED with `door unsuitable at x,y,z: wall instead`: tell the player that tile is
    walled. If citizens lose a way, CUTOFF names it.
  - To keep a door there, the player builds a wall or pillar beside the tile by hand first.
  - `seal at=...` placements show the `nodoor` choice in their `seal:piece`/`seal:note` lines.
- **Live check (Run 11 site98):** after `git pull` and `dfhack-run dfllm reload`, within a game day (PEACE) kern.log
  shows the retry line for c1a147087d, then `c1a147087d seal.build: door unsuitable at 128,121,143: wall instead
  (quickfort refused the door; no wall or fortification beside it)`.
  - In DF: a constructed wall is planned on 128,121,143 (buildingplan waits for boulders/logs if none are free) and
    gets built.
  - PROJECT_DONE: `c1a147087d (seal) done; door unsuitable at 128,121,143: wall instead`; `dfllm cmd inspect
    '{"what":"refuge"}'` then shows Kern+ no longer open there.
  - If the line says `quickfort refused the door` without the reason, a neighbour is hidden or a wall: read the four
    tiles in DF.
  - No retry line within two days: the project is not `build_lost` in PEACE, or its retries are spent (`inspect
    persist` m.runner `rty`). Then `dfllm cmd bp.cancel '{"proj":"c1a147087d"}'` and `dfllm cmd bp.place tpl=seal
    site=S1 at=last`. cli.log should show `seal:piece ... door unsuitable at 128,121,143 ...: wall instead`.
## TOOL_BLOCKED names what keeps DF from handing the picks out; melt marks, forbidden tools and a second tool labor repaired; unvalidated orders name the absent manager (2026-10-16; offline, live-untested)
- **Why (Run 11, Kilrudrabed site98, y434 spring):**
  - BUG-023 goes on: TOOL_BLOCKED `Miners: ... hold no pick for 240 days, 14 dig jobs open; 3 free picks loose`. The picks
    1836340, 1885239 and 1886349 lay on the floor, not forbidden, not reserved, on the citizens' walk group; the release
    sweep (d4d1a96) and 240 days of equipment update requests (697a95d) changed nothing, and the report could not say why.
  - New work orders (ConstructCoffin wood x25, four ConstructDoor wood) stayed unvalidated: the manager (hf 5443) rested
    with a wound. ORDER_STUCK named their material instead; kernel orders wait the same way.
- **Causes:** proven from the code: the census counted a melt-marked or owned pick as free (live L1b: melt marks kept the
  spare picks from the miners for a year) and ignored forbidden picks entirely (TOOL_BLOCKED needed a free one); a member
  could keep a second tool labor (MINE + HUNT/CUTWOOD) no detail grants; TOOL_BLOCKED read nothing of DF's equipment lists,
  the work tool pairs, the members' burrows or the civ alert. Suspected (the diagnosis reads each): the picks are in no
  free list (unmanifested after their miners died in siege 3), DF keeps them as dead miners' work tools, the members are
  paired with lost picks, or a burrow holds them. The order reasons never looked at `status.validated`.
- **Diagnosis (economy, daily while a tool detail is blocked, read-only, `economy.tool_diag`):**
  - Per free tool (4, forbidden ones after the free): flags (in_job, owned, melt, forbid, artifact, hostile, encased,
    foreign, container), DF's list (`u` items_unassigned, `a` assigned, `m` unmanifested, `-` none), its work tool pair
    (`work_weapons`/`work_units`, read as parallel vectors: unit and dead/gone/soldier/member/other), owner, `far`, the
    building on its tile.
  - Per member without one (6): the detail's labor, a second tool labor, DF's pair for him (`wu=item:held|loose|forbidden|
    gone|held by N`), the burrows DF keeps him to (the civ alert's while it sounds, else `unit.burrows`) and the free tools
    in them, the tools on his walk group (snapshot.groups), the first 40 open dig/FellTree jobs he can take (his group, his
    burrows: a tool job is what sends a dwarf for his tool), `uniform_pickup`, a pending `pickup_flags.update`, patient,
    job; DF's pending `update.weapon` (kern.log).
  - Blockers in order: `labor`, `tool2`, `alert`, `burrow`, `walk`, `jobs`, `pair`, `flag`, `pool`, `upair`, `fetch`,
    `pending`, else `none`. TOOL_BLOCKED gains `blk` (texts), `bk` (keys), `picks`, `units` (compact records, <= 3), `civ`, `ww`,
    `forb`, the message the first text when it fits; a new blocker key is news (util/cadence). kern.log `tools: Miners
    blocked (<keys>): <texts> | civ alert burrows N, work tool pairs N | picks: ... | members: ...` at the first pass after
    a load and whenever the diagnosis changes; `inspect` `{what:'workload', key:'tools'}` returns every record, and the
    workload `blocked` rows carry `blk`.
- **Repairs (economy, act):**
  - A free pick/axe marked for melting loses the mark while members lack it (act.item_flag, the item sheet's toggle), as many
    a day as lack one (kern.log `... marked for melting while N members hold none: melt mark taken off`).
  - Forbidden picks/axes nobody carries are counted (`w_pick_forb`, `w_axe_forb`; also `w_pick_melt`, `w_pick_own` and the
    axe ones; `inspect workload` `tools`) and unforbidden by T.forbid (PEACE/RECOVERY, revealed, on the walk group) while
    members lack that tool; TOOL_BLOCKED also comes with only forbidden ones (`N forbidden`).
  - One tool labor per dwarf: `act.work_detail` joining Miners, Woodcutters or Hunters switches the other two tool labors off
    when no detail grants them (a second tool detail the unit is in keeps its labor); economy's repair makes that pass for
    such a member (`held a second tool labor (HUNT, no detail grants it): taken off through the detail`, with the
    equipment request).
  - Not built: item moves, edits of `work_weapons`/`work_units`/the equipment lists (no UI does them), hauling jobs or a
    stockpile for the picks (v1 measured that bins and stockpiles do not decide it), `setAutomaticProfessions` (DF's work
    detail pass would give the miners the everybody-does-this labors back).
- **The absent manager (economy orders part):** `economy.manager_state` reads the MANAGER holder: none appointed, gone
  (dead, left, off the map), resting/injured (needs health care or rests in bed), in a strange mood. An unvalidated order
  while he cannot validate has only that reason: ORDER_STUCK `why` `unvalidated: no manager available (manager Ber
  resting/injured)`, also in `inspect orders`. After `orders.manager_days` (3) of unvalidated orders: DECISION_NEEDED
  `manager_absent` (A, util/cadence: once per manager and reason) `no manager available (...) for N days: M orders not
  validated (ConstructCoffin x25, ...)`, q: appoint an acting manager on the nobles screen? The kernel never replaces a
  holder (no act verb; the player's choice); the office question (`manager_office`) waits meanwhile; kern.log `manager
  orders validated again` ends the episode.
- Contracts: TOOL_BLOCKED `forb blk bk picks units civ ww` (schema, contract.lua comment, CONTRACTS row and appendix); the
  census keys `w_*_forb/_melt/_own`; `act.work_detail`'s tool labor rule; `inspect workload` `key:'tools'`; ORDER_STUCK's
  manager reason; config `economy.orders.manager_days` (`config/baseline.json`); RULES §7 TOOL_BLOCKED and DECISION_NEEDED
  rows; `dfllm follow`'s TOOL_BLOCKED hint (`key:'tools'`). BUG-023 section "Fourth live check".
- Tests (fail on the old code): `tests/lua/test_economy_tools.lua` (four `BUG-023 round 5` cases: a pick paired with a dead
  unit, an unmanifested one and a member paired with a gone pick, the kern.log line and `key=tools`; a second tool labor,
  the civ alert and an own burrow, a new blocker is news; melt mark off, forbidden picks counted, unforbidden and reported
  without a free one; the dig jobs and the picks off the members' walk group), `tests/lua/test_act_supply.lua` (one tool labor), `tests/lua/test_economy_orders.lua` (the resting
  manager: reasons, DECISION_NEEDED, recovery, a dead manager; an available manager keeps the old reasons).
  `tests/lua/test_economy_jobs.lua` reads the new tool counts.
- **How to use:** TOOL_BLOCKED: read `d.bk`/`d.blk`; `labor`, `tool2`, melt and forbidden picks the kernel repairs itself;
  `alert`/`burrow`/`walk`/`jobs`: which burrow (lever rooms, the civ alert) or walk group keeps them from the tools or the
  jobs; `pair`/`pool`/`upair`/`fetch`/`pending`/
  `none`: DF's own equipment state, tell the player with the records from `key:'tools'` (no verb fixes it).
  DECISION_NEEDED `manager_absent`: ask the player for an acting manager.
- **Live check (Run 11 site98):** after `git pull` and `dfhack-run dfllm reload`, within a game day:
  - kern.log `tools: Miners blocked (<keys>): ...` with the three picks (1836340 103,108,139 ...) and the members; then
    TOOL_BLOCKED with `bk`/`blk`. `dfllm cmd inspect '{"what":"workload","key":"tools"}'` for every record.
  - Expected reading: `pool` (`1836340:unmanifested` or `:none`: DF lost them from its free list), `pair ... (dead N)` (DF
    keeps them as dead miners' work tools), `upair` (a member paired with a lost pick), `burrow`/`alert`, `walk`/`jobs`,
    `fetch`,
    `pending` or `none`. Report the line to the dev session; with `fetch` look at the member's job.
  - Orders: `dfllm cmd inspect '{"what":"orders"}'` lists the coffins/doors with `unvalidated: no manager available
    (manager <name> resting/injured)`; after 3 days of it DECISION_NEEDED `manager_absent`.

## The daily shaft check: an explore shaft open to a cavern is plugged in any project state, a hatch is no plug, explores stop above known cavern levels (2026-10-16; offline, live-untested)
- **Why (Run 11, Kilrudrabed site98, y432-433, kernel a6c33a9 with the cavern plug):** CAVERN_PLUG never came for the
  explore c1a14676. It stood at `dig 98 % stalled` while its shaft 136,73 (z137 down) was open next to a cavern lake
  (1146 water tiles on z127). Earlier it had ended `BREACH_STOP damp`; after the reload it showed as stalled, not
  stopped. The game session then put a hatch on the shaft top (`seal at=136,73,137`) and cancelled c1a14676, but by the
  doctrine a hatch does not hold forgotten beasts or building destroyers. Later explores kept hitting the z127 cavern
  lakes (y432s1b0 at 112,59 was plugged cleanly).
- **Cause:** the plug of the cavern-plug entry below comes only from a breach stop (`breach()`, with a tile and the
  project document) and from the daily recheck. The recheck takes a project only while it is stopped as
  `breach:damp|water|cavern|cavern_lake`, not done and without a plug record (m.runner `cav`). `runner.cavern_open()`
  (readiness `caverns`, threat) lists only those records. A stalled explore (or a running, blocked, done or cancelled
  one) was never looked at, so readiness never saw the open shaft. Nothing in the runner turns `breach:*` back into
  `stalled`, so the stop was lost outside it. Most likely (not verified live): the reload restored site data older than
  the map. kern writes changed site data at most every 10 s (keys >= 8 KB such as m.runner every 60 s), and nothing
  writes it before a DF save. A save inside that window keeps the dug shaft and the undone designations but holds the
  project as it was before the stop. Its undone tiles then read as lost and were designated once more; nobody could dig
  them, so the project stood at 98 % and stalled after 7 days. The explore ranking also knew nothing of the z127 lakes:
  they lie below the sites snapshot, so its cavern marks never showed them.
- **Shaft check (runner, every mode):** every explore's stair column is recorded (m.runner `xs[<id>]` = {x, y, top,
  low, t, c, fin, off}; at most `shaft_keep` 24). The record is made from the document when the check first sees the
  project, and when the project is done or cancelled, so it outlives the project. Explores that left the list before
  their record existed (c1a14676) are found in `<save>/bp/*.json`, `scan_n` (8) files a run after a boot, with state
  `gone`. A shaft is looked at at the first run after a boot and then once a day, at most `shaft_n` (4) per run. A
  stopped explore keeps its stop's cadence (m.runner `br`). The check runs whatever the project's state: running,
  stalled, blocked, stopped, being cancelled, done, cancelled or gone.
  - What it reads: a column whose top is dug is read top down on revealed tiles. Its bottom, its tiles that hold water,
    the stored breach tile and up to `shaft_probe` (60) dug tiles of the document that hold water go through the breach
    test of the entry below (`opened_at`; `runner.opened` is unchanged). A cavern lake or an open cavern there plugs the
    shaft at once.
  - CAVERN_PLUG `queued` gains `state`, with msg `c1a14676 (stalled; shaft check): the shaft 136,73 z137-127 opens into
    a cavern lake at 136,73,127; plug ...`.
  - A project still digging (running, stalled, blocked) is stopped first: BREACH_STOP src `check` with `state`, msg
    `c1a14676: cavern lake (check, was stalled: 1146 water tiles in reach), digging stopped`, and its applied chunks
    are undone, so nobody digs on into the lake.
  - One stopped as damp/water is raised as before (src `recheck`). A `warm` stop keeps its name and is plugged.
  - A done, cancelled, cancelling or gone explore is only plugged.
  - A plug project for the shaft that outlived its record (an older m.runner after a reload) is used again, never a
    second one. An old CAVERN_PLUG `none` (no dug column then) is looked at again.
  - Non-explore stops keep the old recheck (CAVERN_PLUG `none`: walled by hand).
- **A hatch or door is no plug:** a shaft is closed only by a constructed wall, on its top or (with a hatch or door on
  the top) on the tile below it. CAVERN_PLUG `done` comes only then, and the check reads such a shaft as open: `(the
  hatch on its top is no plug)`. The plug walls the tile below first (channel + `Cw`, reached through the hatch). Once
  that wall stands the plug ends and the hatch stays. If that step is given up (`plug_wait`), stage `p0.free` removes
  the hatch or door with quickfort `undo` of its build key (`H`/`d`: the player's remove-building, a deconstruct job),
  in PEACE only (no open shaft in a fight, and seal retires a piece gone in PEACE instead of rebuilding it). The top
  is then channelled and walled. A hatch DF has not removed after `plug_wait` fails the plug (`the Hatch was not
  removed within 1 day`: by hand).
- **Known cavern levels for the explore ranking:** every tile where a dig broke into a cavern (each plug's breach:
  BREACH_STOP `cavern`/`cavern_lake`, the shaft check's hit) is kept in m.runner `cz` (<= 32, newest kept; made at boot
  from the existing plug and breach records). It is mirrored into the fort manifest as `caverns` (schema: manifest
  `caverns`). `bp.sites.avoid_levels` adds their levels, so no explore shaft reaches one. `plan propose` (fit_explore,
  unchanged) then fits the depth above them, and `bp sites explore` names them (`avoid, a cavern/damp/warm mark or a
  cavern breach`).
- **Readiness:** the plug record makes `runner.cavern_open()` list the shaft at once, and CAVERN_PLUG re-evaluates, so
  R0 `caverns` holds until the wall stands. Threat counts hostiles near the shaft from then on.
- **Log line (kern.log, info), one per run that looked:** for example `cavern check: c1a14676 136,73 z137-127 gone:
  cavern lake (1146 water tiles) -> plug pl5400 queued (the hatch on its top is no plug); e2 40,41 z100-95 running: no
  cavern (12 water tiles in reach)`. Other results: `closed (a constructed wall on its top)` or `(... below the Hatch on
  its top)`, `not dug yet`, `top hidden`, `plug <id> under way`, `plug <id> failed: wall the shaft top by hand`,
  `plugged`, `N more next run`. A stopped room dig reads `r1 (bedrooms) breach:damp: no cavern`. With nothing to look
  at, the first run after a boot logs `cavern check: no explore shaft and no stopped dig to look at`. A new cavern level
  logs `cavern at x,y,z (cavern_lake): explore shafts stop above zZ`.
- **Cost:** `opened_at` reads the wide `lake_r` box only when water touches the tile (a 3x3x3 read first: the flood
  starts only there); a dry shaft costs a column read plus about 30 tile reads per candidate.
- Fair play: revealed tiles only (snapshot.tile, snapshot.liquids, the cav flag); never water_table. Removing a hatch
  is the player's remove-building order.
- Contracts: CAVERN_PLUG `state`; BREACH_STOP src `check` and `state` (schema, contract.lua comment, CONTRACTS §12 rows
  and appendix); manifest `caverns` (CONTRACTS §11, schema); m.runner `xs`, `cz`; CONTRACTS `runner.cavern_open`.
  RULES §7 CAVERN_PLUG row, DESIGN §5 explore, `bp/sites.py` and `bp/mine.py` docstrings.
- Tests: `tests/lua/test_runner_shaft.lua` (new; every test fails on the old runner). It covers:
  - the live c1a14676: stalled at 98 % after a reload without the stop or a shaft record. It is stopped and plugged,
    `cavern_open` lists 136,73 z137-127, the pending arm tile is undone, the log line is right, and a further reload
    without the plug record reuses the plug;
  - a running explore, a done one and a cancelled one;
  - the log line (no cavern, closed, not dug, daily, at once after a boot) and a `warm` stop;
  - a hatch on the top: walled below, `done`, the hatch stays; the lower wall given up, so the hatch is removed in
    PEACE only and the top walled; a hatch never removed: `failed`;
  - an explore cancelled under the older kernel, found in the bp folder (`gone`); the manifest `caverns` rebuilt after
    a reload.

  `runner_world.lua` gains `H.hatch`. Also `test_readiness.lua` (R0 `caverns` at once on CAVERN_PLUG queued),
  `tests/test_runner.py` with `runner_shaft_dump.lua` (the new events validate), `tests/test_schema.py` (the `state`
  fields), and `tests/bp/test_bp_explore.py` (a recorded breach at z16 keeps depth 12 out, depth 6 fits).
- **How to use:** nothing to send.
  - On a CAVERN_PLUG wake with `state`, tell the player which shaft is walled. For a stalled/running/blocked state,
    `bp.cancel` the explore without undo; it is stopped already. For done/cancelled/gone there is nothing to cancel.
  - Leave a hatch the session put on a shaft: the plug walls below it (or removes it in PEACE). Never count a hatch as
    the fix.
  - To see why a shaft is or is not plugged, read the newest `cavern check:` line in
    `<DF>/dfllm-runtime/<save>/kern.log`.
- **Live check (Run 11 site98):** after `git pull` and `dfhack-run dfllm reload`, the first runner runs read the bp
  folder.
  - Expected line: `cavern check: c1a14676 136,73 z137-<bottom> gone: cavern lake (... water tiles) -> plug pl<tick>
    queued (the hatch on its top is no plug)`. CAVERN_PLUG `queued` comes with state `gone` and walls 136,73,136 +
    136,73,137; `dfllm status` shows the `pl<tick>` project, and `ready.fail` holds `caverns`.
  - In DF: a miner channels 136,73,136 through the hatch and a builder walls it, then CAVERN_PLUG `done` reads
    `constructed wall on 136,73,136 below the Hatch on 136,73,137`. Otherwise, after a day the hatch gets a
    remove-building job in PEACE, and the top is channelled and walled.
  - `inspect persist` m.runner `cz` and `<save>/manifest.json` `caverns` hold the z127 breach tiles (112,59 and others).
    `dfllm bp sites explore` / `plan propose` then keep the shaft bottoms at z128 or above: depth fitted, or the
    message names `cavern breach`.
  - If the line says `no cavern (N water tiles in reach)` instead, no revealed lake or cavern tile touches the shaft's
    dug tiles (its revealed bottom lies above the lake, z131 per the session). The shaft then ends in rock; it is not
    plugged, and the line says so. Compare the levels below the bottom in DF, and the N with `lake_min` 30.
  - `not dug yet` / `top hidden`: the column record is wrong. `inspect persist` m.runner `xs` names its x, y, top, low.
  - No line at all: the runner did not run (`dfllm doctor`).
## The trade depot after a siege: DEPOT_MISSING says what is done and its material (2026-10-16; offline, live-untested)
- **Why (Run 11, siege 3, pop 54 -> 29):** the siege destroyed the trade depot; the Muboomon caravan came (NO_DEPOT,
  DEPOT_MISSING). The keeper (`runner.depot_keep`, FR-43) queues only in PEACE/RECOVERY, and in any other mode the old
  line read `no known depot site` although fortcore's manifest names the depot; nothing named the depot's material
  while the fort had 1 boulder.
- **What it does now:** the runner's keeper (unchanged) queues the 5x5 depot at manifest.depot every run in RECOVERY
  and PEACE once none stands (test: BREACH refused, RECOVERY queued). DEPOT_MISSING names what is done: `project depot2
  queued`, `the kernel queues one in PEACE or RECOVERY (now BREACH)`, `no known depot site (no fortcore depot): place
  one by hand`, and the depot's material from `economy.mat_for('depot', 3)` (`building material: logs`, `no material
  for depot: no rock, no blocks, no logs`; d `mat`). The planned depot waits for building material like a wall:
  economy switches buildingplan's logs/boulders/blocks on when that is all the fort has; MATERIAL_SHORT names `depot`
  (also `workshop`, `building`; constructions stay `wall`).
- Contracts: DEPOT_MISSING `mat` (schema, appendix, CONTRACTS row); `economy.mat_for` kinds `depot`/`workshop`; RULES §7
  DEPOT_MISSING.
- Tests: `tests/lua/test_trade_ledger.lua` (the line in BREACH, RECOVERY and without a site; the keeper after a siege),
  `tests/lua/test_economy_pieces.lua` (a planned depot without material, logs switched on).
- **How to use / live check:** after the next siege, in RECOVERY `dfllm status` lists a `depotN` project and kern.log
  `trade depot missing (keeper): project depotN at x,y,z`; a caravan meanwhile gives DEPOT_MISSING with `project depotN
  queued; building material: ...`. If the line says `no material for depot`, tell the player (logs or stone). Keep O1
  down for the builders in PEACE.

## Seal pieces and furniture in the material the fort has, stone and picks as goals (2026-10-16; offline, live-untested)
- **Why (Run 11, Kilrudrabed site98 y432, BREACH, pop 54):** REFUGE_FAIL for Kern+ and Tiefe+ `open to 1 entrance
  128,121,143 floor beside door 127,121,143`; `seal at=last` stayed `build_lost (missing d)` while ConstructDoor was
  cancelled for rock: 1 boulder in the fort, ~110 orders said 'no rock' (quickfort `orders` makes every door, hatch and
  piece of furniture a rock order, live L3; economy's wood fallback kept 30 logs back and converted nothing), 2 picks,
  1 iron bar, idle 46-64 %; the game session placed bedrooms by hand for stone. Later 34 boulders and the refuge door
  still open: buildingplan waits for a door item, never for raw rock, and the door order was gone.
- **economy, the pieces planned buildings wait for (`T.jmake`, after `T.jmat`; `M.PIECES`):** a planned building's missing
  door, hatch cover, grate, floodgate, cabinet, chest, table, throne, armor/weapon rack or bed (no free or forbidden item
  of it) gets an order the fort can run: stone (Masons) while the free stone covers the open rock orders, else wood
  (Carpenters; doors, hatches, grates and floodgates keep only the moods' wood floor, not the config reserve), else stone
  behind the other rock orders while stone is free. An open rock order of that job the stone cannot cover is re-entered
  in wood (`act.order_material`) first. Walls (building material): what buildingplan allows; when that is all the fort
  has, its `logs`/`boulders`/`blocks` setting goes on (`buildingplan set logs true`, once a boot; never bars). Nothing
  makes it, or a seal piece queues behind the rock orders without logs: **MATERIAL_SHORT (B, new)** once per set
  (`no material for door: no rock, no logs (door x1 wait)`, `stone queued for door: behind the other rock orders, no
  logs; 34 free boulders, 110 in rock orders`, `...; 34 boulders are ore, flux, economic or soft stone`). Census: free
  `doors`, `hatches`, `grates`, `blocks_free`.
- **economy, rock:** a "Needs rock/stone/boulder" cancel of a one-time stone order while the free stone is short of the
  open rock orders is re-entered in wood at once when logs cover it; with no free stone at all the order is removed
  (ORDER_STUCK dropped, `no rock: ...`; `rock.drop_per_day`), not after 10 cancels; a rock cancel loop gets no
  `orders recheck` then (it only posted the jobs again; CANCEL_LOOP says `no recheck`). Free stone below what the rock
  orders, walls and needs want, a pick in the fort, no dig job and no runner dig backlog, no bedrooms project:
  PROJECT_REQUEST bedrooms why=rock (n 4, `short`) at most weekly; follow places it at prio 1 like care's mood_rock.
- **economy, picks:** picks below the Miners' demand (BUG-023's `tool_want`): a pick (MakeWeapon ITEM_WEAPON_PICK) from
  the first metal with a spare bar at a forge (copper first), else `economy.trade_wants()` -> `pick`, which trade puts
  after the moods' tokens and before plan.trade.want.
- **Hooks:** `economy.mat_for(kind, n)` (door, hatch, grate, wall, furniture kinds: `item`/`rock`/`wood`/a building
  material/`setting`, or nil + why), `economy.trade_wants()`. inspect workload: `stone`, `picks`, `short`.
- **runner (build_lost, small):** a seal stage whose pieces were lost is placed again up to `remake_max` (4) more times
  while `economy.mat_for` says they can be made (was: one re-apply, then build_lost); a `build_lost` seal is retried once
  its pieces can be made (daily; also a seal an older kernel blocked); PROJECT_BLOCKED names economy's reason
  (`missing d (no material for door: no rock, no logs)`, d `mat`).
- **plan:** `plan propose` drafts `{"tpl":"bedrooms","site":"S1","p":{"n":4}}` (after the audit seal and the refuge
  pieces) while state `stock.rock` < `stock.rock_need` and no dig template (bedrooms, stockroom, refuge_beds, explore) is
  under way, and puts `pick` first in trade.want (with `bar:iron`) while `stock.picks` < `stock.pick_want` and no bars;
  `plan check` warns without them. brief: MATERIAL_SHORT right after STOCK_LOW.
- Contracts: event MATERIAL_SHORT (B), PROJECT_BLOCKED `mat`, state `stock.rock`/`rock_need`/`picks`/`pick_want` (schema,
  contract.lua, appendix), hooks `economy.mat_for`/`trade_wants` (CONTRACTS §7), rows PROJECT_REQUEST why=rock,
  ORDER_STUCK, CANCEL_LOOP; config `economy.pieces`/`rock`/`picks` (baseline.json); RULES §7 PROJECT_BLOCKED, §10
  economy; DESIGN §5.
- Tests (all fail on 276b252): `tests/lua/test_economy_pieces.lua` (new: census, the rock door order to wood with 25
  logs, a planned door/hatch/grate ordered in wood or stone, MATERIAL_SHORT once, 34 boulders behind 110 rock orders and
  economic stone, walls switch buildingplan logs on, "Needs rock" to wood/removed and no recheck, PROJECT_REQUEST
  bedrooms why=rock, picks forged or wanted), `tests/lua/test_runner.lua` (the seal placed again while material exists,
  bounded; build_lost with the reason, the retry once the door can be made, an older kernel's record),
  `tests/lua/test_trade.lua` (economy's tokens), `tests/test_plan_stone.py` (new), `tests/test_cli_wake.py` (follow
  places why=rock), `tests/test_wp8_files.py`, `tests/test_economy_specs.py`.
- **How to use:** nothing for the loop: the kernel orders the pieces and asks for the stone dig itself (keep `follow`
  running without `--no-auto`). MATERIAL_SHORT in the brief says what the fort lacks (logs: autochop/woodcutters;
  stone: the bedrooms dig; ore, flux or economic stone: DF's stone use settings are the player's). A PROJECT_BLOCKED
  seal with `(no material ...)`: tell the player; the kernel retries it once a piece can be made. Year review: keep
  the drafted bedrooms dig and `pick` in trade.want.
- **Live check (Run 11):** after `git pull` and `dfhack-run dfllm reload`: within a game day `<save>/kern.log` shows
  `order N ConstructDoor x1: ... re-entered in wood` or `order dfllm:piece_door x1 (door for a planned building)`
  (work orders screen: a wooden or stone door order), the door at 128,121,143 gets built and `dfllm cmd inspect
  '{"what":"refuge"}'` shows Kern+/Tiefe+ `sep` 1. If the old seal project stays `build_lost` with its retries spent:
  `dfllm cmd bp.cancel '{"proj":"<id>"}'`, then `dfllm cmd bp.place tpl=seal site=S1 at=last` again. `dfllm cmd inspect
  '{"what":"workload"}'` shows `stone` {free, need}, `picks` {have, want, route} and `short`; `dfllm events --type
  MATERIAL_SHORT` names what nothing can make; with the stone short and the miners idle `dfllm events --type
  PROJECT_REQUEST` shows `bedrooms ... why rock` and cli.log follow's placement; `dfllm status` stock and `dfllm plan
  propose` show the stone dig and `pick` in trade.want. Watch: whether DF's cancel text for a stone door names rock,
  stone or a boulder (else the cancel path stays the old one), and whether `buildingplan set logs true` is accepted.
## Food in Run 11: the real `no cook` cause, a fishery for raw fish, the fishing zone on safe water, `food_low` names the blockers (2026-10-16; offline, live-untested)
- **Why (Run 11, Kilrudrabed site98, y432 winter, pop 54):** food 24 days and falling, no meat or fish, no farm soil,
  both kitchens without a job, ORDER_STUCK `PrepareMeal ... no cook` (8 times), nobody fished: the Fisherdwarves detail
  waits for a fishing zone and the kernel only read zones. In y433 the session found 883-4532 raw fish (FISH_RAW) and no
  fishery (food had fallen to 5 days); economy's PrepareRawFish order needs one and no template built it.
- **What `no cook` meant:** not DF's text and not a missing cook: economy's order check names a missing input key as
  `no <key>`, and PrepareMeal's key is `cook` (the census' cook ingredients). The worker check would have said
  `no worker COOK`. The census had no ingredient: raw fish are no ingredient before a fishery cleans them, plump helmets
  are banned (Gordon's rule), and food-class items of a material with neither `EDIBLE_RAW` nor `EDIBLE_COOKED` (leaves,
  flowers) are no food at all. Best evidence: the label code (`ctx.has('cook')`) and the session's finding of raw fish
  without a fishery.
- **Census:** `cook_in` = cook ingredients as a kitchen sees them (non-meal food of an `EDIBLE_COOKED` material not on
  the Cook ban: `dfhack.kitchen.findExclusion`, a growth with its growth index or -1, or the config ban), `cook_ban`
  (`cook_ban_g` growths), `food_inedible` (top materials kept), `food_far` (another walk group). The meal order and the
  order check use `cook_in`. ORDER_STUCK now says e.g. `no cook ingredient (883 raw fish need a fishery, 1566 inedible
  (OAK:LEAF), 11 cook-banned)` (`why` up to 120 chars); PrepareRawFish without a fishery says `no Fishery`.
- **Fishery:** raw fish (>= 5) or fishers at work and no fishery: PROJECT_REQUEST `workshops why=fishery` (every 14
  days at most); `dfllm follow` places a workshops project with only the fishery (`p.add Fishery`, every moodable type
  skipped) at prio 1. The workshops template takes `add=Fishery` (quickfort `wh`); fortcore stage 1 builds a fishery
  (new forts).
- **Fishing zone (fair play: the zones screen, revealed tiles only):** while fishers are wanted (food below 90 days, the
  pre-alarm or a famine), no fishing zone stands and the fort is in PEACE/RECOVERY, at most weekly: economy reads
  revealed water around the citizens' median (48 tiles; the fortcore surface and the level below, the citizens' levels
  and the level below each, at most 6) through `snapshot.liquids` (sliced, 1500 tiles a frame), depth >= 2, never cavern
  water (caverns stay sealed) or ice (winter), with a standable bank on the citizens' walk group (same level, or one up
  over open space or a brook top), never on the attack path (Z1/Z2, killboxes), a roofed bank first, then the nearest;
  `act.fish_zone` paints a 3x3 `dfllm-fish` zone (quickfort zone key `f`) over the water and, with the bank above, over
  that level too. None: `no safe fishing water (n frozen, n cavern, n shallow, n no bank on the walk group, n on the
  attack path)` in kern.log and the food decisions. `snapshot.liquids` leaves ice (tiletype material FROZEN_LIQUID) out
  and lists it apart with `ice`; `snapshot.tile` says `ice`.
- **Decisions:** `food_low` (below 30 days, class A) and `famine` name the numbers (food days, citizens, meals), the
  blockers (`block`: fishery, kitchen, cook, fish_zone, hunt, farms, butcher) and the options (`opts`; always
  `trade.want food`, butcher, gather, `popcap.lower`). `food_low` follows util/cadence (BUG-008): once at once, again
  only with a new blocker or below 20 days, after max(7 days, 10 min). The famine text no longer claims a missing
  fishery on the first run of a day (the facts are read before the decisions).
- **Hunting and the kitchen:** the famine hunters (2, with crossbows and free bolts, PEACE/RECOVERY) hunt from the
  food_low pre-alarm on; cookable growths on a kitchen ban are let go once per episode (`ban-cooking fruit --unban`;
  plump helmets are no growth and stay banned, D-09).
- Contracts: act `fish_zone` (economy), `snapshot.liquids(..., ice)`, `snapshot.tile` `ice`, census fields,
  DECISION_NEEDED opt `food`, `block`, `opts`; config `economy.fishing`. Docs: RULES §7 DECISION_NEEDED, §10 Labor and
  Food; DESIGN §5.5/§5.11; CONTRACTS §5, §6.3, §7, appendix.
- Tests: `tests/lua/test_economy_fishing.lua` (new: census, ORDER_STUCK causes, fishery request, the zone on safe
  water, no safe water and the decision, no search outside PEACE/with a zone/with food, the unban),
  `tests/lua/test_snapshot.lua` (ice), `tests/lua/test_act_supply.lua` (fish_zone), `tests/lua/test_economy_food.lua`
  (cadence), `tests/lua/test_economy.lua`, `tests/lua/test_economy_chains.lua` (pre-alarm hunters),
  `tests/test_cli_wake.py` (follow places the fishery), `tests/bp` goldens (fortcore fishery).
- **How to use / what to do now by hand:** nothing new to type: after `git pull` and `dfhack-run dfllm reload` the
  kernel paints the fishing zone, asks for the fishery and names the blockers. Until then (closed verb set): a fishery
  with `dfllm cmd bp.place '{"tpl":"workshops","site":"S1","p":{"add":"Fishery"}}'` (live after `git pull`; cmd.place
  skips the moodable shops the fort has), a fishing zone by hand in the zones screen (the player; no inbox verb paints
  zones), `trade.want food`/`meat`/`fish` for the next caravan, `popcap.lower`.
- **Live check (Run 11):** after the reload, within a game day with food below 90 days in PEACE: kern.log `fishing:
  zone dfllm-fish at x,y,z (...)` or `fishing: no safe fishing water (...)` (winter: `n frozen`); in game the zones
  screen shows a Fishing zone `dfllm-fish` on the water, the Fisherdwarves detail gets 1-3 members the next day. With
  raw fish and no fishery: PROJECT_REQUEST `workshops why=fishery` and a workshops project with one `wh` shop (cli.log
  `auto`). ORDER_STUCK for PrepareMeal names `no cook ingredient (...)` instead of `no cook`; `dfllm brief` OPEN
  food_low shows `food N d (54 cit, M meals): ...; ... Also: trade.want food, butcher, gather, popcap.lower`. Check the
  fishers stand on the bank and fish (job Fish), and that raw fish turn into prepared fish at the fishery.
## Melee squads refilled in a siege from healthy civilians in the core, never from the refuge (Run 11 siege 3, 2026-10-16; offline, live-untested)
- **Why (Run 11, Kilrudrabed, siege 3 of y432/433):** 25 dead (pop 54 -> 29, soldiers 10 -> 5), O1 destroyed; squads A and B
  emptied (deaths) and were never refilled, only C (5) remained. military's upkeep refilled only to the population target
  (it shrinks with the deaths, and the tools-first rule takes melee out entirely below 3 axes or picks) and from anybody,
  the refuge included.
- **military:** in SIEGE/BREACH a melee squad below half its target is refilled (act.squad_add, the squads screen) with
  healthy adults (no wound, awake, thirst < 25,000, hunger < 50,000) who stand in Kern+ and not in the refuge; tool-detail
  members and tool-labor holders come last (sole key-labor holders, nobles, moods never); the first melee squad's target is
  at least `HOLD_MIN` (5: the core stations) then, ignoring the shrunk target and the tools-first rule; no top-up at or
  above half; the leader of an emptied squad comes from the same list. kern.log `military: SIEGE refill: squad A 0 -> 5
  of 5 with healthy civilians from the core: <ids>`, or at most every 2,400 ticks `military: SIEGE: squad A 1 of 5 and no
  healthy civilian in the core to refill it (in the refuge N, outside the core N, hurt N, ...)`. PEACE unchanged (its
  release rules take the extra soldiers back).
- Docs: DESIGN §5.3, DOCTRINE, RULES §10, bugs/BUG-032 part 3. No event, verb or state field changed.
- Tests: `tests/lua/test_military_refill.lua` (new; fail on 94446e8 except the PEACE case). The intake and station test
  worlds staff their squads in PEACE first.
- **Live check:** in the next siege with losses: kern.log `military: SIEGE refill: squad A ...`, the squads screen shows A
  back at 5; no citizen leaves Tiefe+ to join; `dfllm status` soldiers back up.

## Squad stations never on or next to a bridge, a squad that holds a raise moves at once, the deep defense's lever pulls reach the refuge (BUG-032, 2026-10-16; offline, live-untested)
- **Why (Run 11, Kilrudrabed site98, y432 spring: a cave dragon siege and a snatcher, then BREACH, 0 deaths so far):**
  `GATE_FAIL B2: 'not up after 908 ticks'` (blocked): squad 104 stationed at 115,116,142, soldier 27836 held the raise
  (BUG-027's occupancy rule, correct). The station is the manifest's `stations.b2` (fortcore stage 3, local (1, 44, ze),
  one tile behind B2's footprint), taken by BREACH's posture B2_HOLD; gate's text says "stationed on the bridge" for a
  station on or next to the footprint. y432 winter d64: `GATE_FAIL O1 'no_worker'` in the deep defense, lever 18664 pulled
  again and again while every civilian stood confined in Tiefe+; by hand the pull was taken at once.
- **Stations clear of the bridges (military, new library `lua/dfllm/stations.lua`):** every posture names a chain of
  stations (B2_HOLD: b2, then core, the core level's centre `z4`, melee; READY_IN/STATION_B1 the same while B2 is up, else
  melee, b2, ...; CORE: core, b2, z4, melee; READY_STATION: [gallery,] melee, then b2, core, z4; INTAKE: [gallery,] field;
  the extra entries only after an earlier one failed). The first one that lies more than gate's MARGIN (1) +
  `stations.spread` (config/reflex.json, new, default 1: DF stands a squad on the tiles around its station point) tiles
  from every manifest bridge footprint on its level is taken; else it moves to the nearest revealed plain floor
  (snapshot.tile `.`, no building, off the stairs, within 8 tiles; a hidden tile never counts) on the inner side of the
  footprints that hold it (the deepest manifest zone around the footprint: O1 -> Z1, B1 -> Z3, B2 -> Z4; else the
  station's side, else away from `edge`); else the next of the chain. siege's deep-defense core station
  (`military.station_for`) and the sortie's gathering point (`military.safe_pos`) use the same rule. STATION_MOVED (B,
  new) and kern.log name the old and the new station, once per station and outcome.
- **A squad that holds a raise moves (siege -> military.restation):** each siege pass reads `gate.holds()` (new: the bridges
  whose pull waits for units, and who); a soldier holding a raise who stands at his squad's station (within spread + 1
  tiles of its station order) gets his squad a station clear of that footprint at once (the squads screen's move order):
  moved on the bridge's inner side far enough that the crowd stays out of the ring, else the posture's chain, core, b2,
  z4. Kept for the posture; a player's own squad gets the move order directly; kill orders and sortie holds are left
  alone; a soldier only passing over the footprint is not moved (the raise waits, BUG-027). The forced raise
  (`gate.force_near`) is unchanged. STATION_MOVED `hold` (or `none`).
- **fortcore:** `stations.melee` (0, 38, ze), the gatehouse centre (was (0, 36), two tiles from B1); `stations.b2`
  (-2, 45, zc), the core hub west of the civilians' stair (was (1, 44, ze) on the Z4 landing: B2's margin row, its lever
  room and the civilians' stair head); `core` unchanged. New placements only; a live manifest keeps its values and the
  kernel moves them. **Validator:** `station_bridge` (error) for a station on a bridge footprint or within 2 tiles of one.
- **gate:** the GATE/GATE_FAIL text says `stationed on the bridge` (on it), `stationed next to the bridge`, `stationed K
  tiles from the bridge` (the soldier stands at his station) or `on its way to its station`. Lever pulls with the
  civilians in the refuge: the lever order's first class is the burrows of the sounding alert (BREACH: the refuge, as
  before; was Kern+ in every other mode, so the deep defense pulled Kern+ levers nobody confined could take while O1's
  refuge lever kept `Hebel+` off the list); a pull waiting without a worker on a lever outside the alert's burrows moves
  at once to a usable one inside; `Hebel+` is listed also once every lever inside failed this epoch; wherever the alert
  confines to the refuge (BREACH, the deep defense, a lockdown that took Tiefe+) `Hebel+` follows breach_safe.
- Contracts: event STATION_MOVED (schema, contract.lua, CONTRACTS §12 and the appendix); `gate.margin`, `gate.holds`,
  `military.restation`, `station_for`, `safe_pos`, the posture chains, the lever order (§7); config `stations.spread`
  (§9.18, `python -m dfpilot.lint --config`); manifest stations rule (§11). RULES §7 GATE_FORCED row, §10 Military;
  DESIGN §5.3; DOCTRINE; bugs/BUG-032.
- Tests: `tests/lua/test_stations.lua` (new: the library rules; Run 11 replay: BREACH with b2 one tile behind B2 -> every
  squad at the relocated tile, B2 up, no GATE_FAIL; a hidden tile skipped; no floor -> core; a player's station next to
  B2 and a player's own squad re-stationed at once; a passer-by not moved), `tests/lua/test_gate_footprint.lua` (deep
  defense: Hebel+ while the pulls are pending, a confined civilian pulls; the refuge lever first; no Hebel+ with a
  hostile near the levers), `tests/bp/test_bp_stations.py` (new: fortcore stations in every rotation and stage, the
  validator), `tests/test_alarm.py` (stations.spread). The shared test world's b2 moved from 51,62 to 51,63.
- **How to use:** nothing for the normal loop. STATION_MOVED in the brief says where a squad now stands and why; a
  GATE_FAIL `blocked` that names a soldier "on its way" is a passer-by (wait); one at his station should not repeat.
- **Live check (Run 11):** after `git pull` and `dfhack-run dfllm reload`: `dfllm cmd inspect '{"what":"manifest"}'`
  shows `stations.b2` 115,116,142 (the manifest path, bug question 4). At the next SIEGE/BREACH (ALERT for melee):
  `dfllm events --type STATION_MOVED` and kern.log `military: station b2 115,116,142 lies 1 tile from bridge B2
  (clearance 2: gate margin 1 + spread 1): moved to ...`; the squads screen shows the new station; with every squad on
  the landing a `STATION_MOVED hold` (`squad 104 (A) holds the raise of B2: ... re-stationed at ...`) and B2 up within the
  lever latency; no `GATE_FAIL B2 ... blocked` naming a soldier at his station. In the next deep defense or BREACH:
  `dfllm events --type LEVER` shows the first O1 pull on a lever inside the alert's burrows (the refuge lever); no
  `GATE_FAIL O1 no_worker` while the civilians stand in Tiefe+. If soldiers spread wider than one tile around their
  station in 53.16 (repeated STATION_MOVED hold), raise `stations.spread` (0-5) in config/reflex.json.

## `seal at=last` takes the current leaks once each, plants and doors handled; `seal at=refuge` hatches the refuge stair; the refuge comes first from the fort's start (2026-10-16; offline, live-untested)
- **Why (Run 11, Kilrudrabed y429, pop 54):** `bp.place tpl=seal at=all|last` gave the same door 125,103,144 on every
  repetition (its seal was pending, then the entrance check reused an old answer) and never the new leaks: 188,103,144
  floor, 124,81,138 'open route without a roofed tile', shrubs/saplings at 188,88,144 and 177,99,144 (no door stands on
  a plant). REFUGE_FAIL `Kern+: open to 1 entrance 127,121,143 Door (62 steps)` stood while the plans went on with P1
  work; the refuge rule of `plan check`/`propose` started at P3.
- **`seal at=last|all` (`cmd.current_openings`, `cmd.seal_openings`):** the openings come from the newest SEAL_LEAK
  (unless a newer SEAL check read the fort sealed; a wall, since walk groups pass doors), the entrance check (newest
  SIEGE_UNREADY `ents`, else `ready.ents`; BUG-031 lists the doorless tiles beside a door there) and a current
  REFUGE_FAIL's `fix` as given (else its `open`; while `alert.ok` 0 or `alert.ref.sep` 0), one per tile. Left out, like
  `at=audit` already did: openings a seal project builds (not done) or built (done, unless a snapshot taken after it
  shows the piece gone). At most 6 per seal; the next `at=last` takes the rest. One `seal:note` line per opening left
  out or moved (cli.log, and `  seal note:` on stdout of `dfllm cmd`).
- **Plants and doors (fair play: player designations only, never DFHack `plant remove`):** a shrub gets quickfort's
  gather-plants designation (`#dig p`, stage `seal.clear`) and its piece after it (stage `seal.plant`); a tree tile
  (branch, trunk_branch, twig) the chop designation (`t`, no piece: the felled tree takes the branches). A sapling is no
  tree yet (quickfort's `t` marks tree tiles only; no player designation removes it), so like a door/hatch the route
  passes beside, or another building on the opening, it gets the neighbouring tile that closes the same route
  (`bp.topo.SealGeo.neighbour`, written `N floor for=O:kind`). An open route without a roofed tile gets a wall on the
  first of its first 8 floor/ramp tiles to the snapshot border that cuts the citizen's side (with >= 12 roofed tiles,
  the fort) from the border (`SealGeo.route`; a citizen in the open field gets none). A door that closes its doorway on
  the snapshot (a SEAL_LEAK through a door) is left out with a note: a wall there would close the fort's own way.
- **`seal at=refuge` (BUG-031 open point):** fortcore's Tiefe+ hangs below Kern+ on the civilians' stair without a door
  or hatch, so whatever reaches Kern+ reaches it. `at=refuge` puts a hatch on that stair one level above the refuge
  (`cmd.refuge_head`: manifest refuge anchor + `stairs.civ`; seal's refuge flood counts a hatch as a closer, walkers
  pass it) and adds the current REFUGE_FAIL's `fix` tiles; `at=all` includes the stair head. Offline: with the hatch the
  core's landing no longer reaches the refuge anchor with doors and hatches closed.
- **Kernel (snapshot.lua, minimal):** snapshot marks `shrub` and `sapling` (plant tiles; the roofed ones first, then the
  open-sky ones up to 500; both always written). Without them (an older kernel) the entrance check's kinds stand.
- **`dfllm plan check`/`propose` (refuge gate, from the fort's start):** once the refuge burrow exists (`alert.ref.ex`),
  below P3 too: a plan that raises phase_target or adds builds is refused (ERROR) until the seal and the missing
  `refuge_beds` come no later than its first other new build (at P3+ the same ordering); a plan that adds nothing only
  warns. The seal: `{"tpl":"seal","site":"S1","p":{"at":"refuge"}}` while the stair head lacks its hatch
  (`fort.refuge.head_open`: only at=refuge/all or a seal naming the tile fixes that) or the refuge is open and
  `at=refuge` has tiles; else `at=last` (an opening reaches Tiefe+, or a current REFUGE_FAIL names open entrances). No
  build is asked that cannot be placed: `seal at=last` finding nothing to close (`seal_n` 0) and, below P3,
  `refuge_beds` without a site (no fortcore refuge room yet: `bed_site` false) are warnings. `plan propose` drafts the
  refuge pieces first in the current season (after the audit's seal) at every phase, one seal at most; fortcore stage 3
  for a missing refuge stays a P3+ draft.
- Wake hints: SEAL_LEAK points at `bp.place tpl=seal site=S1 at=last`, REFUGE_FAIL at `at=refuge`. Docs: RULES §7 (SIEGE_UNREADY,
  SEAL_LEAK, REFUGE_FAIL), §8 refuge gate; DESIGN §5.2 seal, §5.4 refuge gate; CONTRACTS §9.10 marks. No event, verb or
  state field changed (the CONTRACTS appendix is unchanged).
- Tests: `tests/bp/test_bp_seal_run11.py` (new: no second seal for a pending/built opening, SEAL_LEAK as a source with a
  wall, shrubs gathered and saplings closed beside, a door the route passes beside, an open route, six per seal, notes;
  the stair-head hatch on a built fortcore and the refuge it separates; REFUGE_FAIL `fix`; plan facts),
  `tests/bp/test_bp_seal.py`, `tests/test_cli_plan.py` (the refuge gate from the fort's start, the stair-head hatch,
  propose below P3, fort facts from REFUGE_FAIL), `tests/lua/test_snapshot.lua` (plant marks).
- **How to use:** `dfllm cmd bp.place tpl=seal site=S1 at=last` after SIEGE_UNREADY, SEAL_LEAK or REFUGE_FAIL (or the
  line's `seal at=...`), `at=refuge` once for the refuge stair's hatch; repeat it until it says `nothing to close` (each
  run takes up to 6 openings no seal covers yet). Read the `seal ...` and `seal note: ...` lines it prints. Year review:
  `dfllm plan propose` puts the seal and `refuge_beds` first; `dfllm plan check` says what is missing and where it must
  go.
- **Live check (Run 11):** after `git pull` and `dfhack-run dfllm reload`, `dfllm bp sites seal --fresh` (a snapshot
  with the plant marks), then `dfllm cmd bp.place tpl=seal site=S1 at=last`: the output names 188,103,144 (and the other
  current leaks), no `125,103,144` piece while its seal is pending (`seal note: 125,103,144: left out, seal project ...
  builds its piece`), `188,88,144 shrub: gather the shrub, then door at 188,88,144`, `177,99,144 sapling: door at
  <neighbour> (...)`, and for 124,81,138 a wall on the route's first cutting tile or a note that the citizen stood in
  the open. `dfllm cmd bp.place tpl=seal site=S1 at=refuge` names `<civ stair x,y>,<refuge z+1> stair_updown: hatch at
  ...`; once built, `dfllm cmd inspect '{"what":"refuge"}'` shows Tiefe+ `sep` 1 while Kern+ is still open. In game the
  herbalists gather the shrub (designations screen shows it) before the door is built. A second `at=last` right after
  must not repeat any tile. `dfllm plan propose y.json` on Kilrudrabed (P1/P2, Kern+ open, Tiefe+ short of beds, no
  hatch on the refuge stair) drafts `seal at=refuge` and `refuge_beds` (if `dfllm bp sites refuge_beds` lists a site) as
  the first builds of the current season; `dfllm plan check y.json` without them says `refuge: ... the refuge comes
  first (Run 11): adding builds (...) waits for it`.

## Glass for strange moods: raw and cut green glass from revealed sand (2026-10-16; offline, live-untested)
- **Why (Run 11, Kilrudrabed site98, y429):** no gem vein on the site (`explore` digs since y427), moods kept failing for
  gems, bars and leather, and every year the first unfulfilled mood dwarf died.
- **What glass can and cannot replace** (DF's mood filters, DFHack strangemood.cpp; `reserve.glass_ok`): raw glass
  (ROUGH of GLASS_GREEN/CLEAR/CRYSTAL) serves a glassmaker's base material and the extra "raw glass" (DF asks for it only
  once the fort has made that glass); cut glass (CutGlass at a jeweler's) serves the extra "cut gems" (SMALLGEM of any
  material). Glass never serves rough gems (ROUGH of an inorganic: a gem cutter's or setter's base, the extra rough gem),
  metal bars, blocks, leather or cloth. Only green glass is made (clear/crystal need pearlash or rock crystal), so a
  glassmaker who prefers clear or crystal glass still waits.
- **care:** `care.mood_wants` entries carry `glass` (`raw`/`cut`); MOOD_RISK names economy's route for gems and glass
  (`route gems: cut glass: no glass furnace (asked), no sand revealed, ..., raw 0/9, cut 6; trade.want gem`), the
  rough-gem route (`rough gems: mine a gem vein or trade.want gem (glass is no rough gem)`) otherwise; the mood's
  DECISION_NEEDED hint adds cut glass for a cut-gem need.
- **economy:** census `gems` no longer counts raw glass; new `glass` (raw glass), `gems_glass` (cut glass), `sand` (bags of
  sand), `bags` (empty bags); key `glass` (no alias of gems). The glass chain (`M.glass_plan`, config `economy.glass`)
  runs while a mood wants raw glass or cut gems, or with no natural gem in the fort while a mood missed gems/glass within
  `leather.memory_days`, or from `glass.from_phase` (P3) while the gems are below the mood reserve's gems target
  (`reserve.targets.gems`, 5): cut glass up to that target plus `glass.raw` (3) raw glass. Steps: no glass furnace (or
  no jeweler's while cut glass is wanted) -> PROJECT_REQUEST workshops why=glass (follow places the missing moodable
  shops); no sand zone -> one 1x1 `dfllm-sand` zone on a revealed sand floor on the citizens' walk group, roofed first;
  no empty bag -> ConstructBag from spare cloth or leather; fuel -> MakeCharcoal (not with a magma glass furnace);
  orders CollectSand, MakeRawGlass GLASS_GREEN (bag of sand + fuel conditions), CutGlass GLASS_GREEN. Blockers the kernel
  cannot fix (no sand revealed, no bags, no fuel) -> GLASS_BLOCKED (B) once per set (util/cadence, `glass.report_days`).
- **snapshot:** exports mark revealed soil floors of a sand layer (`marks.sand`; layer material SOIL_SAND via DFHack
  tile-material); new hook `snapshot.sand()`; economy asks for one export when none ran this boot.
- **act:** `sand_zone(pos)` (economy): the zones screen's Sand zone, quickfort zone key `s`. **orderlib:** CollectSand,
  MakeRawGlass, CutGlass, ConstructBag (workshops, inputs `sand`/`bags`/`glass`; CollectSand is hauling labor).
- Contracts: event GLASS_BLOCKED (schema, contract.lua, appendix), act `sand_zone`, hook `snapshot.sand`,
  `economy.route(key, via)`, `care.mood_wants` `glass`, census fields, PROJECT_REQUEST why=glass, marks `sand`. RULES §7
  MOOD_RISK row, §10 moods; config `economy.glass` (baseline.json).
- Tests: `tests/lua/test_economy_glass.lua` (new: census, the whole chain, blockers once, no chain with natural gems,
  magma and the boot export), `test_reserve.lua` (glass_ok), `test_care_moods.lua` (MOOD_RISK routes, mood_wants glass),
  `test_snapshot.lua` (sand marks, hook), `test_act_supply.lua` (sand_zone), `tests/test_economy_specs.py` (glass jobs on a
  DF install).
- **How to use:** nothing for the normal loop. A MOOD_RISK line names the glass route and what blocks it; GLASS_BLOCKED in
  the brief says what the player must supply (dig into or look at a sand layer, cloth for bags, a wood furnace).
- **Live check:** after `git pull` and `dfhack-run dfllm reload`, in Kilrudrabed: `dfllm audit` (an export); the newest
  snapshot under `<save>/snap/` has `marks.sand` if a revealed sand floor lies in its box; within a game day
  `<save>/kern.log` shows `glass: sand collection zone dfllm-sand at x,y,z` and the zones screen lists a Sand zone there;
  `dfllm cmd inspect '{"what":"orders"}'` (or the work orders screen) shows `dfllm:bag`/`dfllm:glass_fuel`, then
  `dfllm:sand` (Collect sand), `dfllm:glass` (Make raw green glass) and `dfllm:cutglass` (Cut green glass); without sand
  `dfllm events --type GLASS_BLOCKED` names `no_sand`. If a CollectSand order never gets a job ("Needs ..." cancels or
  ORDER_STUCK), note it in the repo: the order may need a glass furnace link in 53.16.
## Run 11: a usable refuge at every invasion, the alert lets thirsty citizens out, HOSPITAL_DRY names the cistern, BUG-031 (2026-10-16; offline, live-untested)
- **Why (Run 11, Kilrudrabed y429, pop 54):** every invasion said `REFUGE_FAIL Kern+: open to 1 entrance 127,121,143 Door (62 steps)` and
  `no confinement, citizens flee` although fortcore stage 3 had built Tiefe+; single thirsty citizens got `STRANDED ... no rescue (the outside
  is not verified sealed)` while the alert held them in Tiefe+ without drink; HOSPITAL_DRY said `... a cistern` every month beside a cistern.
- **Entrances beside a door (seal):** an opening is all the touching inside tiles next to the outside, and a door on one of them (the seal
  template puts it on the first) leaves the others open. The exposure flood now keeps one label per start tile: REFUGE_FAIL and `inspect
  refuge` name the tiles the flood entered by (`open to 1 entrance 25,10,9 floor +1 beside door 25,9,9`, `(door not built)` for a placed
  door nobody built), `d.fix` / `fix` = the seal template's `at` (`25,10,9 floor;25,11,9 floor`), the message adds `close it: seal at=...`,
  `hint` the `bp.place` command. `seal.entrance_doors().open` lists these tiles (`door` 1, `note`), so the lockdown text, SIEGE_UNREADY `ents`
  and `seal at=last` close them.
- **Breach days per episode (seal):** a lockdown in PEACE that took the dead end opened the 7 days without counts for good, and every later
  invasion found them spent (flee). They end now once neither a gated mode nor a lockdown holds; a refuge with its own drink/well and food is
  not bound to them; a spent window is named in the flee text. The refuge is a SIEGE/SOFT-level candidate after `Innen+` (a stocked refuge
  holds a siege when an opening reaches Kern+).
- **Thirst in the alert's burrow (siege + seal):** citizens (soldiers and patients excluded) over thirst/hunger 30,000 in a burrow of the
  sounding civ alert, with the drink/food on their walk group: `seal.dry` marks the burrow when its audit finds none there, every level
  refuses it for the episode, and the alert moves to a burrow that has it or goes off (also in a lockdown). STRANDED (A) phase `relax`
  (`burrow`), REFUGE_FAIL `dry`. `refused ... the outside is not verified sealed` names seal's leak (`leak at x,y,z Door closed`).
- **Hospital water (water + snapshot):** the nearest cistern room of the manifest is named with what its well lacks (`its well 77 stands
  over 0/7 (dry) at x,y,z`, no well, not built, `47 tiles from the hospital (> 30)`) in `why`, `d.cistern` and the recipe; no cistern
  PROJECT_REQUEST while one stands within 30 tiles. Cavern water (`snapshot.liquids` 4th value: a revealed cavern tile) is listed in
  `inspect water_sources` (`cavern` 1) but never offered (caverns stay sealed); no cavern access was added.
- Contracts: REFUGE_FAIL `fix`, `dry`; STRANDED phase `relax`, `burrow`; HOSPITAL_DRY `cistern` (schema, CONTRACTS appendix and rows);
  public `seal.dry`, `seal.groups().leak`, `seal.entrance_doors` `open` gaps, `snapshot.liquids` cavern flag; RULES §7 rows STRANDED,
  HOSPITAL_DRY, REFUGE_FAIL. Bug file BUG-031.
- Tests: `tests/lua/test_seal_refuge.lua`, `tests/lua/test_stranded.lua`, `tests/lua/test_water_fr.lua` (all new cases fail on 99f69f2).
- **How to use:** nothing new for the loop. A REFUGE_FAIL with `close it: seal at=...` is placed as `dfllm cmd bp.place
  '{"tpl":"seal","site":"S1","p":{"at":"<fix>"}}'` (or `at=last` once SIEGE_UNREADY named them); STRANDED `relax` needs no action.
- **Live check:** after `git pull` and `dfhack-run dfllm reload`, `dfllm cmd inspect '{"what":"refuge"}'`: Kern+ `open` names the tiles beside
  127,121,143 (not the door), `fix` and `hint` give the seal; `dfllm cmd inspect '{"what":"entrances"}'` counts them as openings without a door.
  Place the seal; once built, `inspect refuge` shows Kern+ and Tiefe+ `sep` 1 and the choice SIEGE `Kern+`. In the next lockdown REFUGE_FAIL
  (if any) names a burrow, not `citizens flee`, and `inspect refuge` shows `bsince` empty again once the lockdown has ended (kern.log `episode
  over`). The next HOSPITAL_DRY names the cistern and the depth under its well; `inspect water_sources` shows the z127 lake with `cavern` 1
  and its `d`.
## A cavern breach is named and plugged: BREACH_STOP `cavern_lake`, the `plug` project, CAVERN_PLUG (2026-10-16; offline, live-untested)
- **Why (Run 11, Kilrudrabed site98):** the explore shaft 136,73 (z137 down) broke into a cavern lake on z127 (1146
  visible water tiles there, 662 on z126). DF's damp report stopped it and BREACH_STOP said `damp (report)`, so nothing
  showed that the aborted shaft was now an open way from the cavern into the core (Run 3 fell to forgotten beasts
  through an opened shaft; doors and hatches do not hold them).
- **Breach kinds (runner):** a damp/water/cavern stop is held against the revealed tiles at the breach
  (`runner.opened`): >= `lake_min` (30) revealed water tiles outside the project's own dug tiles connected to it within
  `lake_r` (12) on its level +- 1, with a revealed cavern tile (`snapshot.tile` new `cav` = `designation.feature_global`)
  beside it or in that water (or none of that water under the open sky) = `cavern_lake`; a revealed cavern tile
  beside it = `cavern`; a big body on the surface = `water`; else it stays `damp` (aquifer seepage, also 7/7 in the own
  shaft). It only raises a stop, never lowers it.
  A FEATURE_DISCOVERY of underground water (lake, river) is `cavern_lake` (was `water`). BREACH_STOP gains `src`,
  `was`, `n`; msg `e1: cavern lake (report, not damp: 552 water tiles in reach), digging stopped`. A project stopped as
  damp/water/cavern without a plug looks again once a day (src `recheck`): its stored breach tile, its shaft bottom and
  its dug tiles that hold water (the live Run 11 shaft, stopped as damp by the old code, is found this way).
  `damp_dig`/`seep_max` (light aquifer re-designation) are unchanged; with `damp_dig` a damp report beside a cavern
  stops the dig all the same.
- **Plug (runner, at once):** an explore shaft open to a cavern gets a `plug` project (prio 1, class defense, every mode,
  never stopped by a damp report or water): its top stair tile and the one below each get a channel (`h`: walls cannot
  stand on stairs, quickfort `is_valid_tile_construction`) and then a constructed wall (`Cw`, buildingplan waits for
  the material); the lower one first (it is reached only through the upper one), given up when a step of it waits
  `plug_wait` (a day) or quickfort refuses it; the top one is channelled and walled from the core floor beside it.
  **CAVERN_PLUG (A, new):** `queued` names the shaft (`x,y zTOP-zBOT`), the breach and the walls; `done` once a
  constructed wall stands on the shaft top (the plug's or one built by hand); `failed` (quickfort refused the top,
  the plug was cancelled, blocked or ended without the wall); `none` for other templates (their stairs may be the
  fort's own: wall the way in by hand). Record m.runner `cav` (outlives the explore project).
- **Readiness:** `caverns` stays in `ready.fail` (R0) while `runner.cavern_open()` lists a shaft whose top wall does not
  stand, also when the explore was cancelled and the shaft left the audit box; CAVERN_PLUG triggers a re-evaluation.
- **Threat:** a hostile within `SHAFT_R` (30) tiles of an open shaft, from 5 levels below its bottom up to its top,
  counts although it stands below the fort's z band (a cavern creature at the opening raises ALERT); once plugged the
  sealed cavern is quiet again.
- Contracts: event CAVERN_PLUG (A, RULES §7 row), BREACH_STOP fields/whys, `snapshot.tile` `cav`, public
  `runner.cavern_open`/`runner.opened` (schema, contract.lua, CONTRACTS §7/§12 and appendix). RULES §7/§8/§10, DESIGN
  §5 explore and §11.1, DOCTRINE §1; wake hint for CAVERN_PLUG.
- Tests: `tests/lua/test_runner_cavern.lua` (new: lake vs damp, the plug's four steps, the lower wall given up,
  quickfort refusing the top, seepage stays damp, the recheck of an old damp stop, an open cavern, a room breach =
  none, an underground lake without the cavern flag, the plug in SIEGE and against hazards, damp_dig unchanged),
  `test_runner.lua` (FEATURE_DISCOVERY water), `test_readiness.lua`, `test_siege_sense.lua` (threat near the shaft),
  `test_snapshot.lua` (`cav`), `tests/test_schema.py` (the new event).
- **How to use:** nothing to send: the kernel names the breach and plugs the shaft itself. On a CAVERN_PLUG wake:
  `queued` -> tell the player, `dfllm status` shows the `pl<tick>` project, then `dfllm cmd bp.cancel
  '{"proj":"<explore id>"}'` (no undo); `failed`/`none` -> tell the player at once: a constructed wall on the named
  tile by hand (a stair: channel it first). Readiness stays R0 `caverns` until the top wall stands.
- **Live check (Run 11 site98):** after `git pull` and `dfhack-run dfllm reload`, within one runner run the explore
  blocked `breach:damp` shows `breach:cavern_lake` (`dfllm events --type BREACH_STOP`: src `recheck`, was `damp`) and
  CAVERN_PLUG `queued` names the shaft 136,73 z137-127 (or -126) and walls 136,73,136 + 136,73,137; `dfllm status`
  `ready.fail` holds `caverns`. Watch in DF: (1) whether a miner channels 136,73,136 from the stair above (if not, the
  log says `lower wall (p1.dig) given up` after a day); (2) whether quickfort designates the channel on the `j` at
  z137 and a builder walls the open space from the core floor (`inspect projects`; if refused: CAVERN_PLUG `failed`,
  wall it by hand); (3) CAVERN_PLUG `done` and `caverns` gone from `ready.fail` (the audit's own cavern check must
  pass too); (4) `inspect persist` key `m.runner` `cav` holds the record. If the lake tiles carry no `cav`
  (feature_global), the kind is still `cavern_lake` as long as none of them lies under the open sky.

## No P3+ without a separated refuge with beds; template `refuge_beds` (2026-10-16; offline, live-untested)
- **Why (Run 10, post-mortem root cause 5):** Tiefe+ was never usable (beds 8 < 27, open to the entrance 95,127,123,
  58 steps), Kern+ lay on the attack path, at pop 110 there was no safe room; no template could add beds to the refuge
  (every room stays off the refuge level).
- **Kernel (seal):** state `alert.ref` = `{ex, sep, beds, need}`: the refuge burrow exists, is separated (1; 0 an
  opening reaches it without door/hatch/bridge; -1 not known yet), its beds, and the beds wanted (ceil(citizens x
  `refuge.bed_pct` %), config/reflex.json, default 25).
- **`dfllm plan check`:** ERROR for phase_target P3+ while the refuge is missing, open or short of beds, unless the
  plan's new builds (or projects under way) fix it: no refuge -> `{"tpl":"fortcore","site":"same","p":{"stage":3}}`;
  an opening -> a seal (`{"tpl":"seal","site":"S1","p":{"at":"last"}}`); beds short -> `{"tpl":"refuge_beds",
  "site":"S1","p":{"n":N}}` (the `n` add up to the shortfall). Separation unknown, or a state without `alert.ref`,
  warns. **`dfllm plan propose`** drafts these first (right after the audit's seal).
- **Template `refuge_beds`** (`dfpilot/bp/rooms.py`, params `n` 2-30, `burrow` Tiefe+): a dormitory dug from a floor
  tile of the fortcore refuge room into the rock (the footprint and its wall ring rock or unknown: no new way in), a
  door, beds beside a centre aisle, a dormitory zone, in the refuge burrow; never in Z4, private. `bp sites
  refuge_beds` lists the refuge-room anchors.
- Contracts: state `alert.ref` (schema, contract.lua, CONTRACTS appendix and §9.3 row). RULES §7 REFUGE_FAIL, §8 refuge
  gate, §11 P5 note; DESIGN §5.4 refuge gate; README template list.
- Tests: `tests/bp/test_bp_refuge_beds.py` (new: sited in the refuge, audit ok and refuge separate after it is built,
  rejected beside an open tile, layout, needs the refuge), `tests/test_cli_plan.py` (gate, projects under way,
  propose), `tests/lua/test_seal_refuge.lua` (alert.ref); generic room tests keep refuge_beds out of the core checks.
- **How to use:** year review as usual: `dfllm plan propose` puts the refuge pieces first; `dfllm plan check` says what
  is missing. By hand: `dfllm bp sites refuge_beds`, `dfllm cmd bp.place '{"tpl":"refuge_beds","site":"S1",
  "p":{"n":20}}'`.
- **Live check:** after `git pull` and `dfhack-run dfllm reload`, `dfllm cmd inspect '{"what":"refuge"}'` (Tiefe+ `beds`,
  `sep`, `need.beds`) and the state's `alert.ref` agree; in a fort like Run 10 (Tiefe+ 8 beds, 110 citizens)
  `dfllm plan check` on a P4+ plan says `refuge: Tiefe+ has 8 beds < 28 ...` and `dfllm plan propose` drafts
  `refuge_beds` n=20 (plus the seal at=last while Tiefe+ is open); once built, `inspect refuge` shows the beds in
  Tiefe+ and `dfllm audit` stays without `refuge:` and `bypass` findings.

## The audit's bypass is walled before the fort grows: `seal at=audit` by follow, plan propose and plan check (2026-10-16; offline, live-untested)
- **Why (Run 10, post-mortem root cause 1):** `bypass: edge->Z3/Z4 avoids the trap hall (reaches 139,128,117)` stood
  in the audit for months, the plans raised the phase anyway and the 41 traps stayed unused. The findings now name
  the wall (`bypass: wall x,y,z floor -> X`), but building it still waited for someone to read it.
- **Readiness (kernel):** R0 as before; new state `ready.route` = the last audit's first route finding (bypass or
  refuge on the attack path, <= 60 chars); SIEGE_UNREADY names it with `(fix: seal at=audit)` (or `(no wall tile:
  inspect entrances)`), the ways-in list is shortened when the line would cut the trap count. `dfllm status` line 2:
  `audit route: bypass: wall ... | next: wall it: dfllm cmd bp.place tpl=seal site=S1 at=audit (or a plan build seal
  p.at=audit)`; the SIEGE_UNREADY wake line's `next:` is the seal command when its `afails` name a wall.
- **Automatic path (follow, auto mode):** on each AUDIT event in PEACE, the walls the newest audit names and no seal
  project builds yet are placed as `bp.place {"tpl":"seal","site":"S1","p":{"at":"audit"}}` (the follower's
  placement job, like tombs; `auto:seal` in cli.log, one `seal:piece` line per wall). Not with `--no-auto` (no
  automatic placements there), not in ALERT/SIEGE (the next monthly audit asks again).
- **`dfllm plan propose`** drafts that seal as the first new build (the current season; seasons[0] of next year's
  plan). **`dfllm plan check`**: ERROR when the plan raises phase_target above the current phase or adds builds while
  such a wall stands in no seal project, unless a new build due now is a seal with `at=audit` / `at=all` / the tiles;
  a seal in a later season is refused (`move the seal ...`). A route without a wall tile, or one a pending seal
  builds, is a warning.
- **`cmd.audit_routes`** (shared): routes, walls, `open` walls, `pending` {wall: seal project}; a seal done before an
  audit that still names its tile counts as gone. `seal at=audit` leaves pending walls out (never two seals per tile).
- Contracts: state `ready.route` (schema, contract.lua, CONTRACTS appendix). RULES §7 SIEGE_UNREADY row, §8 bypass
  gate; DESIGN §5.4.
- Tests: `tests/test_cli_plan.py` (gate, pending/done/no-wall, state fallback, propose, apply with the real seal),
  `tests/test_cli_wake.py` (follow places the seal once, PEACE only, not with --no-auto; wake hint),
  `tests/test_cli_status.py`, `tests/lua/test_readiness.lua`.
- **How to use:** nothing for the normal loop: keep `dfllm follow` (without `--no-auto`) running and the seal is placed
  after the next audit. By hand: `dfllm cmd bp.place tpl=seal site=S1 at=audit`. In a plan: `{"tpl":"seal","site":"S1",
  "p":{"at":"audit"}}` as the first build of the current season (`dfllm plan propose` writes it).
- **Live check:** after `git pull` and `dfhack-run dfllm reload`, `dfllm audit`; with a bypass `dfllm status` line 2
  shows `audit route: bypass: wall x,y,z ... | next: wall it ...`; within a few seconds follow logs `auto:seal` and
  `seal:piece` in `<save>/cli.log` and `dfllm events --type CMD` shows the bp.place; `dfllm plan propose` puts no second
  seal in (the pending one covers the tile) and `dfllm plan check` warns `seal project ... builds the wall`. Once the
  wall stands, `dfllm audit` shows no `bypass` (or the next route) and readiness can reach R1.
## Destroyed bridges and the deep defense against building destroyers, BUG-030 (2026-10-16; offline, live-untested)
- **Why (Run 10 fell, y421):** 58 goblins and 6 trolls destroyed O1, B1 and B2; the kernel kept their wants for nine days
  (GATE_FAIL `no_lever`, `STRANDED B1 raised although it cuts N citizens off` 40+ times with `buildings.other.BRIDGE`
  empty); the civilians stayed in Kern+ and the 19 recruits at the melee and gallery stations between O1 and B2.
- **Destroyed bridges (gate):** a manifest bridge gate saw complete on its footprint and that is gone now is destroyed:
  BRIDGE_DESTROYED (A, once), its want, pull and move record dropped, `gate.want` refuses it, no GATE_FAIL, state
  `bridges` `destroyed` (status `DESTROYED`), `inspect defense` `destroyed`, the audit snapshot shows the bare
  footprint; `gate.state` keeps `unknown` (readiness `bridge:B`) plus the destroyed tick; checked again once a day
  (`rebuilt`). siege: no raise hold or STRANDED for it, a lost O1/B1 in SIEGE is BREACH at once (why `destroyed`),
  RECOVERY counts it as lowered.
- **Deep defense (siege, SIEGE only):** building destroyers in sight (new `census.h.bd`, from the caste flag or
  `caste_raw.misc.buildingdestroyer`), an army > `stations.core_ratio` (3) x soldiers, or weak squads (worn <
  `stations.worn` 60, iron/steel < `stations.metal` 0 = off; `config/reflex.json` `stations`): civilians to the
  separated refuge at seal's BREACH level, every squad at the core station (new posture CORE: manifest `stations.core`,
  fortcore's core hub by the civilians' stair, else `stations.b2`), no kill orders, no
  intake wave (INTAKE refused `deep`); SIEGE_DEEP (A) names reasons and destroyers; state `wave.deep`, status `DEEP ...`.
- Contracts: events BRIDGE_DESTROYED, SIEGE_DEEP (A, RULES §7), BREACH why `destroyed`, GATE `rebuilt`, bridge state
  `destroyed`, `wave.deep`, posture CORE, manifest `stations.core` (fortcore stage 3), config `stations`, `gate.state`
  third value (CONTRACTS §19 BD). Docs: BUG-030, DESIGN §3/§4/
  §5.3, DOCTRINE §2 (plan B), RULES §7/§10.
- Tests: `tests/lua/test_stranded.lua` (B1 and B2 destroyed in a breach; O1 destroyed in SIEGE), `tests/lua/test_intake.lua`
  (trolls, army 30 vs 8 soldiers, weak squads), `tests/test_cli_status.py`, `tests/test_alarm.py`.
- **Live check:** `dfhack-run dfllm reload`; in the next siege with trolls `dfllm events --type SIEGE_DEEP` names them,
  `dfllm status` shows `DEEP destroyers` and `alert Tiefe+`, every squad's station is `stations.b2` (138,127,122; no `stations.core` in a Run 10 manifest); a bridge
  they destroy gives one BRIDGE_DESTROYED and `bridges ... DESTROYED`, then no STRANDED or GATE_FAIL naming it; with trolls
  in sight `inspect census` shows `h.bd` > 0 (if 0, the raws field has another name in 53.16: note it in BUG-030).
## Ore search and leather as plan goals, verified quicksave (2026-10-16; offline, live-untested)
- Live Run 10 (Handlelock): iron stayed at 8 bars for years, three caravans a year brought none, 20 soldiers wore 38-53 %;
  economy's explore route waited for 0 spare bars and never fired, and nothing consumed its request. A fey mood died for two
  leather (no tannery, no hunters). After a graphics crash `dfhack-run quicksave` wrote nothing (no error, empty output) and
  the restart loaded a state 30 game days older.
- **Ore (economy + plan):** the metal route is `explore` while no metal ore boulders lie in the fort and the soldiers' metal
  slots want more bars than it has (`gear.bars_short`) or the bars are below the mood stock; PROJECT_REQUEST explore carries
  `bars`/`short`, DECISION_NEEDED metal points at the plan. New state `stock.ore/bars/leather/metal/mood_miss` (economy).
  New template `explore` (`dfpilot/bp/mine.py`): a 1-wide stair shaft `depth` (12) levels down from the deepest public core
  floor with W/E/S side tunnels of `arm` (6) tiles every `every` (3) levels and at the bottom; the ranking never starts on or
  below the refuge level and never reaches a level in `p.avoid` (absolute z, e.g. known aquifer levels) or one with a
  revealed cavern/damp/warm mark; the runner's damp/warm/cavern stop applies as for every dig. `plan propose` drafts it as
  the first new build of every season from the current one (fitting `depth` 12/9/6/4/2 to the sites snapshot) and adds
  `bar:iron` to `trade.want`; `plan check` refuses a plan with neither explore nor a `bar:*` want while the ore goal holds
  (no ore and route explore, or worn < 80 %) and warns when only the trade want covers it.
- **Leather (economy + care + plan):** a standing floor of 2 leather (`reserve.leather`); classes a mood missed are kept a
  year (`leather.memory_days`); a missed leather with 0 in the fort hunts like an open need (through the no-game pause);
  without a tanner's shop while hides lie or a mood missed leather economy asks for the `workshops` project
  (PROJECT_REQUEST why=tannery, follow places it; every 14 days at most). MOOD_RISK names the route (`economy.route`, new
  `d.route`: `route leather: no tannery (asked), hunt: no bolts, butcher, trade.want leather`). `plan propose` puts
  `leather` first in `trade.want`, `plan check` warns without it. `dfllm status` shows `ore N bars N (explore) leather N
  moods missed ...`.
- **Quicksave:** new `dfllm save` (`dfpilot/save.py`): DFHack `quicksave` through dfhack-run, then up to 120 s of 1 s polls
  of DF's save folder: verified only when a fortress save folder (marker of this fort) holds a `world.sav` newer than the
  call and DF is done writing. Refused in SIEGE/BREACH/DRILL, without ACTIVE, within 600 s of a verified save or 120 s of
  a failed one. Every attempt -> `<save>/quicksave.json` (kind `quicksave`, CONTRACTS §9.19) and cli.log; a failure prints
  `QUICKSAVE_FAILED: ...` (exit 1), `dfllm status`/`brief` show `QUICKSAVE FAILED ... ago`, and `dfllm follow` wakes
  QUICKSAVE_FAILED (follow's own wake, RULES §7). `tools/run_watch.py` saves through it once a game year (at most 3
  attempts, `saved_year` only on a verified save). The hook still blocks a bare `dfhack-run quicksave` and names `dfllm save`.
- Contracts: state `stock.*` keys (schema + contract.lua), event d `MOOD_RISK.route`, `PROJECT_REQUEST.bars/short`, kind
  `quicksave`; config `economy.reserve.leather` 2, `economy.leather.request_days/memory_days`; CONTRACTS §8, §9.3, §9.19,
  §12, §15, DESIGN §5.5/§5.9, RULES §1.2, §3, §7, §10.
- Tests: `tests/lua/test_economy_chains.lua` (8 bars for 20 soldiers -> explore and state; a missed leather mood -> hunting
  through the pause, tannery requests, route), `tests/lua/test_care_moods.lua` (MOOD_RISK route),
  `tests/bp/test_bp_explore.py`, `tests/test_plan_supply.py`, `tests/test_save.py` (verified, the Run 10 empty case, another
  fort's save, a save in progress, refusals, follow wakes, run_watch, hook, status).
- **Live check / How to use:**
  - After the next load or `dfhack-run dfllm boot` (the new Lua), `dfllm status`: the stock line shows `ore 0 bars 8 (explore)` in a fort
    without ore; `dfllm events --type PROJECT_REQUEST` shows `explore why=ore` once a season.
  - Year review: `dfllm plan propose y.json` drafts `explore@S1` per season (and `bar:iron`, `leather` first after a
    leather mood); the propose output names the fitted depth (`explore: depth 12 at [x,y,z] ...`); `dfllm plan check
    y.json` lists the placement; `dfllm plan apply y.json`. Without a plan entry: `dfllm bp sites explore`, then
    `dfllm cmd bp.place '{"tpl":"explore","site":"S1","p":{"depth":12,"avoid":"113"}}'` (`avoid` = levels known to be
    aquifer). Watch for BREACH_STOP (damp/cavern) on the project; ore shows as `ore N` in status and smelting starts.
  - Leather: after a MOOD_RISK naming leather, `dfllm cmd inspect '{"what":"workload"}'` / kern.log for hunters (`Hunters`
    detail 1-2 with crossbow and bolts) and a `workshops why=tannery` request; trade.want `leather` first.
  - Quicksave: `python -m dfpilot save` -> `quicksave ok: autosave N written S s after the call` or
    `QUICKSAVE_FAILED: ...` (then tell Gordon; save by hand). `--dry-run` shows what it would do; `--min-gap 0` forces it.
    Check once by hand that DF 53.16's `quicksave` lands in an `autosave N` folder or the loaded save's folder (both count).

## PREDATOR only near the citizens (2026-10-16; offline, live-untested)
- Live Run 10 y421: four lockdowns in ten game days (clock 30 t/s, civilians confined) for animals at the map edge 60-120 tiles
  from the fort, because any roofed tile of the citizens' walkable group counted as "inside".
- A wild danger now raises PREDATOR (A) only inside Kern+ / past B1 or within `predator_near` tiles (config/reflex.json, default
  40, 0 = the old rule) of a citizen outside Kern+; otherwise one class-B `PREDATOR_FAR` per 1,200 ticks, no lockdown, no clock hold.
- Live check: `dfllm events --type PREDATOR_FAR` for animals at the edge; PREDATOR only when one comes near a citizen or into Kern+.

## Tool reservations swept, no pick specs for soldiers, BUG-023 (2026-10-16; offline, live-untested)
- Live Run 10 y421 after bbf75a4: `pick_res 6` of 9 picks, Woodcutters emptied. Reservations sat in the positions' `assigned_items`;
  economy's tool cap and military's member-based keep fed each other.
- military: never an explicit pick spec for a soldier; keeps at least `economy.tool_want()` (the demand before the cap); every upkeep
  unassigns picks/axes nobody carries that are reserved for positions without a weapon spec of that kind (new `act.squad_release`).
- Live check: kern.log `military: N of M reserved picks/axes nobody carries unassigned`, `inspect what=workload` `pick_res`/`axe_res` 0.

## Intake waves, the sortie through O1, inner stations, BUG-029 (2026-10-16; offline, live-untested)
- **Intake waves (Gordon's decision, on by default, `config/reflex.json` `intake`):** in SIEGE, once O1 and B1 are up,
  the civ alert sounds, no civilian or hostile is in the bailey, trap hall or field, nobody is past B1, no great danger,
  building destroyer, trap avoider or flier is in sight, >= 4 soldiers in uniform (worn >= 80 %), the army is at most 4x
  the soldiers and the traps of the intake area are armed: B1 goes down with O1 up, the squads go to the killing field
  (melee) and the gallery (crossbows), B1 rises, O1 goes down for min(6, soldiers on station) hostiles and rises again
  (also on a loss, a danger within 20 tiles of O1, fewer soldiers on station or a lower worn), kill orders on the field
  go to crossbows and melee, and once the field is clear the squads come back through B1 and rest 1,200 ticks before
  the next wave. INTAKE (B) per phase (`refused` once per reason), WAVE_FAIL (A) on losses, a hostile past B1, a field
  not clear after 4,800 ticks. Hostiles in the intake area are no BREACH and no INTRUDER; one past B1 still is.
- **Sortie through O1 (`squad.sortie` with `gate`, approved, SIEGE):** the reply compares the squad's combat value with
  the hostiles near the target x 10 and refuses below it or below worn 80 %; gather in the bailey (B1 up behind them),
  O1 down, kill near the target, recall on a loss, no target, 2,400 ticks or a danger, O1 up when all are back (or at
  once with a hostile at the gate: WAVE_FAIL left_outside names who stays out), back inside through B1. SORTIE (B).
- **Airlock:** gate lowers an outer bridge for an intake or a sortie only while every inner one is up and wanted up,
  and the reverse; never O1 and B1 down at once. The lockdown leaves those wants alone.
- **BUG-029 (inner stations):** SIEGE stands every squad, crossbows too, at the inner station (READY_IN:
  `stations.melee`, `stations.b2` while B2 is not down; STATION_B1 the same); soldiers left on the field side come in
  through the airlock (`stray`), soldiers between B1 and a raised core seal get it lowered (`unseal`). Flasks open
  (no supplies setting in act yet).
- Contracts: postures READY_IN, INTAKE; events INTAKE, SORTIE (B), WAVE_FAIL (A, RULES §7); state `wave` (status line
  `intake fight (waves 3), sortie A recall`); verb arg `gate`; manifest `stations.field/bailey`; `census.h` zone and
  danger counts; `gate.want` intake/sortie; `military.hold_order/release/members_in/squad_info`, `kill` opts;
  `siege.sortie/expects`; `snapshot.traps`; config `intake`/`sortie` (CONTRACTS §9.18, `dfpilot.lint --config`).
- Tests: `tests/lua/test_intake.lua` (new: a wave opens, closes at the wave size, clears, cools down, opens again;
  refused with a megabeast, low worn, a civilian in the bailey, intake off, traps re-arming; the trap hall is no
  BREACH, a hostile past B1 is; losses; the sortie sequence and left_outside; the airlock; BUG-029), updated
  `test_siege.lua`, `test_siege_sense.lua`; `tests/test_alarm.py`, `tests/test_cli_status.py`.
- **Live check:** `dfhack-run dfllm reload`; in the next SIEGE `dfllm status` shows `intake ...` and `dfllm events --type INTAKE`
  the phases; between waves the squads' station is `stations.melee` (130,128,122) or `stations.b2` (138,127,122) while
  B2 is up, never the gallery; a wave: B1 down with O1 up, squads in the field, B1 up, then O1 down (never both down),
  O1 up at 6 inside, the field cleared, B1 down for the way back; no BREACH or INTRUDER for goblins in the trap hall.
  No more waves: `intake.on` false in `config/reflex.json`, then `dfhack-run dfllm reload` (a running wave finishes).
## Soldiers no longer reserve the civilians' picks and axes, BUG-023 (2026-10-16; offline, live-untested)
- Live Run 10: `3 free picks, 3 reserved by squad uniforms` while 2 of 6 miners held none; DF never hands a reserved tool out as a
  work tool. military's weapon guard now keeps one pick per Miners member and one axe per Woodcutters member (was a fixed 2/1) and
  re-plans explicit pick/axe specs beyond the spare tools; act's `squad_uniform`/`squad_unequip` give a released, unheld item back
  from `items_assigned` to `items_unassigned`, as the squads screen does.
- Live check: kern.log `military: squad X: N positions give up their pick/axe spec`, `inspect what=workload` reserved tools 0,
  then the members pick their tools up (TOOL_BLOCKED stops).

## Tool repair: equipment update also for existing members, BUG-023 (2026-10-16; offline, live-untested)
- Live Run 10 y420: with `tools.equip_update` on, members added before the switch never got the request (Woodcutters 0 of 1 with
  an axe for 16 days, 5 free axes). Now a Miners/Woodcutters member without its tool while free tools exist gets the equipment
  update request again (`act.work_detail` opts `equip = 'force'`) at the first pass after a load and every `tools.repair_days`.
- TOOL_BLOCKED gains `eq`/`eq_days` and the hint says how often the request was made.
- Live check: `dfhack-run dfllm reload`, then kern.log `... holds no axe: equipment update requested again`; the member should
  carry the tool within a game day. TOOL_BLOCKED with `eq` >= 2 means the request alone does not help: report it, do not move tools.
## Template `stockroom` and the core stock in `dfllm plan` (2026-10-16; offline, live-untested)
- **Why (BUG-028, Run 10 y419):** 60 days of drink inside the core, 3093 units outside O1; `plan check` only warned.
- **`stockroom`** (`dfpilot/bp/rooms.py`, DESIGN §5.11): a room in the core with food stockpiles `dfllm-stock` (one
  barrel or pot per tile, quickfort `barrels=`; drink is stored there too) and a still (`still=1`, default; params
  `w`, `h`, `still`, `barrels`), joined to Kern+.
- **`dfllm plan propose`** drafts `stockroom` first while drink or food inside Kern+/the refuge is below 90 days and
  none was applied (food only: `still=0`). **`dfllm plan check`** adds `core stock: add tpl stockroom to a season`;
  once the fort has seen a siege (events or mode) the low value is the doctrine minimum: an error until a stockroom is
  planned or exists (`plan.sieged`, `fort_facts` `stockroom`/`sieged`).
- Tests: `tests/bp/test_bp_stockroom.py` (new), `tests/test_cli_plan.py`; README template list.
- **How to use:** year review as usual (`plan propose` puts it in), or `dfllm cmd bp.place tpl=stockroom site=S1`.
- **Live check:** in the Run 10 fort (`alert.core_d` 60, a siege in the log) `dfllm plan check` on a plan without a
  stockroom says ERROR `... the doctrine minimum since the fort's first siege`; `plan propose` drafts
  `stockroom@S1`; after it is built `inspect what=refuge` `supply` and `alert.core_d` rise as the haulers fill it.

## `traps 0` beside an armed trap hall: why, and the count that helps (2026-10-16; offline, live-untested)
- **Cause:** `bp.topo.audit` `min_traps` was the minimum over every attacker route, and the bypass the same audit found
  (Run 10: the way down to the refuge level, see the audit-findings entry; Run 9: the other openings) meets no trap,
  so 41 armed stone-fall traps read `traps 0`. The trap export itself was right (StoneFallTrap -> `S`, armed =
  `ready_timeout` 0, Z2 = the hall segments); reproduced offline with the Run 10 route shape. The other way to read
  `0` with the audit `ok` (no bypass): a way into the hall's last, trap-free tiles from the side (also reproduced);
  that one is a real hole for R2 and is now located by `dfllm audit`.
- **Fix:** with a bypass the count is taken as if the walls its findings name stood (bypass closed route by route,
  up to 4); otherwise the plain minimum, so R2 (`traps<30`, read only while R1 is green) is unchanged. A side way into
  the hall's trap-free end (R1 green) still reads 0 and is now located. `audit(..., info=)` returns `traps` {armed,
  hall, any_route, walls, enters}; `dfllm audit` prints `traps: (41 of 41 armed traps in the trap hall; ...)`, follow
  logs it; status adds `(counted as if the bypass were walled)` / `(a bypass skips the hall)` / `(dfllm audit: where
  the cheapest route enters the hall)`.
- Tests: `tests/bp/test_bp_traps.py` (new), `tests/bp/test_bp_topo.py`, `tests/test_cli_status.py`.
- **Live check:** in the Run 10 fort `dfllm audit` prints `traps 35` (or the hall's count) with the bypass finding and
  `traps: (41 of 41 armed traps in the trap hall; counted with the 1 bypass wall(s) ...)`; once the seal wall stands
  `dfllm status` shows the same count without the hint.

## Audit findings say what to build where; `seal at=audit` (2026-10-16; offline, live-untested)
- **Why (Run 10):** `bypass: edge->Z3/Z4 avoids the trap hall (reaches 139,128,117)` and `refuge: on the attack path
  (reachable without passing Z4)` named no fix. 139,128,117 is one level above the refuge: a way down to the refuge
  level outside the fort, then up the civilian stair (reproduced offline: a stair from the surface and a tunnel into
  the refuge room give exactly these two findings).
- **`bp.topo.choke`:** on the part of the route after it leaves the attack side (Z1/Z2/kill boxes/bridges), walking
  back from the target, the first tile outside the fort geometry that takes a constructed wall (floor; a ramp the
  route climbs gets the wall on its top) and whose wall closes every such route (else `(+more)`). Findings now read
  `bypass: wall x,y,z floor -> X` and `refuge: on the attack path, wall x,y,z floor` (<= 60 characters, readiness'
  cut); without a wall tile the old texts stay. The validator's `bypass` finding carries the same text.
- **`seal at=audit`** builds those walls (`at=all`: entrances and audit walls); DESIGN §5.4 has a table of every
  audit finding, what it means for the player and what to build; RULES §8 one line.
- Tests: `tests/bp/test_bp_choke.py` (new).
- **How to use:** `dfllm audit` (each fail names the wall), then `dfllm cmd bp.place tpl=seal site=S1 at=audit` and,
  once built, `dfllm audit` again.
- **Live check:** in the Run 10 fort `dfllm audit` shows `bypass: wall x,y,z ... -> 139,128,117` and the refuge
  finding with the same tile; after the seal is built both are gone (or the next route is named).

## Template `seal`: close the open ways in, one piece per opening (2026-10-16; offline, live-untested)
- **Why (Run 10):** SIEGE_UNREADY listed `90,109,125 ramp`, `53,126,127 floor`, `95,127,123 floor` as ways in without door
  or bridge; there was no template for them and the session placed doors by hand with quickfort `#build d`.
- **`seal`** (`dfpilot/bp/defense.py`, DESIGN §5.2): a door on a floor-like tile, a constructed wall on the ramp top
  above a ramp (a ramp cannot carry a door), a hatch on a stair; `close=wall|grate|bars` or a piece per opening
  (`x,y,z floor wall`). `at=last` (the default) takes the openings of the last entrance check (newest SIEGE_UNREADY,
  else `state.ready.ents`); kinds come from the newest snapshot; closed tiles are left out. Never refused for touching
  another project. One `seal:piece` line per piece in `cli.log` and on stdout. The renderer now knows hatches on
  stairs, floor grates/bars on ramp tops and wall grates/bars.
- Tests: `tests/bp/test_bp_seal.py` (new); the R0 status hint now names the template.
- **How to use:** `dfllm cmd bp.place tpl=seal site=S1 at=last` (or `at="90,109,125 ramp;53,126,127 floor"`); preview
  with `dfllm bp preview seal at=...`; the pieces stand in the reply and in `cli.log`.
- **Live check:** in the Run 10 fort after `bp.place tpl=seal site=S1 at=last` the project builds the doors/walls;
  `inspect entrances` then reports those ways in with a door (or gone) and the next SIEGE_UNREADY lists fewer.

## Outward crossbow gallery `gallery_o1` over the O1 approach (2026-10-16; offline, live-untested)
- **Why (Run 10):** in the siege O1 stayed up and 47 goblins waited in front of it for weeks; nothing could reach or
  shoot them (the inner gallery covers only the killing field). Gordon chose mechanism 3: a ranged option without opening.
- **Template `gallery_o1`** (`dfpilot/bp/defense.py`, DESIGN §5.2): constructed fortifications in the east wall of the
  tunnel in front of O1, a roofed 3-tile gallery behind them, reached only through a corridor from the inner gallery
  (Z3 side). Stages: F line dug from the tunnel, fortifications built, then strip and corridor dug from inside and
  taken out of every burrow, so the fort is never open. `bp sites gallery_o1` derives the one site from the manifest
  (O1 frame: inner gallery station + bailey, O1 when listed) and says why when it cannot (tunnel or inner gallery not
  dug, rock open). Occupancy ignores the fortcore tiles it is built against (`bp.emit.ATTACHED`).
- **Audit/validator:** manifest room `gallery_o1`; `topo.audit` fails `gallery_o1: reachable without passing Z3`,
  `not roofed`, `no fortification faces the O1 approach`, `not dug` (the bypass check catches a dug-out or door F line too).
- **`dfllm plan check`:** warning (not an error) from P5 on when the fort has or builds a fortcore O1 and no
  `gallery_o1` is planned, applied or in the manifest: `no outward gallery over O1: a waiting army cannot be shot; add
  tpl gallery_o1 to a season (site S1, once fortcore stage 2 is dug)`.
- Tests: `tests/bp/test_bp_gallery.py` (new), `tests/test_cli_plan.py`; room-only tests now list `rooms.BUILD`.
- **How to use:** `dfllm bp sites gallery_o1`, then `dfllm cmd bp.place '{"tpl":"gallery_o1","site":"S1"}'` (or a plan
  build `{"tpl":"gallery_o1","site":"S1"}`). In a SIEGE with the army waiting at O1: `dfllm cmd squad.sortie
  '{"squad":"C","target":[x,y,z],"approve":true}'` with the strip's middle tile (after asking the player).
- **Live check:** in the Run 10 fort `dfllm bp sites gallery_o1` lists S1 at the O1 footprint centre; after the project
  is done `dfllm audit` shows no `gallery_o1:` fail, `inspect what=manifest` has the room, and a crossbow squad sent
  there by sortie shoots into the tunnel while O1 stays up.

## Stranded behind our own gates: rescue, BREACH -> SIEGE, raise hold, SUPPLY_OUTSIDE, BUG-028 (2026-10-16; offline, live-untested)
- **Rescue (a):** citizens and soldiers with thirst or hunger > 30,000 on a walk group without drink/food get the inner
  and core bridges on the way to the stock lowered (never O1) once the outer gates are up, the outside is verified
  sealed and no hostile is inside or on the joined groups; up again once they are through (drank, ate, in the alert
  burrow, gone; at most 2,400 ticks) or at once when a hostile comes near. gate accepts `want(b, 'down', 'rescue')` in
  SIEGE/BREACH and during a lockdown (hostile guard and footprint rules unchanged). STRANDED (A) `rescue/done/abort`,
  `refused` with the reason. An open rescue survives a reload.
- **BREACH -> SIEGE (b):** every outer gate up, the fresh entrance check says no route, nobody hostile inside: SIEGE after
  600 ticks (`SIEGE_START ... (sealed): breach over`), the refuge is released. New transition in `contract.TRANSITIONS`.
- **Raise hold (c):** before siege first raises a bridge, `seal.split` floods each side of the footprints; a raise that
  would leave citizens (not soldiers) on a part without drink or food waits (no BREACH for it) until a hostile is within
  30 tiles of that bridge, then goes ahead: STRANDED `hold` / `forced`.
- **SUPPLY_OUTSIDE (d, A):** more than half of the drink or food stock lies outside Kern+ and the refuge (cadence: a month,
  news only); state `alert.core_d/core_f` (days inside), `dfllm plan check` warns below 90 days, `inspect refuge`
  `supply`. **(e)** the runtime hotfix `gate.BLOCK_WAIT = 10000000` is obsolete since 0b0abec.
- Tests: `tests/lua/test_stranded.lua` (new), `tests/test_cli_plan.py`. Contracts: STRANDED, SUPPLY_OUTSIDE (schema,
  contract, CONTRACTS §12, RULES §7), `seal.groups/sides/split`, `siege.held`, `gate.want` rescue, state `alert.core_*`.
- **Live check:** after `dfllm reload` in the Run 10 fort (O1 up, B1/B2 down by hand): `dfllm events --type STRANDED`
  shows no `rescue` while nobody is thirsty; `inspect what=refuge` `supply` (drink inside vs total) and a SUPPLY_OUTSIDE
  wake for the 3093 units outside O1; with the kernel running, BREACH ends in SIEGE (`events --type MODE`:
  `BREACH>SIEGE sealed`) once O1, B1, B2 are up and `inspect entrances` says sealed; a raise of B1 with citizens between
  O1 and B1 gives STRANDED `hold` instead of stranding them. Drop the `BLOCK_WAIT` hotfix.

## Run 10 batch merged: what to do after `git pull` (2026-10-16, updated with trade, BUG-027, FR-68 and BUG-028)
- Reload: `dfhack-run dfllm reload` (kernel parts: SIEGE_UNREADY, LOCKDOWN_PARTIAL, TOOL_BLOCKED, refuge levels, CUTOFF re-read,
  build_lost retry, mood cloth kinds); restart `dfllm follow --no-auto` (it audits again; `--no-audit` switches that off).
- Audit now: `python -m dfpilot audit`; drill by hand: `python -m dfpilot cmd drill '{"why":"manual check"}'`.
- Refuge (BUG-018/019): an `Innen+` painted before this version may contain exposed tiles and stay refused: delete it on the
  burrows screen, seal repaints it. `inspect what=refuge` shows `open`, `exp`, `dead`, `hint`. Forts with doorless entrances now
  often get `flee` (alert off) instead of a confinement with the enemy.
- Tools (BUG-023): the kernel reports `TOOL_BLOCKED`; `tools.equip_update` is on (Gordon's yes 2026-10-16, a fair-play exception):
  tool-detail members get the equipment update request with their labor and should fetch a pick/axe within a game day.
  Confirmed the same day: `gate.force_near` 3 and the BREACH lever burrow (`docs/v2/DECISIONS.md`).
- Trade (BUG-026): while a caravan visit runs, trade holds a kernel boost (not demoted, 20 ms/s, snapshots and seal background
  jobs wait) and the arbiter caps the clock at `clock.trade_cap` (100); `caravan.time_remaining` counts 10-tick units. New:
  `cloth:plant|silk|yarn` / `thread:*` tokens (mood needs reach the want list), verb `trade.retry` (second trade in one visit),
  `inspect what=trade` `wanted_matches` (also goods still carried by the merchants).
- Bridges (BUG-027): no pull while any non-hostile unit is on or next to the footprint; forced raise only with a hostile within
  `gate.force_near` (3); alert first, then raise; backup lever; BRIDGE_CRUSH. The runtime hack `gate.BLOCK_WAIT = ...` is obsolete
  (the field no longer exists).
- Stop guard (FR-68): `dfhack-run dfllm stop` in SIEGE/BREACH/ALERT keeps the FPS cap (30/100) and starts `dfllm-guard`
  (dismisses known blocking popups, keeps the clock); `dfllm boot`/`reload` remove it, `dfllm restore` or `stop --restore-fps`
  release the clock. Lever burrow: in BREACH `Hebel+` is listed while no hostile is in Kern+ or near the levers (the cause of
  `GATE_FAIL no worker` in y419).
- Siege supply (BUG-028): stranded citizens (thirst/hunger > 30000 on a group without drink/food) get the inner bridges
  lowered once the outside is verified sealed (STRANDED rescue/done/abort/refused, never O1); BREACH falls back to SIEGE after
  600 sealed ticks; a raise that would cut citizens off from all drink/food waits (STRANDED hold) unless a hostile is within
  30 tiles; SUPPLY_OUTSIDE when most of the drink/food lies outside Kern+/refuge; `dfllm plan check` warns below 90 days inside.

## Lever burrow check in BREACH, BUG-027 (2026-10-16)
- Run 10 y419: after `BREACH O1 not up at T+900` (enemy far) every O1/B1 lever lay in Kern+, but the BREACH alert holds the civilians in Tiefe+ and the
  lever burrow `Hebel+` was never listed in BREACH, so nobody could pull them (`GATE_FAIL ... no worker: its levers lie outside the alert burrow`).
  In BREACH `gate.rooms` now lists `Hebel+` while no hostile is inside Kern+ and none within 20 tiles of those levers; the GATE_FAIL names the burrows.
- A mode change that renews an `up` epoch resets that epoch's no-worker history and bad levers. A popup pause cannot cause `no_worker` (game-tick timers).
- Tests: three cases in `tests/lua/test_gate_footprint.lua`.

## Stop guard FR-68: `dfllm stop` in a fight keeps the clock and the popups clear (2026-10-16; branch fix-ready, offline, live-untested)
- **Live siege y419 (Run 10):** the session stopped the kernel for ~3 min to pull levers by hand. `dfllm stop` put the
  FPS cap and timestream back to 500 and left every popup standing, so each death notice ("found dead, dehydrated")
  halted the simulation until `dfllm reload` (back in BREACH).
- **`dfllm stop` in SIEGE/BREACH/ALERT or during a reflex lockdown** now restores every setting except the FPS cap and
  timestream (arbiter `on.UNLOAD` with `hold_ok`; `restore.json` stays `active:1`) and prints/logs a warning: `stopped in
  SIEGE: FPS cap held at 30, timestream off; guard dfllm-guard runs ...`. `dfllm stop --restore-fps` = the old
  full restore. PEACE, map unload, reload and restore behave as before.
- **Guard `dfllm-guard`** (`lua/dfllm/guard.lua`, repeat every 10 frames, also while paused) while the kernel is stopped:
  dismisses the front popup when the arbiter's whitelist knows it (new public `arbiter.classify`, `act.dismiss_popup`, as
  the arbiter does), holds the vanilla FPS cap at the mode's clamp (30 SIEGE/BREACH, 100 ALERT) and timestream off (only
  with D-11 accepted), never pauses or unpauses, logs to `commands.log` (origin `guard`), reports in `<save>/guard.json`.
  `dfllm boot`/`adopt`/`reload` remove it (the boot's heal puts the original cap back before the new capture; kern.log
  `stop guard removed at boot: ...`); `dfllm restore` removes it and releases the clock; a map unload removes it and heals.
- **`status`/`brief`** (Python) print `GUARD: kernel stopped in SIEGE 3m ago; dfllm-guard holds FPS cap 30, timestream off,
  dismissed 4 popups (death 3, ...) | dfhack-run dfllm boot resumes the kernel, dfllm restore releases the clock` on line 2
  (`GUARD last seen … ago` when DF closed while it ran); in game `dfllm status` names the guard when the kernel is stopped.
- Tests: `tests/lua/test_kern_arbiter.lua` (2 FR-68 cases on the real kernel: SIEGE stop, popups, clamp, boot ends it,
  `--restore-fps`, PEACE, ALERT cap, `dfllm restore`, map unload, reload, D-11, lockdown in PEACE), `tests/test_cli_status.py`
  (GUARD line, stale, off, malformed), `tests/test_hook.py` (`dfllm stop --restore-fps` allowed).
- **How to use / Live check:** after `git pull`, `dfhack-run dfllm reload`. In a siege, `dfhack-run dfllm stop` must print
  `stopped in SIEGE ... FPS cap held at 30 ...; guard dfllm-guard runs`; `dfhack-run dfllm status` says `kernel not running;
  stop guard on: SIEGE, FPS cap 30, timestream off, N popups dismissed`; `python -m dfpilot status` shows the `GUARD:` line; a
  death notice disappears within a second while DF's Settings show the FPS cap 30; `<save>/commands.log` has `guard
  act.dismiss_popup` lines. Then `dfhack-run dfllm boot` (or `reload`): the guard is gone (`guard.json` `on:0`, kern.log
  `stop guard removed at boot`) and the mode's clock is the kernel's again. `dfhack-run dfllm restore` (or `dfllm stop
  --restore-fps` while stopped) gives the original FPS cap back without booting.

## Siege readiness gate FR-65, audit and drill with `follow --no-auto` (2026-10-16; branch fix-ready, offline, live-untested)
- **Run 10 (Handlelock): `audit FAIL never` and `drill never` for the whole fort.** The session ran `dfllm follow --no-auto`,
  which also switched off the audit job (the only sender of the `audit` verb), `dfllm cmd audit` is refused by design
  (VERB_BY, hook) and `snapshot purpose=audit` alone produces no result. Now `--no-auto` stops only the automatic
  placements (tombs, workshops, farms, P0/P1 starters); the audit still runs (it changes nothing in the fort, it is the
  readiness input). `--no-audit` switches it off too.
- **`dfllm audit [--snap ID] [--timeout S] [--wait S]`**: follow's audit job once, on demand: a fresh audit snapshot (the
  kernel's default box: manifest geometry + margin; ids `aud…`, which follow leaves alone) or `--snap` (an audit snapshot
  of this boot), the kern manifest, `bp.topo.audit`, the `audit` verb (`by:'follow'`; shared code `wake.compute_audit`).
  It takes no result args, so the trust rule holds: the hook and `dfllm cmd` still refuse a hand-written `dfllm cmd audit`
  and now point to `dfllm audit`. Exit 0 stored, 1 refused (e.g. `unknown snap`), 2 not sent, 3 no reply.
- **Drills were scheduled all along** (first, yearly, every season for R2, after a siege, retries), but only with an
  outer/inner manifest bridge, phase ≥ P5 and soldiers, so a fort without fortcore never drilled and nobody saw why.
  New public `drill.hold()` (`no bridges`, `phase P3<P5`, `no soldiers`, `retry wait`, `merchants`, …), published by
  readiness as `ready.dhold`; `status`: `drill never (auto: no bridges; run dfllm cmd drill)`, `audit never (run dfllm audit)`.
- **FR-65:** readiness emits **SIEGE_UNREADY (A)** while R0 fails in PEACE: the R1 blockers (`no_outer`, `bridge:B1`,
  `levers:B1`, `refuge_sep`, …), the ways in without a door or bridge from seal's last entrance check (`x,y,z kind`, via the
  public `seal.entrance_doors`; seal.lua is unchanged), the last audit's trap count and its own fail texts; first 2 days
  after a load at the earliest, then after a game month and 30 real minutes (10 when a blocker or an open way in is new;
  util/cadence, the record persists in `m.readiness`). State `ready.open/ents/dhold` (optional). `status` and `brief`
  never show a plain PEACE at R0: line 1 `PEACE UNREADY`, line 2 `SIEGE UNREADY (R0): <blockers> | 2 ways in without door
  or bridge: … | traps 0 | next: dfllm audit; wall/door the open ways in …`. follow's hint: `inspect entrances`, then
  `dfllm audit`. The R0 → R1 tokens are explained in `docs/v2/DESIGN.md` §5.4 (table) and RULES §8.
- Tests: `tests/lua/test_readiness.lua` (2 FR-65 cases: payload, cadence, reload, PEACE only, R1 quiet, no entrance check),
  `tests/lua/test_drill.lua` (`drill.hold` reasons, `ready.dhold`), `tests/test_cli_wake.py` (`--no-auto` keeps the
  audit, `--no-audit`, `aud…` snapshots, `dfllm audit` fresh/`--snap`/refusals, the wake hint), `tests/test_cli_status.py`
  (UNREADY lines, budget, schema), `tests/test_integration_v2.py` (trust rules for `dfllm audit`).
- **How to use / Live check (game session with `--no-auto`):** restart the watcher (`python -m dfpilot follow --no-auto`:
  it now audits every audit snapshot), then run the audit at once: `python -m dfpilot audit` (prints `audit of snapshot
  aud… : ok no, traps 0, bypass yes, …`, the fails and `ok … audit: audit stored, readiness R0`); an older audit snapshot of
  this boot: `python -m dfpilot audit --snap <id>` (ids: `python -m dfpilot events --type SNAPSHOT_READY`). A drill by hand
  (PEACE, no merchants): `python -m dfpilot cmd drill '{"why":"manual check"}'`, result after T+1,200 in `python -m dfpilot
  events --type DRILL_RESULT`. Check: `python -m dfpilot status` shows `audit FAIL <age>` or `audit ok` instead of `audit
  never`. The kernel part (SIEGE_UNREADY, `ready.open/ents/dhold`, `drill never (auto: …)`) comes with the next load of the
  save; then within 2 game days at R0 in PEACE a `SIEGE_UNREADY` wake whose ways in match `python -m dfpilot cmd inspect
  '{"what":"entrances"}'` (`python -m dfpilot events --type SIEGE_UNREADY`).
## Lockdown doors read back, mood needs from the attached items, build_lost retried, embark fails early, BUG-015/017/022/020 (2026-10-16; offline, live-untested)
- **BUG-015:** reflex reads every door it forbade back on the next pass; a door whose flag fell back leaves the count and the undo, is
  named `partial lockdown: door 16970 (74,70,117) refused (flag reset)` and announced once per lockdown by the new class-A event
  `LOCKDOWN_PARTIAL` (with the units and items on its tile), and is tried once more (forbidden + closed, `act.door_forbid` `close`)
  when its tile changed, at the latest 1,200 ticks later. LOCKDOWN_END counts only doors really held (`, 1 refused (flag reset)`);
  state `alarm.dref`; new `snapshot.units_at`. Tests in `tests/lua/test_lockdown.lua`, `tests/lua/test_kern_act.lua`.
- **BUG-017:** MOOD_RISK and MOOD_NEED list only mood filters still without an attached item: care reads the mood job again at
  report time, the thirst/hunger MOOD_RISK drops classes the dwarf collected since the last run (`nothing missing`), and
  `reserve.job_needs` matches attached items without a filter index to the filter they fit. A class with no item in the fort is
  named (`leather: no source in the fort`, d `nosrc`). Cloth and thread kinds (Run 10 y418): `care.mood_wants` `buy` =
  `cloth:plant|silk|yarn` (`thread:*`) for a kinded filter, MOOD_RISK names the kind's stock (`cloth(plant) 0 in stock`), and the
  mood reserve splits its cloth/thread hold over the kinds in stock (line `cloth 10/10 (plant 2, silk 5, yarn 7 in stock)`).
  Tests in `tests/lua/test_care_moods.lua`, `tests/lua/test_reserve.lua`.
- **BUG-022:** a dig stage keeps the hidden tiles it completed without (m.runner `skip`, per chunk); a `build_lost` project runs again
  from its dig stage once those tiles are revealed or more missing cells stand on open floor (checked daily, at the latest a season
  later, 8 retries). PROJECT_BLOCKED follows the cadence rule (once per project, stage and cause; the budget spent once more) and names
  the missing pieces (`missing B1, lever B1 x3, trap`, d `missing`, `retry`). Tests in `tests/lua/test_runner.lua`.
- **BUG-020 (mitigated):** `embark.py scan` stops early with `local.place: rectangle does not follow the mouse: held A and B,
  rectangle stays at X` when two confirmed misses for different held pixels show the same rectangle, instead of learning a k from
  them and running the hold out of the window; the cause stays open. Test in `tests/lua/test_embark.lua`.
## Economy: miners and woodcutters with their tools, reachable workload, steel chain, webs, BUG-023/BUG-024 (2026-10-16; commit 47d98c4, offline, live-untested)
- **Miners sizing (Run 10, Handlelock: 29-33 dig jobs waited, target 2):** one miner per `tools.details.Miners.tiles_per` = 10 dig
  jobs (was 40), one per `runner_per` = 40 of the runner's dig tiles, `ore` = 1 more while metal is wanted and the fort has no ore;
  every tool detail is capped by its free unreserved tools plus the tools its members hold (picks a squad uniform reserved are no
  free picks); when it shrinks, members holding the tool stay first. A log line says when one dig front keeps several miners idle.
- **Members the player put in stay:** economy takes off only the members it added (persist `m.economy.tools[name].mine`); the
  others count toward the target and make no WORK_DETAIL. Members present at the first run after the update count as the
  player's. Hunters and fishers still all leave when the fort leaves PEACE.
- **Labors through `act.work_detail`:** a member without the detail's labor (`labor` = MINE, CUTWOOD, HUNT, FISH) gets it through
  `act.work_detail` (Lua writes to `assigned_units` set no labor), at most every `repair_days`. `act.work_detail` opts `only`: a
  miner leaves the everybody-does-this details that are no tool details (Planters in mode 1 took six of eight miners to the farms)
  and their labors go off except `keep_labors` and those of a selected detail; not during a starvation.
- **TOOL_BLOCKED (A, BUG-023):** Miners/Woodcutters members without pick/axe for `block_days` while the detail's jobs wait and free
  tools exist; the event names members, free tools in bins / loose / reserved and a position; cadence rule. The starving-postings
  line ends `: no axe in hand (Woodcutters 2 of 2)`. The direct equip (moveToInventory) is not implemented (fair play); the
  engine's pickup request `tools.equip_update` is in `act.work_detail` but off until Gordon says yes. No-bin storage and the
  E18 pick-uniform squad were not built: v1 measured bins are not the cause and pick uniforms reserve the picks.
- **`inspect workload` (FR-40):** unclaimed = no worker, a live job-board posting (else `waiting`) and on a citizen's walk group
  (new `snapshot.groups`; a dig wall or tree counts by its neighbours); `unreachable` apart; `idle_noreach` (idle adults whose
  group has no unclaimed job); `blocked`, `cloth`, `tools.{pick,axe}_{bin,res}`.
- **Steel chain:** manager orders waiting for steel bars (`no bars:INORGANIC:STEEL`) get `dfllm:pig_iron` (PIG_IRON_MAKING) and
  `dfllm:steel` (STEEL_MAKING) orders when a smelter, iron, flux and fuel exist (iron ore is smelted, charcoal follows the bars);
  otherwise DECISION_NEEDED `steel` names the missing input once (cadence).
- **BUG-024:** spider webs are counted apart (`webs`, `webs_near`) and never as thread; WeaveCloth orders say `no collected thread
  (N webs, none on the walk group)`; a CollectWebs hint (log) only for webs on the citizens' walk group.
- Contracts: event TOOL_BLOCKED (schema, contract.lua, CONTRACTS §12, RULES §7, wake hint); `act.work_detail(name, id, on, opts?)`;
  census `w_{pick,axe}_{bin,res}`, `webs`, `webs_near`; config `tools.{block_days,repair_days,equip_update,keep_labors}`,
  per detail `labor/tool/jobs/runner_per/ore/only`, `metal.steel`.
- Tests: `tests/lua/test_economy_tools.lua`, `tests/lua/test_economy_reach.lua`, an act case in `tests/lua/test_act_supply.lua`
  (all fail on the old code); tool-detail tests adapted to the kept player's members.
- **Live check:** after `git pull` + `dfllm reload`: `inspect workload` (Miners target ~3-4 for 33 dig jobs, `blocked` lists the
  miners/woodcutters without tools, `unreachable` holds the GatherPlants outside the wall, `cloth.why`); a TOOL_BLOCKED wake with
  the bin position; kern.log `Miners: ... left the everybody-does-this details` and `labor: ... no axe in hand`; `inspect orders`
  for the steel orders (pig iron/steel orders or DECISION_NEEDED steel naming the missing input); no WORK_DETAIL for the
  hand-added miners.
## Refuge: separated burrows only, BREACH level, the dead end Tiefe+, bed share, CUTOFF confirmed, BUG-018/019/021, FR-67 (2026-10-16; offline, live-untested)
- **BUG-018:** a burrow is confined to only when no entrance of seal's entrance BFS reaches it without a door, hatch, bridge or floodgate
  (an exposure flood after every BFS; a porch of <= 12 tiles behind an entrance does not count) and no visible hostile stands in it.
  REFUGE_FAIL names the entrances (`Kern+: open to 1 entrance 20,10,9 stair_up (5 steps)`, `d.open`); with no separated burrow and no
  dead end nobody is confined (`flee`): siege turns the alert off even while a lockdown holds it and never substitutes Kern+ for seal's pick.
  `Innen+` is painted without the exposed tiles.
- **BUG-019/FR-67:** levels SIEGE (counts) and BREACH (separated, reachable, >= 9 tiles, no counts) for `breach_days` (7). The dead end behind
  the deepest stair is painted as `Tiefe+` when missing (boot, scans; at once in BREACH or with an entrance into the burrows) and is the
  last fallback (>= 10 steps from every entrance). Live case Run 10 y419 (`Tiefe+: 63 tiles<109, beds 8<28 -> confining to Kern+`) now
  gives Tiefe+.
- **Refuge beds:** beds >= ceil(citizens x `bed_pct` %) (25: the share asleep at once; `beds 18<23` was 18 beds for about 90 citizens, not
  23 citizens); a shortfall only ranks the burrows (one with enough beds first), never refuses the only usable one; the text says the
  formula (`beds 18<23 (25% of 90 citizens)`). Knobs `refuge.bed_pct` and `refuge.breach_days` in `config/reflex.json` (lint --config).
- **BUG-021:** CUTOFF only after the citizens' and the class tiles' groups were read again in one go; the text names a cut-off citizen and a
  stock tile with their groups (`d.unit/upos/at/agrp`). The entrance check starts over when the walk groups were renumbered while it ran.
- Tests: `tests/lua/test_seal_refuge.lua` (new), `tests/lua/test_lockdown.lua`, `tests/lua/test_seal.lua`, `tests/test_seal_files.py`,
  `tests/test_alarm.py`. Events: REFUGE_FAIL `level/flee/open`, CUTOFF `unit/upos/at/agrp` (`dfpilot/schema.py`).
- **Live check:** `dfllm cmd inspect '{"what":"refuge","key":"refresh"}'`: `burrows.Kern+` shows `sep` (0 with `open` = the doorless
  entrances), `ok` 0 while an entrance reaches it; `dead` names the dead end and `burrows.Tiefe+` exists (kern.log `seal: Tiefe+ painted
  with N tiles ...`); `choice.SIEGE/BREACH` name Tiefe+ (`level` BREACH or DEAD) or `flee` 1; `need.beds_rule`; `hint`. If `Innen+`
  predates this version it may hold exposed tiles (`sep` 0): ask the player to delete it on the burrows screen; seal paints it again
  without them.
  After a construction: no CUTOFF with `cause not found`; `inspect reach` `runs.cut_unconfirmed` counts the dropped ones.
## Visitors and merchants hold a bridge pull too, BUG-027 (2026-10-16)
- `gate.watch()` gives sense the footprints of the bridges with work; sense lists the visible friendly non-citizens there (visitors, merchants, tame
  animals) as `census.h.friends`, and gate holds the pull for them like for citizens. Test in `tests/lua/test_gate_footprint.lua`.

## BRIDGE_CRUSH and the death cause `crushed` by a bridge, BUG-027 (2026-10-16)
- gate records each bridge move (the pull, the move window, the units it saw within 5 tiles of the footprint while it pulled or the bridge moved);
  public `gate.moves()`; GATE `moving` names units on or next to the footprint.
- New class-A event `BRIDGE_CRUSH` (gate, on UNIT_DEATH, once per unit): a death in a move's window of a unit gate saw within 2 tiles of the footprint
  (also a death still "missing" in the unit list), a found body on or next to it, or an incident DRAWBRIDGE; never a combat incident.
- care's DEATH says `crushed` (src `bridge`) with `bridge` and the evidence (`dfllm.deaths.bridge`); Run 10's seven deaths all read `unknown (missing)`.
- Tests: three cases in `tests/lua/test_care_deaths.lua`, one in `tests/lua/test_gate_footprint.lua`.

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
## Trade: cloth kinds, mood wants, a second trade per visit, wanted goods in inspect (Run 10 y418, 2026-10-16; offline, live-untested)
- **Cloth and thread kinds:** `cloth:plant`, `cloth:silk`, `cloth:yarn` (and `thread:…`) match by material flag THREAD_PLANT, SILK, YARN;
  plain `cloth`/`thread` stays "any"; other cloth/thread subs are refused (`dfpilot/schema.py` TOKEN, the `trade.want` verb).
  `inspect what=trade` names cloth goods with their kind (`cloth:plant`).
- **care.mood_wants:** the entries' `buy` tokens (e.g. `cloth:plant` from the mood agent's reserve) go before `plan.trade.want`, capped at the
  units the moods miss; trade buys only the matching kind.
- **Verb `trade.retry {civ?, want?, sell?}`** (PEACE): a second trade in the same visit while the caravan stands at the depot with
  `time_remaining` >= 300 (3,000 ticks); resets the visit and optionally the wants (as `trade.want`). Replaces the live `debug.getupvalue` hack.
- **`inspect what=trade` `wanted_matches`:** every merchant good that matches a want token whatever its value, in a depot or still carried by
  the merchants and pack animals (from the item vectors of the wanted types), per token, type and material; at most 40 kinds,
  `wanted_more` counts the rest, the reply stays within 8 KB; `carried_items`.
- Tests: five cases in `tests/lua/test_trade.lua` and the schema cases in `tests/test_schema.py`, all failing on the previous commit.
- Live check: `inspect what=trade` shows `wanted_matches` with `carried` > 0 while goods are still on the animals; `trade.want '{"want":
  ["cloth:plant"]}'` then buys only plant cloth (ledger `bought cloth:plant`); after a trade with time left, `dfllm cmd trade.retry
  '{"want":[...]}'` answers `trade with <civ> restarts` and a second `CARAVAN traded` follows.

## Trade gets the kernel's priority during a caravan visit, BUG-026 root cause; review of BUG-025/026 (2026-10-16; offline, live-untested)
- **Kernel boost** (`util/sched.lua`, `kern.lua`, `k_mock.lua`, CONTRACTS §3.3.9/§4): `K.boost(why, busy)`, `K.unboost()`, `K.busy()`. A boosted
  module (only `trade`) is not demoted, is paced at 20 ms/s outside the PEACE pool, and starts and ends without an old debt; 30 s TTL.
  `busy` makes snapshot exports and seal's background jobs wait. trade holds it from the start of a visit (caravan approaching or at the
  depot, PEACE) to its end, busy on the trade screen.
- **Trade clock** (`arbiter.lua`, `trade.clock()`): FPS cap `clock.trade_cap` (config/reflex.json, default 100) from the first trade-screen
  phase until the visit ends; never above the player's cap.
- **Phase limits on trade's own clock** (`PHASE_MS`, `TALK_MS`, `REPLY_MS`; at most 250 ms per run): a starved module no longer times out.
  `CARAVAN retry/failed` add `ph_act`, `ph_runs`; the event fields are declared in `dfpilot/schema.py`.
- **Review fixes:** `time_remaining` counts 10-tick units (retry wait, `left` in ticks, no retry without room, `inspect` `left_ticks`); the
  depot toggles are restored at the depot they were set at and the broker request follows the merchants to their depot; with two depots the
  sale items wait for the merchants' depot; one depot scan per step; `DEPOT_ITEMS` counts the newest items; a departing caravan's ledger
  never uses another visit's goods.
- Tests: 14 new cases (trade, trade ledger, kern load, arbiter, snapshot, seal), all failing on the old code.

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
