# Triage of the Run 11-14 backlog (bulk handover, 2026-10-23)

Source: `bugs/RUN11-offene-bugs-und-FR.md` (65 notes of the game session, runs 11-14) and
`docs/v2/POSTMORTEM-run13-wheelsblows-y525.md`. Decisions: `docs/v2/DECISIONS.md` section "Decided by the development
session (2026-10-23)". Numbers below are reserved for the packages; an unused number stays unused.

Rule for every package: tests first (each new test fails on the base commit), fair play (RULES §1.1: only what a player
can do in the UI; reading state is fine; no unit/item edits, no createitem/dig-now/reveal/hidden tiles), the gate
(`pytest`, `luahost`, `lint lua/dfllm`, `lint --config`, RULES.md <= 300 lines), a bug file per number, a CHANGELOG entry
with "Why / What changed / Live check".

## Packages

| Pkg | Wave | Theme | Bug / FR numbers | Notes |
|---|---|---|---|---|
| A1 seal-door | A | the seal door that never gets built, designations lost, project parts blocking each other | BUG-044 .. BUG-047 | 8, 16, 21, 22, 23 (door part), 32, 47 |
| A2 perimeter | A | bridges and gates lost for good, escalation at an open entrance, refuge integrity | BUG-048, BUG-049, FR-70 | 13, 17, 20, 23, 26, 43 (rebuild part), Run 13 causes 1 and 3 |
| A3 military | A | uniform-unstick strips armor, militia rotation, drill gate, soldiers not on station, loose tools | BUG-050 .. BUG-053, FR-71 | 2, 19, 34, 53, 64 (rotation), 23 (on_station=0), Run 13 cause 2 |
| A4 health | A | patients dying of thirst, vacant offices, appoint verbs, abandoned hospital locations, the civzone build verb | BUG-054 .. BUG-056, FR-78 | 11, 18, 24, 25, 61, 64 (verb registry), 65 |
| B1 labor | B | empty or reset work details, farming slots, misleading messages, labor coverage | BUG-057 .. BUG-059, FR-72 | 3, 6, 33, 35, 36, 37, 38, 44, 46, 54 (details), 62, 63 |
| B2 orders | B | stale stone-door orders, EngraveSlab jam, autoslab restock, cloth and thread orders | BUG-060, BUG-061, FR-73 | 42, 45, 56 (slabs), 60, 10 |
| B3 care | B | tomb zones closed for citizens, ghosts, mood deaths, toppled-by reports, stress | BUG-062 .. BUG-064, FR-74 | 12, 14, 15, 48, 52, 55, 56 (reporting), 58 |
| C1 alarm | C | harmless intruders and endless confinement, civ_alert re-asserted, popups | BUG-065, FR-75 | 40, 49, 50, 54 (alarm part), 57 |
| C2 reclaim | C | reclaimed forts, manifest hygiene, plan/follow ordering, repeated lever pulls | FR-76, BUG-066 .. BUG-068 | 5, 28, 29, 30, 31, 41, 51, 59 |
| C3 platform | C | quicksave, frame freezes, status gaps, idle breakdown | BUG-069 .. BUG-071, FR-77 | 1, 4, 7, 39 |
| C4 decided | C | one stockpile per quickfort place, wet wells only, reachable gather zone, seal-first fault event | BUG-072 .. BUG-075 | decisions 6, 7, 10, 11 |

## Every note, where it goes

