# BUG-088 The recruit list and the militia cohort take residents, whom the squads screen does not list
Status: fixed in the integration audit J1 commit (offline, live-untested): `military.recruits` and the rotation's pool
(`rot_pool`) take adult citizens only (`dfhack.units.isCitizen`); residents stay in the census and in every count
Severity: low (fair play: the kernel enlists a unit the squads screen offers no player; DF may refuse the add, which costs a
swap, a leaver gone and a month of passing the unit over)
Found: 2026-10-23, integration audit J1 (BUG-085's reasoning read with the FR-79 pool)
Module: `lua/dfllm/military.lua` (`M.recruits`, `M.rot_pool`), `lua/dfllm/sense.lua` (`scan_citizens`, read only)

## Actual
BUG-085 (audit I4) closed the `squad.add` verb to "living adult citizens" because the squads screen lists nothing else
(RULES 1.1: only what a player can do through the UI), and noted that "military's own fill ... only picks citizens". It does
not. `census.u.ids` is every sane citizen **and resident**: `sense.lua:120-127` reads `U.getCitizens(false, true)` (residents
included, Lua API.txt:1696) and counts `U.isCitizen(u) or U.isResident(u)`; RECALL names them (`/res`, a resident who is no
citizen, Run 11 siege 9). `M.recruits` (military.lua:461-475, the list for squads A and C, the leaders and the SIEGE refill)
and FR-79's `M.rot_pool` (:1334-1344) kept every `isAdult` unit of that list. A resident of the lowest unit id leads squad A
(ties in combat value go by id); the rotation ranks by served windows and then by id, so a resident is among the first
entrants of every cohort. `act.squad_add` is `dfhack.military.addToSquad`, which takes any unit with a figure (BUG-085).

## Cause
The census is deliberately wider than the citizens (residents live in the fort, count for the pop and the recall). The
recruit filter (WP6) predates the squad verbs of A4 and the rotation of D1, and nobody asked it the question BUG-085 asked of
the verb.

## Fix
`citizen(u)` (`dfhack.units.isCitizen`, guarded) in the adult filter of both lists; a resident is neither child nor
candidate. Nothing else reads the lists. `adults`, `soldiers` and every share in the census still include residents.

## Tests
`tests/lua/test_integration_j1.lua` (fails on c038ce9): 60 units whose three lowest ids are residents: no resident in
squad A, B or C at the start, none in the cohort after the turnover, and no `squad_add` of one.

## Not decided offline
- Whether DF refuses `addToSquad` for a resident (then the old code wasted a swap per resident entrant) or takes one.
- The same question for economy's work-detail candidates (they also read `census.u.ids`): not part of this audit.

Related: BUG-085, BUG-076, FR-79, BUG-035 (`/res`)
