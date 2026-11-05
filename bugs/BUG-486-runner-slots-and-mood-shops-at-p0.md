# BUG-486 many projects "set aside, no runner slot" with idle hands; mood shops 45 days late
Status: fixed (offline, live-untested)
Severity: high (Trumpetrealms y373-y375: dining 478 d, tavern, temple, hospital, bedrooms 'set aside (no progress), no runner slot (the others go first)', 15 of 16 adults idle; 'mood shops missing 45 days: Jewelers,MetalsmithsForge,Bowyers +5')
Found: 2026-11-05, Run 16d i4 Trumpetrealms (FR-BUGS "Projekt-Durchsatz", "Mood-Werkstaetten kamen erst nach 45 d")
Module: `lua/dfllm/runner.lua` (`M.CFG.slots_*`, `Q.slot_cap`, `begin_run`), `lua/dfllm/economy.lua` (`idle_free`, `mood_shops`), `lua/dfllm/care.lua` (`mood_emergency`, `ws_fix`), `dfpilot/fairplay.py` (`RUNNER_LIM`)

## Actual
(a) The runner worked on `M.CFG.active` = 3 projects at once whatever the fort looked like; every other project queued ('queued behind ...'), made no progress of its own and, after `queue.idle_days`, was set aside. 15 idle adults and 2-3 digs.
(b) A Secretive mood (MOOD_RISK #797, phase P0, pop 20) asked for no workshop: `economy.mood_shops` answers only from `mood_from_phase` (P1) on, so care's typed `PROJECT_REQUEST workshops why=mood` never came, and the plan's P1 waited for the very workshops.

## Root cause
(a) runner.lua begin_run: `n < M.CFG.active`. (b) economy.lua `M.mood_shops`: `phase_ok(K, 'P1')` -> nil -> care.lua `mood_emergency` `typed` false -> no ask; with a dwarf whose skill names no shop type (`M.SKILL_WS[skill]` nil) the typed list was empty even when the answer existed.

## Fix
(a) `Q.slot_cap(K, c)`: slots = active (3) + free idle adults (`economy.idle_free`, the daily scan: no job, not resting / hurt / in a mood) // `slots_idle` (3) + adults // `slots_pop` (40), at most `slots_max` (8), never below 3; no economy answer or `slots_idle` 0 keeps 3. Same loop, same order (seal first, care, mood, then plan order / prio); only more projects run at once. config `runner.queue` `slots_idle` (0-50), `slots_pop` (1-250), `slots_max` (1-20) (`fairplay.RUNNER_LIM`, CONTRACTS.md), kern.log `runner slots N (active 3 + F free idle adults of A)`.
(b) `economy.mood_shops(K, true)` answers at any phase (care passes `true`: a strange mood is in the fort); the readiness blocker keeps the phase gate. `care.mood_emergency`: no workshop claimed, no skill shop named -> the first `MOOD_ASK_MAX` (3) missing moodable shops are asked at once (`PROJECT_REQUEST workshops why=mood types`, prio 1, follow places them in the current season), not at next year's plan.

## Tests
`tests/lua/test_bug486_slots_moods.lua` (5: slots 6 for 9 idle of 16, 3 without economy / idle hands, slots_max cap, `idle_free` after the daily scan, `mood_shops(K, true)` at P0 with an applied plan, the three-shop request of a mood with no shop); `tests/lua/test_runner.lua` 'at most 3 projects' unchanged.

## Live check
Trumpetrealms-like fort (15 idle of 16): kern.log `runner slots 6 ...`, the queue rows 'queued behind' shrink, fewer 'set aside'; a mood at P0 without a shop: PROJECT_REQUEST workshops why=mood with types and a workshops project at prio 1 the same day.
Open: slots are about projects, not miners: the number of Miners on the work detail (12 unclaimed Dig jobs, 4 picks) is the economy's cover rule, unchanged; a larger `slots_max` is the player's config.
