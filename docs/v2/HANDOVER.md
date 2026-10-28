# Handover of the dev session to the game session (2026-10-28)

The dev session ends its implementation work here. The game session continues the development. State at handover:
main `10260c1`, gate green (pytest 0; 137 Lua suites, 1682 tests; `dfpilot lint lua/dfllm` 0; `lint --config` ok;
RULES.md 300 lines). **Everything merged since BUG-044 is tested offline only; nothing is confirmed in a live game.**
Nothing is in flight: no worktree, no open branch, no unmerged commit.

## How to work (rules that held through all waves)
- Fair play (RULES section 1.1, `dfpilot/fairplay.py`) is binding. RULES.md stays at 300 lines or fewer: edit rows in place.
- Tests first; every new test must fail on the previous commit. Gate before every commit:
  `python -m pytest -q`, `python tools/luahost.py --tests tests/lua`, `python -m dfpilot lint lua/dfllm`,
  `python -m dfpilot.lint --config`, `wc -l RULES.md`.
- Contracts live in `dfpilot/schema.py` AND `lua/dfllm/util/contract.lua`; after a change run
  `python -m dfpilot.schema --write-appendix docs/v2/CONTRACTS.md`. A class A event needs a RULES section 7 row.
  Event `d` strings stay under 200 bytes. Repeated messages follow `lua/dfllm/util/cadence.lua`. `economy.lua` and
  `runner.lua` sit at Lua's limit of 200 locals: put helpers into module fields. Token budgets: STATUS 300, BRIEF 1500, WAKE 150.
- `bugs/README.md` table: five columns (ID | Status | Severity | Title | Module), strictly ascending, one row per bug file
  (a test checks it). Each bug number gets a file in `bugs/`; each package gets one CHANGELOG entry (Why / What changed / Live check).
- Commits end with the two trailer lines `Co-Authored-By: ...` and `Claude-Session: ...`; no model names elsewhere.
- Merging parallel branches: the conflicts are always the same files (CHANGELOG.md, bugs/README.md, docs/feature-requests/README.md,
  RULES.md rows, `docs/v2/CONTRACTS.md` incl. its contract digest, `config/*.json`, `dfpilot/schema.py` enum lists). Keep both sides, regenerate the
  CONTRACTS appendix, and make tests that read "the top CHANGELOG entry" search for their own entry instead.
- The note numbers of the game session (`bugs/RUN11-offene-bugs-und-FR.md`) are not our BUG ids. `docs/v2/TRIAGE-run11-14.md`
  maps notes to ids. Next free ids: BUG-121 and FR-94 (BUG-121..127 were reserved for the open notes below and are unused).

## Open to-dos (not started)
1. **Note 100 `dfllm resume`** (FR-94): a kernel verb that releases a pause set by DF (after a load, a restart or a popup) with a UI-equal
   action (the pause key to the main DF viewscreen, as the inbox/arbiter already do it), allowed only in the state pause:df or pause:popup,
   only when no popup with a DENY word (curse, transform, were, vampire) is open, at most once per 60 s, the answer names the previous
   reason and the new state. Unknown popup: read its text and put it in the wake, never silent. Wake `PAUSED_BY_DF for N min: dfllm resume`
   (config key, about 5 real minutes). Tests for every refusal and the success path.
2. **Note 101 TIMELINE_RESET** (BUG-121): after loading an older save, `events.jsonl` and `follow.cursor` stand in the discarded timeline
   and `follow` replays its events as fresh wakes. The kernel writes a marker event `TIMELINE_RESET (n_alt, tick_alt, tick_neu)` at boot when the
   clock jumped back; `follow`, `events` and `brief` drop events newer than the current tick or older than the last marker; lockdown and
   `alarm.txt` state of the old line are not taken over. A timestream restart must not trigger it; first boot without a log.
3. **Note 102 refuge check without a stair** (BUG-123..125; DONE offline in branch `fix-refuge-seal-102`, see CHANGELOG): `plan check` demands `seal at=refuge` as the first build for a manifest stair at
   77,68,125 that is undug, unrevealed rock; the seal then fails with "the tile is not revealed", so even the hospital is blocked. Wanted:
   a manifest stair that is not a stair on the map is "refuge: no stair found (not dug)", a warning, not an error; the stale entry is flagged, not
   deleted; a real stair whose hatch tile is not revealed moves the hatch to the nearest revealed tile of the same stair or asks the player once
   (DECISION_NEEDED, cadence); hospital, coffins and tombs are never blocked by the seal demand. A real exposed refuge must still be demanded first.
