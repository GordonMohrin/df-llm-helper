## A. Gaps: areas the 8 analysts did not cover, or covered too thinly
1. The input was cut off. Slice 5 (orchestration) stops in the middle of the runde.py entry, and slices 6-8 never reached me. I could not judge them; military, economy and happiness may be covered there.
2. Military and defense code was only touched from the side: siege.lua, killorder, militaerwacht, ausruestung, the alarm burrow and squad and uniform setup. Nobody showed why the elite was used up in B8/B9 or how its replacement was meant to work.
3. Happiness and needs got no real analysis. The stress and needs distribution, the thoughts and petition logs and what actually makes dwarves happy in 53.x were not examined; only the log sizes were. The idea of "KPI = stress/needs" is untested.
4. Starting a new fort in the same world was not analysed: tools/embark/*.sh, RUN6-START, site selection. Nobody looked at how much invasion pressure the world now carries after 5 dead forts (around year 212 and later), or at whether earlier sites or ghosts matter.
5. Nobody profiled DF itself. Pathing, temperature, weather, item and unit counts, d_init settings and the FPS cap were never measured. The cause of the stalls is unproven, and there are competing hypotheses: aufsicht every 30 s, arbeit/orders every 1500 frames, CoreSuspend contention from about 1.5 dfhack-run spawns per second, quicksave, Lua garbage collection or heap growth. No callback was ever timed in-game.
6. There is no fair-play audit of repo B (161 scripts). Open points: direct writes to pickup_flags and cur_routine_idx, trade.goodflag plus simulated clicks, reads of water_table on hidden tiles for site and gate decisions, whether gefahr also scans enemies that are not visible, and whether timestream itself counts as fair play.
7. The LLM and harness side is only partly covered. Nobody explained why each turn carries about 0.5 M tokens: CLAUDE.md, the MEMORY index, sessions that are never reset, cost of the Monitor and Cron wake-ups. Model and effort choice was not looked at.
8. The DFHack natives were proposed but never tested for fit. Open questions: does autofarm conflict with the rule against cooking plump helmets, does logistics auto-trade work, does idle-crafting meet needs. Plugin enable state is stored per save and was never checked against the Run 6 save, so claims like "autobutcher was off" rest on ERFAHRUNGEN only.
9. "Wealth raises siege size" and "DF auto-assigns bedrooms well enough" are both stated without measurement.

## B. Contradictions and unverified claims
- The persistent RPC idea contradicts the main diagnosis. A CoreRunCommand over :5000 still suspends the core, so it removes the process-spawn cost but not the main-thread contention. Only an in-game file push gets rid of both.
- The stall numbers are two different measurements. stall.log gives 2,076 vs 2,039 rows (read at different times) and a stall period of 33 s. FLAG_PERF reports a "period 7-26 s". The attribution to aufsicht (30 s) or to arbeit (1500 frames) is unresolved.
- Context per turn is quoted as 373-549k, ~519k and ~700k (the last from a Run 5 docstring). Use about 0.5 M.
- The verdicts disagree between slices:
  - freeze_guard: replace (slice 1) vs keep (slice 2)
  - schmuckwelle: cut (slice 3) vs keep (slice 4)
  - arbeitswacht: cut (slice 3) vs rework as the seed of the project runner (slice 4)
- Slice 4 proposes dropping the dig chunk gate because "it never fired". That conflicts with the diagonal-water flood lesson in memory. Keep a cheap breach stop.
- "Idle % is the wrong KPI" conflicts with Gordon's memory rules ("Idle >40 % -> act", "idle workers get new jobs at once"). Gordon asked to question all decisions, but this one is his, so it needs his explicit decision.
- Native tools: automelt, autodump and preserve-tombs exist as plugins, not as scripts. suspendmanager and timestream are plugins too. The analysts' native list is therefore valid, but some of their tool names point to the wrong place.
- config.lua:267 says "TARGET 500 = calendar ~2x", but TIMESTREAM_FPS is 200. What the target actually means is unclear.
- CLAUDE.md says to commit as Claude and push only on Gordon's word. Memory says the author is Gordon with Co-Authored-By, and always push. Memory wins.

## C. Spot-checks (read against the files)
1. TRUE: df_llm_helper/config.py:35 has `"transport": {"batch": False ...}` with the comment "only after a live test".
2. TRUE: supervisor.py:247-256 deletes any pause.hold older than HOLD_MAX_S and runs `claude/advance run`. The only exception is handel_aktiv; there is no siege_aktiv check. Step 4 (line 261) does check civ_alarm and feinde_nah, but step 3 does not.
3. TRUE: config.lua:257-305 has ALERT_RANGE=4 and FORT_BOX=FORT_X±ALERT_RANGE (a 9x9 column), NORMAL_FPS 100, TIMESTREAM_FPS 200, TIMESTREAM_CALM_S 8 and TIMESTREAM=true.
4. TRUE: grep finds "eventful" 0 times in lua/claude, although the eventful plugin is installed.
5. TRUE: killorder.lua:79 has `ALTFORT_Z = 127` with the comment "Altfort z127..133" (the Run 5 layout), and line 89 uses it to decide what counts as "inner".
6. TRUE: dfhack-config/control-panel.json has `commands: []`, and onMapLoad.init only runs `claude/tempo load` and `claude/wachen load`.
   - Installed plugins: autobutcher, autochop, autofarm, autonestbox, autoslab, automelt, autodump, logistics, preserve-rooms, preserve-tombs, suspendmanager, tailor, timestream, eventful, spectate, dwarfvet, cleanowned.
   - Installed scripts: idle-crafting, autofish, autotraining, pop-control, warn-stranded, combine, lever, quicksave.
   - hack/data/orders holds 7 order JSONs.
7. TRUE: training.lua:7 and :55 put non-elite squads on routine 0 (Off duty, civilian clothes) outside their training months.
8. TRUE: exceptions.local.jsonl has 14 entries with `action` FP10..FP20. fairplay.py:42-47 defines FP10 as teleport, FP11 as uncovering hidden tiles, FP12 as writing work_weapons, FP13 as changing the owner and FP14 as the bin planner, so the ids collide. The register also contains fastdwarf (FP17/19/20), a forced caravan (FP12) and a caravan time extension (FP18).
9. PARTLY TRUE: gefahr.lua:23 and :82-90 call `C()` (a reqscript) in captive(). But excluded() checks isCitizen and isTame first, so the cost is per non-citizen, non-tame unit (invaders, wildlife, visitors), not per unit in general.
10. TRUE: aufsicht.lua:13 has PERIOD_S = 30. tools/out/supervisor.log has 36 lines with ModuleNotFoundError or "aufgegeben". Repo B CLAUDE.md is stale: "Stand 01.10. Run 5", `cd dfpilot && python -m dfpilot check`, deadman 20 min, unpause-guard.ps1.

## D. State of the system (consolidated)
ARCHITECTURE AS-IS
- In-game: DF 53.16 with DFHack, repo B lua/ first in script-paths. onMapLoad starts tempo plus wachen: 39 repeat-util jobs (22.5k lines) and aufsicht every 30 s, which restarts 35 of them. No eventful hooks, no native automation, the orders library is unused.
- External: the df_llm_helper waechter (2 s loop, about 3 dfhack-run spawns per pass, its own guard, deadman and tempo governor). supervisor.py runs as a Windows task every minute (restarts, hold deletion plus advance run, deadman, backups). runde.py --follow runs under a Monitor, plus a 15-min goal tick. The .ps1 scripts are referenced only by docs.
- LLM: one Opus orchestrator with about 0.5 M context per turn, plus Sonnet and Opus subagents. The helper's check/digest/wake path has not run since 10-07; in Run 6 only the waechter ran.
- State is split: 2 flag folders, state.db, ereignisse.jsonl, per-job JSON (some invalid because of decimal commas), 3 Lua copies, 2 Python packages, contradictory docs. Fair play is checked only on the helper path; about 36k direct dfhack-run calls bypass it.

TOP 15 PAIN POINTS (ranked by impact on: play fast, achieve a lot, survive)
1. Defense collapses on contact: reserve Off duty, 0 % of gear worn in B10, single stair SZ1 behind the trap corridor with the refuge below it. The metrics measured the best case (bridge raised, gear assigned instead of worn) and were green 11 min before the wipe.
2. Growth is not tied to readiness: the pop gate was removed on 09.10 at 22:00, the beauty projects ran through 5 sieges (29 to 149 goblins), pop reached 90.
3. Pause, tempo and civ alert are fought over: at least 6 actors pause and at least 5 unpause. The supervisor forced `advance run` in B8, B9 and B10. Timestream came back on 10 s after the siege arrival. An early alarm-off was followed by 3 deaths. Siege start came 30 s after arrival, while the first enemy needed only 22 s.
4. The main thread stalls every ~20-35 s for 3-85 s: about 2,000 calls over 3 s, 712 of 10 s or more, 149 timeouts. The cause is unproven. The stalls slow the game and blind every external control.
5. The session degrades: the quicksave freeze grew from 13 s to 61 s and the calendar rate fell from 236 to about 90 ticks/s until DF was restarted. 109 Lua quicksaves averaged a 31 s freeze.
6. Heavy Lua work is redundant: about 30 full items.all scans per minute, buildings.all walks over 12k entries, reqscript inside per-unit loops, project watchers spiking to 883 and 159 ms and never deregistered.
7. Native automation is unused and reimplemented in Lua, and the copies fight each other: 988 bronze bin orders created and deleted in Run 6.
8. LLM cost is dominated by context: about 74 M input tokens per hour, about 42 M cache-read and 131 turns per building. The helper saves tokens in its output (median 391), which is about 0.08 % of one turn.
9. The control cadence is far slower than the game: a 5-min check is about 50 game days, a caravan is visible for about 15 s, and caravan events were missed (BUG-435).
10. State is split: stale flags caused 41 % idle, 6 of 7 dwarves idle and a permanent danger state. 27 of 56 Lua copies differ, and mil.lua runs a stale killorder copy.
11. Events flood in without owners: 6,180 in 46 h. FALLE_MONSTER_OFFEN fired 592 times, and those caged goblins were free in B10. The regex "goblin" tagged a masterpiece figurine as CRITICAL.
12. The building pipeline is bespoke per project: 8 watchers with 7.4k lines, 15 generators, absolute coordinates, the unsuspend bug still in 4 copies. None of it carries over to Run 7.
13. There are 3 deadman systems with different liveness rules. fps was held at 30 for 14.7 h, and the DF restart chain is broken by an import error.
14. The helper is large and untested live: 23k Python lines, 15 files marked NOT TESTED LIVE, 954 mock tests against Run-5 fixtures, batching off.
15. Knowledge cannot be used: ERFAHRUNGEN.md is 854 KB, CLAUDE.md is stale, and the fair-play register is corrupt and legitimises cheats.

TOP 15 DECISIONS TO DOUBT
1. Controlling the game through one dfhack-run process per query, with a 2 s external poller.
2. Using the LLM as a real-time controller (5-min checks, a wake per event) instead of a once-per-season planner.
3. Many owners for pause, tempo and alert, coordinated through text-file holds and file-age heuristics.
4. A tempo governor that brakes on harmless states while growth stays ungated, with an 8 s calm window.
5. Reserve squads Off duty on a training calendar, and readiness counted as assigned gear rather than worn gear.
6. Beauty projects running always, regardless of defense state, and engraving everything (wealth).
7. One Opus agent plus a bespoke 1000-line watcher per building.
8. Lua copies of work orders and automation, based on distrust from single early incidents.
9. Idle % as the main economy KPI, which pumps filler digging and creates boulders.
10. 39 independent jobs plus a watcher of the watchers, with four mixed time bases.
11. Polling for events DF already announces (eventful is installed but unused).
12. Lua quicksaves every 15-30 min.
13. Two flag folders, absolute paths, and hardcoded IDs and coordinates (Run-5 relics included).
14. A separate "public" repo A with copied Lua, and feature-per-bug growth tested against mocks.
15. Fair play enforced only in the helper client, standing cheat exceptions, and reads of hidden water_table tiles.

TOP 15 IDEAS
1. One in-game kernel: a single scheduler with a ≤2 ms/frame budget, a shared census (units, items.other, buildings.other) and per-module ms published in the heartbeat.
2. eventful hooks (INVASION, REPORT, UNIT_DEATH, UNIT_NEW_ACTIVE, BUILDING, ITEM_CREATED) that write typed events.jsonl and state.json. Python then only reads files: 0 RPC calls per check.
3. An actuator arbiter with leases and priorities (siege > mood > trade > economy) for pause, tempo, civ alert, squads and bridges. Nobody else writes these.
4. A siege reflex in the same tick: gates and bridges after a check for citizens outside, all squads Ready in uniform, civ alert on, a timestream lock of at least 10 min, the siege protocol started automatically.
5. A readiness score that gates pop cap, migrants and wealth projects: worn % after a 60 s drill, soldiers ready, a worst-case path audit, a refuge away from the enemy path.
6. At least 2 squads always Ready in worn uniform, using DF's native squad schedules.
7. A new-fort baseline: `orders import` of library basic, furnace, smelting and military, and enable suspendmanager, autochop, autobutcher, autonestbox, autofish, autoslab, tailor, logistics/automelt, preserve-rooms and preserve-tombs, idle-crafting, autodump and cleanowned.
8. A template library plus a site finder plus one generic project runner (quickfort labels, `quickfort orders`, suspendmanager, deregistration at 100 %). The LLM then spends 3-5 turns per building.
9. A compact core layout: at least 2 separate stairs, the hub within ±2-3 z, the refuge off the enemy path, a civilian stair that can be sealed.
10. A plan file per season written by the LLM (build queue, labor and production targets, military posture, trade wants, pop cap) that in-game executors reconcile continuously.
11. A wake budget (typed critical classes, at most N wakes per hour, payload of at most 150 tokens), fresh short sessions, and one RULES.md of at most 300 lines as the only always-read doc.
12. One repo, one Lua source, one runtime folder, one state document. Delete hack/scripts/claude, repo B dfpilot/ and the repo A Lua copies, and rewrite CLAUDE.md.
13. Fair play at the shell boundary (a PreToolUse hook plus a pre-commit lint), a cleaned exception register with no cheat consents, and no hidden-tile reads.
14. Speed KPIs (ticks/s, stall ms per minute, pause owner). Restart DF automatically when the save freeze exceeds 20 s or the calendar rate drops below 60 % of its baseline. Use DF's own autosave instead of Lua quicksaves.
15. Shrink the helper to a sensor reader, digest, wake, lint, planners and metrics. Add an owner for every event type, a routine that moves caged invaders out, and in-game cancel-loop detection.

KEY NUMBERS
- Calendar speed: median 197 ticks/s (deciles 77-256); 68 game years in ~46 h. Run 6 fell from 89 to 0 citizens in ~16 min against ~149 goblins; the first enemy needed 22 s, siege start came after 30 s.
- check: 17-26 dfhack-run calls, median 2.99 s, max 31.5 s. waechter: about 4,300 spawns per hour. stall.log: about 2,000 calls over 3 s, 149 timeouts, max 84.5 s.
- Lua: 161 scripts with 52k lines, 39 jobs, 8 building watchers with 7.4k lines. Python helper: 23k lines, of which about 64 % is cuttable.
- LLM: ~0.5 M tokens per main turn, 333 M cache-read for 8 buildings, 6,180 events in Run 6, 109 quicksaves (mean freeze 30.7 s).