| Note | Topic | Package | Status |
|---|---|---|---|
| 1 | frame freezes, quicksave 54-110 s | C3 | BUG-070 |
| 2 | drill refused while merchants stand on the map | A3 | BUG-051 |
| 3 | farms projects requested again after build_lost | B1 | BUG-058 (decision 9) |
| 4 | status without pop/stock lines after a year change | C3 | BUG-071 |
| 5 | plan check "explore: only 0 free sites", depth 12 always refused | C2 | BUG-067 |
| 6 | GatherPlants 250-450 unclaimed for years | B1 | FR-72 (decision 10) |
| 7 | idle line contradictory, no breakdown | C3 | FR-77 |
| 8 | plan check "seal: nothing to close" for a finished refuge seal | A1 | BUG-047 |
| 9 | fishery destroyed and not replaced | done | BUG-038/042 (stale follow), live check pending |
| 10 | brew orders missing; does the office need more furniture | B2 | BUG-042 done; answer in B2 notes |
| 11 | hospital locations stay after the zones are deleted | A4 | BUG-056 |
| 12 | stress 52-78 % with no countermeasure | B3 | FR-74 |
| 13 | destroyed outer gate (O1 14 times), bridge_rebuild never answered | A2 | BUG-048 (decision 3) |
| 14 | mood deaths by thirst/hunger | B3 | BUG-063 |
| 15 | population falling in peace, no migrants | B3 | FR-74 (diagnosis) |
| 16 | seal door 115,73,143 stays open | A1 | BUG-044 |
| 17 | siege 13: 36 lost, sealed 0 ticks, bridges and levers lost for years | A2 | FR-70 |
| 18 | patient_thirst although water, buckets and caregivers exist | A4 | BUG-054 |
| 19 | TOOL_BLOCKED Miners: 16 loose picks | A3 | BUG-053 |
| 20 | PERIMETER_BROKEN requeued=0 | A2 | BUG-048 |
| 21, 22 | seal door job suspended again and again | A1 | BUG-044 |
| 23 | siege 14: 24 lost, on_station=0, two entrances open | A1 / A2 / A3 | BUG-044, FR-70, BUG-052 |
| 24 | five patients dead of thirst at once, pop 1 | A4 | BUG-054 |
| 25 | no militia commander, appoint not a verb | A4 | BUG-055 |
| 26 | run summary run 11 | A2 | FR-70 |
| 27 | tutorial crash, reclaim tooling | game repo | not dfpilot: the player's embark tools (`dwarf-fortress-llm/tools`) |
| 28 | reclaim: lever pulled 6x per second, ACT_FAIL | C2 | BUG-068 |
| 29 | reclaim: 13386 items forbidden | C2 | FR-76 |
| 30, 31 | reclaim: fortcore site damp, no site after abort, stage marked done without predecessor | C2 | FR-76, BUG-067 |
| 32 | a stalled forge blocks the kitchen of the same project | A1 | BUG-046 |
| 33, 35, 36 | PlantSeeds unclaimed, farmers missing, PLANT labor by hand | B1 | BUG-057 |
| 34 | idle 74 %, loose picks again | A3 / B1 | BUG-053, BUG-057 |
| 37 | starvation although "food 41 d" (meals 0) | B1 | BUG-059 |
| 38 | no herbalist labor | B1 | FR-72 |
| 39 | QUICKSAVE_FAILED | C3 | BUG-069 |
| 40, 50 | popup pause every ~15 min | C1 | FR-75 |
| 41 | plan draft after bp.place(fortcore): 0 free sites | C2 | BUG-067 |
| 42 | stone door orders without jobs | B2 | BUG-060 |
| 43 | bridges vanish in peace | A2 / B3 | BUG-048, BUG-064 |
| 44 | farm slots empty, autofarm, underground crops | B1 | BUG-058 |
| 45 | 31 EngraveSlab orders jam all stone work | B2 | BUG-061 |
| 46 | Planters/Fisherdwarves details empty | B1 | BUG-057 |
| 47 | stair designation lost after an alert | A1 | BUG-045 |
| 48, 52 | tomb zones `no_citizens=true` | B3 | BUG-062 |
| 49 | endless lockdown for a gremlin in the caves | C1 | BUG-065 (decision 12) |
| 51 | unretire: workshops missing | C2 | FR-76 |
| 53 | uniform-unstick `--drop` strips armor | A3 | BUG-050 |
| 54 | Planters detail reset to 6; timestream 10 FPS and civ_alert after a gremlin alarm | B1 / C1 | BUG-057, BUG-065 |
| 55 | "toppled by" reports: tantrums and ghosts destroy buildings | B3 | BUG-064 |
| 56 | ghosts: no memorial slab, corpse in another walk group | B2 / B3 | BUG-061, BUG-062 |
| 57 | civ_alert re-asserted every round | C1 | BUG-065 |
| 58 | mood dwarf noticed too late | B3 | BUG-063 |
| 59 | destroyed forge stays in the manifest | C2 | BUG-066 |
| 60 | cloth and thread orders only after a mood | B2 | FR-73 |
| 61 | Chief Medical Dwarf vacant, no readiness check, `appoint` not a verb | A4 | BUG-055 |
| 62 | "no Farmers" means no Farmer's Workshop | B1 | BUG-059 |
| 63 | labormanager is not the cause of the Planters reset; Fisherdwarves and gatherers at 0 | B1 | BUG-057 |
| 64 | militia rotation: one window, one squad; squad verbs not registered | A3 / A4 | FR-71, BUG-055 |
| 65 | no verb or template for civzones (pen/pasture, pit/pond, collection zones, fishing area, meeting hall), `bp sites` cannot take a position | A4 | FR-78 |

## Decisions that shape the packages
See `docs/v2/DECISIONS.md`, section "Decided by the development session (2026-10-23)": 1 stage 3 before P3, 2 auto-seal
and `--no-auto`, 3 perimeter and bridge_rebuild, 4 seal-first and explore, 5 recall, 6 wet wells only, 7 one food
stockpile per place call, 8 no cavern water, 9 parked projects and farms, 10 gather zone, 11 seal-first fault event,
12 lone thieves and confinement, 13 popups, 14 loose tools, 15 mood dwarves, 16 population.

## Status after the first pass (2026-10-23, main 724fa33)
All eleven packages are merged, each reviewed by a second engineer and gated (pytest, Lua suites, lint, config, RULES 300
lines). Everything is "offline, live-untested": each bug file names its live checks. Notes that are only partly closed:

| Note | What is still open | Where it goes |
|---|---|---|
| 23 | the recall part of siege 14 (BUG-035 is live-untested for it) and the cause of on_station=0 (diagnostics only, BUG-052) | live data |
| 25 | the militia commander is not appointed by the kernel (it would orphan the vacant assignment squad creation needs); the verbs `appoint`, `squad.create`, `squad.leader` exist | BUG-055 |
| 26 | metal-gear causes beyond the unstick (too little metal, no armor orders) | BUG-050 follow-up, FR-71 |
| 30, 31 | no memory of a failed fortcore site (breach:damp); rooms other than workshops are only counted in `adopt` | FR-76 follow-up |
| 34 | loose picks on another walk group are not fixed (the tool pile skips them) | BUG-053 |
| 43 | the culprit is named (BUG-064), the rebuild text of the keeper does not read it | BUG-048 |
| 52 | who closes an opened tomb zone again 90 s later (TOMBS_LOCKED answers it live) | BUG-062 |
| 54 | who removed 22 hand-added Planters members (the audit line answers it live); the 10 FPS clamp after a gremlin alarm | BUG-057, BUG-065 |
| 64 | member turnover per militia window (squad_remove/add drops the kit) | FR-71 follow-up |
| 69 (game session, later) | autoslab makes no EngraveSlab orders although ghosts and free slabs exist | BUG-061 follow-up |