4. **Note 103 coffins** (BUG-126, 127): brief says coffins want 67, short 10, stock 4, order 0, proj `cof272266509` for three game years while 62 bodies and
   21 ghosts wait; the session had to send `order.add ConstructCoffin material_category wood` by hand (stone is refused as material_category). Prove why the
   FR-61 provisioner (care.lua / economy.lua, `inspect tombs` prov) orders nothing (a stale project id that never completes, a wood-only gate, a full
   order queue with stuck orders, a cap or cooldown, the order counter), then order the amount short (wood first, stone through the material field a manager order
   really accepts), drop the stale project, re-issue when the order vanished or is stuck, DECISION_NEEDED when neither wood nor stone exists.

## Not built (deliberate or unproven)
- Note 99 keyboard path for loading from the title list (`gui.simulateInput`): BUG-098 showed that SELECT moves nothing; the mouse path stays.
- Note 84 isolation of the cursed (burrow plus forbidden door): no verb paints a burrow or forbids a door for a unit; the recipe is text for the player.
  A template `isolation` and statue removal are not built (FR-84 lists them). A kill order stays a question (`curse_kill`).
- Note 98 automatic dump-zone placement by the kernel: needs a safe map read; the planner places it with `zone.place type=dump`. The trash bridge is not read.
- Note 95 zoom of the `view` verb: no UI-neutral zoom setter was proven offline.
- Note 83 Soap Maker and Screw Press (Custom workshops without a `df.workshop_type` name).
- Note 80 cause of the 49 days without cloth: undecidable offline. Covered by the R0 blocker `mood_ws` and the cloth floor.
- Note 93 friends of a unit are not read (no known field); note 90 enabling SUTURE / DRESSING_WOUNDS labors for doctors is only audited, not done.

## Known low-impact risks recorded by the reviews
- `ocancel` persistence can grow; care log lines repeat at timestream speed; `schema.MODULES` periods differ from the modules' own.
- Feature request README order is not ascending (77, 76, 75, 78, 71, 79, 70, 72, 73, 74 at the old end).
- R0 `mood_ws` can be loud in a fort that never builds e.g. a Jeweler (7 days, 20 citizens; switch off with `offices.mood_ws_days` 0).
- The readiness/open_perimeter test fixtures pin the older caps (55/75) and option A to test the level logic; the shipped values (cap 100, D-01 = B) are pinned by one test.
- Old model names remain in RULES.md (lines 17 and 99), DESIGN.md and ASIS-ANALYSIS.md; they were left untouched on purpose.
- Open game questions: who removed hand-added Planters members (BUG-057), who re-closes tomb zones (BUG-062), the 10 FPS clamp after a gremlin alarm (BUG-065),
  seal door suspension (BUG-044), what DF does with a leaver's kit on squad removal (FR-79), whether one unit can hold two occupations (BUG-077),
  where an engraved memorial slab is placed (BUG-090), the cause of the burrow collapse (read `BURROW_SHRUNK` `d.cause`), job_item flag names of 53.16 (BUG-100).

## Live checks still waiting (per package; uncertainty first, then what to read)
The lists below are the hand-back of the seven implementers of the fourth pass. Items 1-5 of the message to the game session
(title-screen loader, curse texts, hospital inspect, GiveWater counters, `dfllm next` / doctor) are the most valuable ones.

### bulk-m1-care
UNCERTAIN
 - Why the game posts no GiveWater job with caregivers and buckets present: the new line says nojob/open/stuck/noreach/alert but not why. Decided only by live data.
 - Whether a running GiveWater job can legitimately have pos -30000 (note 79 says so); the stuck test therefore uses job age (open without worker for give_stuck_days), not pos.
 - Hospital location supply field names in 53.16 (contents.desired_splints, count_splints, need_more.splints, powder for plaster) are guesses probed with pcall; supply_unknown is reported when none exists.
 - Whether the walk group of a branch tile is 0 or a group of its own; both paths end in canWalkBetween false and are classed corpse_unreachable via groups==0 or shape BRANCH/TRUNK_BRANCH/TWIG/T.
 - Which wound-care items the game really requires (table for surgery/suturing, SUTURE and DRESSING_WOUNDS labors, plaster, soap); the audit lists what a player can see, not what DF needs.
 - Whether a resident in a strange mood who claimed one of our workshops should still be served; every non-citizen is ignored as demanded.
 - The base commit is red on 13 pytest tests and 4 Lua suites (D-01 pop cap 100 changed config/baseline.json only); I left it alone, the failing sets are identical before and after.
LIVE
 - At the next PATIENT_DYING or patient_thirst read d.key and the counts (jobs open/running, idle, reach, buckets); for nojob/open/stuck dump read-only the GiveWater job list entries (job.flags, job.pos, worker, general_refs) over a few days plus the patient's needs_healthcare, tile and walk group.
 - Run dfllm cmd inspect '{"what":"hospital"}' in a fort with a hospital: supply_unknown means the guessed supply fields are wrong (list the real ones with pairs on the hospital location's contents); check no_table, no_suture, no_dress against how that hospital treats a wounded dwarf.
 - Read getWalkableGroup and getTileType of the five branch tiles of note 81 (x119-123, y64-72, z133) to see which classification test fired; confirm corpses_unreach 5 and corpses_old 0 in status.
 - For unit 38663-like cases read isResident, isMerchant, isVisitor, civ_id, mood and the claimed workshop to see why a caravan member was in census.u.ids.
### bulk-m2-siege
UNCERTAIN
 - 78: what the live pick was at the 37 deaths (REFUGE_FAIL 'Kern+: food 0<86' means Kern+ was refused, so the fallback may have been Innen+ and the deaths may have another cause: reach, beds)
 - 88: whether the live config/reflex.json listed 'alert' for DEATHS_3PLUS (the post-mortem says civ alert Kern+; shipped default is clock only)
 - 76: the note's tiles (doors 121,67/121,69, ramps 122,67/122,68) do not fit the quoted footprint 88,67,130-88,69,130 nor KP.cells of a 1x3 footprint; the python seal refusal (cmd.py:872-889, door entry with no neighbour on the snapshot) is unchanged and not reproduced
 - 76: whether DF accepts the ramp-top wall in the second quickfort stage
 - defaults floor_pct 100, floor_pop 30, supply_switch 50 are judgment calls
LIVE
 - inspect refuge at the next SIEGE/lockdown: choice.*.burrow/level (FED, WET), burrows[].fed/food/drink/wells/tiles, alert.ok/why; REFUGE_FAIL fallback/level/sup and REFUGE_SWITCH why=supply in events.jsonl
 - for the 37 deaths: inspect refuge of that moment, REFUGE_FAIL fallback, kern.log 'Innen+ painted with N of M interior tiles', inspect reach (path Kern+ to Innen+, beds)
 - config/reflex.json defaults.DEATHS_3PLUS of the fort's runtime folder and the LOCKDOWN events' d.alert/d.clock of Run 14; after a death wave with nothing in sight kern.log 'inner cause at threat 0' and no LOCKDOWN
 - after a bridge loss: kern.log 'the entrance check still finds a way in beside its closure' (tiles), inspect defense bridges[].rebuild.follow, inspect entrances openings[].gap/doors and a snapshot of the 5x5 around 121,68,131 (bp sites seal --fresh)
 - first REFUGE_STOCK of a fort of 30+ (d.cmd sent, stockroom site found with bp sites stockroom); status after a refused drill shows '[N refused: build fortcore stage 2/3 first]'
### bulk-m3-intruder
UNCERTAIN
 - What unit 39230 really was (child by size 6486? visitor/diplomat/restrained?) and whether DFHack isInvader is true for such units; the classification names the reason, BUG-113 not_attackable clears it by behaviour if the flags miss it
 - Why the real BREACH of note 97 did not end with '0 visible' (hidden but alive hostile, stale census, RECOVERY falling back into BREACH?); the new 'BREACH since N d: ... quiet clock: ...' line will show it
 - Whether DF removes a spent move order from squad.orders on arrival and whether body.wounds grows when a soldier hits (not_attackable relies on it; cost of a false positive is limited to clearing a lone harmless unit)
 - Why bridge X25718 did not rise with the soldier gone (unit/item on it, jammed): GATE_FAIL no_effect now carries per-lever worker/dropped story
 - Pre-existing red baseline: pop cap 100 (e3c0c77) vs fixtures 55 makes 4 Lua suites and 13 pytest tests fail on 32994bb; not touched
 - FR-84 may collide with another package's FR number; BUG-111..114 rows sit after BUG-102 in bugs/README.md and will conflict with M1's 103-106 rows on merge (trivial)
LIVE
 - At the next lone intruder: dfllm status shows 'not counted as hostile (id:why)' (BUG-111) or, if soldiers stand beside a unit anyway, dump u.flags1/flags2, counters.unconscious and dfhack.units.isInvader/isVisitor/isMerchant/isDiplomat/isChild/isOpposedToLife of that id (read-only)
 - dfllm events --type SORTIE after a squad.sortie: does 'arrived' come, does 'dead' or 'abort not_attackable' follow; at 'go', 'arrived' and the abort read #squad.orders and #u.body.wounds of the target (read-only)
 - In a BREACH read the 'BREACH since N d: waiting for X up: <reason>; quiet clock: ...' line, kern.log MODE lines with why, and census.h.tick against the game tick (fresh <= 200)
 - For a bridge that stays down: the GATE_FAIL no_effect text (worker took the pulls vs DF dropped every job), units.isUnitInBox and items on the footprint (read-only)
 - alarm.by.sz / status 'size N' of the next lone intruder: if unreadable or > 20000 the harmless rules do not apply (add race to confine.harmless_races or raise harmless_size)
### bulk-m4-curse
UNCERTAIN
 - Announcement type name of 'has been cursed by' and of the transformation (kern routes by text so it is not needed; the CURSED/TRANSFORM event carries it in d.ann).
 - Whether a were-form changes unit.race (and its creature name contains 'were'), whether unit.curse.name/name_visible are set on the sheet before/after, whether DF counts the were-form as isCitizen, and whether a 'has transformed into a dwarf' text exists for the way back.
 - Moon phase: 13 cycles/year fits the Run 14 log (d155 d180 d206 d232 d258 = k*336/13 within a day) but the offset is an estimate until the first wave calibrates it (care.cur.mt).
 - Exact DFHack names read in inspect what=unit (personality.emotions[].thought, body.wounds[].bleeding, body.blood_count/blood_max, histfig_links); each is guarded and a miss is listed in d.unread.
 - A cured curse is not noticed; a hidden vampire is deliberately not read (fair play).
LIVE
 - At the first curse read d.ann of the CURSED event (the announcement type name) and the 'trig' text.
 - dfllm cmd inspect what=unit key=<id> on a cursed dwarf before and after the change: curse.name, curse.form, curse.tf, unread; read-only dfhack-run lua: dfhack.units.isCitizen(u,true), isDanger(u), isInvader(u), getRaceName(u) of a were-form unit.
 - After the first TRANSFORM wave: dfllm cmd inspect what=curse must say calibrated 1; CURSE_MOON must come 4 days before the next wave (compare mi with the real day).
 - status shows 'CURSED n (ids ..), k in were-form, next full moon ~dN (in M d)'; brief shows '## curse (recipe)' and 'stress level 0 (desperate): N units: id name ...'.
 - Check that a curse popup stays on screen (not cleared) and the game session is told by the wake line (CURSED is an interrupt: dfllm ack).
### bulk-m5-guide
UNCERTAIN
 - 86: why the 67 Run 14 drafts never passed plan check is not decidable offline; read-only data: the session's cli.log 'plan.check' lines or 'dfllm plan check' printed on the y707 draft
 - 86: whether the minimal plan passes check in a real stale fort (it is applied only if it does); PLAN_AUTO vs AUTO_FAIL after the second year decides
 - 91: whether Claude Code exports CLAUDE_PROJECT_DIR into the Bash tool shell; without it doctor takes the nearest .claude folder from the cwd up, so a shell that walked into the repo from a parent start folder looks active. Data: 'echo $CLAUDE_PROJECT_DIR; pwd' in the game session and <DF>/dfllm-runtime/hook.log
 - 95: that dfhack.gui.revealInDwarfmodeMap(pos, true) centres and changes level in DF 53.16; that df.global.window_x/y/z exist and are writable (needed for 'view' without target and for the player-moved test); that DF does not move window_x/y by itself (map-edge clamp would end a follow)
 - 85: the curse input reads M4's names (state curse, events CURSED/TRANSFORM/CURSE_MOON) and is inert on a kernel without them; the base state schema prunes the key, so the test injects it into the facts
 - base is not green (pop cap 100 vs baseline.lua DEFAULTS 55 and D-01 B): 13 pytest and 13 Lua failures exist before this package; left alone, another engineer or the orchestrator must fix them
LIVE
 - python -m dfpilot next in a quiet fort prints NEXT: nothing; with an open interrupt NEXT: dfllm ack; the same command 3 times in 30 min is not offered a 4th time
 - status line 1 in a fort whose plan.json is more than a year old shows PLAN STALE: applied yN, now yM; after 2 years follow wakes PLAN_AUTO (or AUTO_FAIL with the ERRORs)
 - from a session started in the parent folder: dfllm doctor says 'hook: not active in this session'; delete an unknown popup by hand and look for kern.log 'popup vanished without a kernel dismiss' and a POPUP_GONE event
 - dfllm cmd view target=<citizen id> in PEACE: map centres on him and takes his level; follow=true ttl_s=60 follows; scrolling ends it; bare 'dfllm cmd view' returns; the same in ALERT is refused
 - read-only: echo $CLAUDE_PROJECT_DIR; pwd in the game session, and whether df.global.window_x exists (dfhack-run lua is not allowed: use a selftest or the first view reply)
### bulk-m6-orders
UNCERTAIN
 - whether the live miners fetch a pick from a chest at all (tell repeats the note's rule of thumb)
 - whether care first lifts the Run 14 hospital stall if the picks are the cause (it lifts after 10 days by design)
 - cause of unit 39015's 49 days without cloth (needs kern.log/events of y707 d074-d123)
 - whether DF swaps a held metal weapon at once when the weapon spec changes to a training raw
 - whether a 1x1 Millstone/Quern inside a 3x3 cell and the 5x5 Kennels/Siege room place live; Millstone needs power which no template builds
 - R0 mood_ws may be loud for a fort that never built e.g. Jeweler/Mechanic (7 days, 20 citizens, off with mood_ws_days 0)
LIVE
 - During a hospital_out: kern.log 'care first:' lines, status line 'care first: <id> (hospital_out N) runs first', inspect projects rows 'paused: care <id>'; after 10 days without progress 'care first: ... made no progress' and state sched.care.stuck
 - At the next TOOL_BLOCKED read d.tell and d.care in events.jsonl (read-only: inspect workload key=tools records of the picks: forbid/owned flags, container, pool)
 - Remove or wait for a missing Loom in a fort of 20+ citizens past P1: after 7 days status shows R0 mood_ws with the bp.place command; run it and read that mood_ws goes
 - At the next strange mood without a workshop read MOOD_RISK.fix and the mood_workshop decision q
 - Read free cloth stock and WeaveCloth orders (economy state stock/orders) in a fort with 10-19 cloth: an order should aim at 20
 - dfllm cmd bp.place '{"tpl":"workshops","site":"S1","p":{"only":"Quern"}}' then bp preview; same for Siege (5x5)
 - dfllm cmd squad.uniform '{"squad":"A","kind":"training"}' on the test fort; read the answer's unchanged list, the squads screen weapon specs and the soldiers' inventories one game day later (read-only dump of squad positions' uniform.weapon item_subtype and unit inventory weapon ids); then economy orders dfllm:train_axe/sword/spear
### bulk-m7-platform
UNCERTAIN
 - Whether DF names an interrupted autosave '<name>_tmp' and leaves a world.sav inside it; whether complete saves hold world.dat (the companion rule is silent below 2 siblings)
 - Civzone enum name for the dump zone in DF 53.16-r3 (Dump or GarbageDump; both accepted) and quickfort zone key 'd'
 - Exact text of a 'Dump item' cancel and whether dfhack.job.getWorker tells a taken DumpItem job
 - Labels, pixel and click count of the 53.16-r3 title menu (unchanged from BUG-098)
 - Game time of a save is read from the perf.csv row at the save's mtime (approximate, unknown if no row within 20 min)
 - Pytest base had 13 pre-existing failures (commit e3c0c77 raised the pop cap to 100 without updating tests); not touched here
LIVE
 - At the title screen: python -m dfpilot supervise --saves (a _tmp folder shows NOT LOADABLE); dir listing of the save folder after an interrupted autosave (names, sizes, mtimes, is world.sav/world.dat inside?)
 - dfllm status and dfhack-run dfllm status at the title screen: the 'DF at title screen: no fort loaded' line
 - python -m dfpilot supervise --load --dry-run, then --load; if it fails read supervise.log 'title screen dump for ...' (viewscreens, rows, cells with tile, titlest fields) and python tools/embark/embark.py screen title53
 - dfllm doctor: load_save: broken (DFHack 53.16-r3) after the stock load-save failed once
 - Dump zone: read a dry spot away from stairs/doors, dfllm cmd zone.place type=dump bbox, then inspect what=items key=trash (zone reach/free, loose, waiting jobs), and the next CANCEL_LOOP of 'Dump item' (d.why, cancel_why holds the game's words); df.civzone_type names containing Dump
