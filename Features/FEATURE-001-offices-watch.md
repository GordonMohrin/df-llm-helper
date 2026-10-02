# FEATURE-001: `offices` watch - are the fortress offices filled by someone who can do the job?

- **Status:** proposed
- **Priority:** P1 (a missing broker cost a caravan trade, a dead captain of the guard went unnoticed through a whole siege)
- **Requested by:** Gordon (player), 2026-10-02, via the local orchestrator
- **Area:** new `df_llm_helper offices` (+ Lua `lua/pilot_offices.lua`), digest/wake integration, trade flow precheck

## Problem
Nothing in the project checks periodically whether the important positions (nobles menu) are filled and whether the holder can actually work.
Only fragments exist: `watchdog.lua` checks that the broker stands at the depot, `orders.lua` assumes a manager exists, `claude/aemter` fills positions on command.

Incidents (Run 5, year 120-121):
1. **Missing broker:** the old broker (Adil) died, the office was held by the mayor who then was in a strange mood; the trade automaton found no available broker and the Muboomon caravan was missed.
2. **Dead holders everywhere after the siege:** `CAPTAIN_OF_THE_GUARD`, `MILITIA_COMMANDER`, `CHIEF_MEDICAL_DWARF` were assigned to dead units (the assignment still lists the dead histfig), `MANAGER`, `BOOKKEEPER`, `BROKER` were empty. Nobody noticed; the player had to ask "who checks the offices?".
3. The new broker pick (4193) later turned out to be a high-stress dwarf; offices should avoid dwarves that are about to snap.

## Proposed behaviour
`python -m df_llm_helper offices [--apply]` (read-only without `--apply`):
1. Read positions and assignments (`entity.positions.own`, `positions.assignments`, `histfig2` -> unit) in one Lua call (`pilot_offices status`, JSON).
2. Per mandatory office (config `offices.required`, default: MANAGER, BOOKKEEPER, BROKER, CAPTAIN_OF_THE_GUARD, MILITIA_COMMANDER, CHIEF_MEDICAL_DWARF; MAYOR when the fort has one) decide:
   - `ok`: holder alive, adult, not in a mood, stress below limit, not seriously wounded, (broker) reachable depot, (captain/commander) is a soldier or a squad leader;
   - `empty`: nobody assigned;
   - `dead`: assignment points to a dead unit;
   - `unfit`: alive but unsuitable (reason: mood / child / stress / wounded / prisoner).
3. Suggest a successor per office with a score: skill for the job (MANAGER/BOOKKEEPER: no heavy labor, BROKER: appraisal/negotiation skills, CAPTAIN: leadership/fighting), not drafted into a squad on duty, not injured, low stress, not a hospital caretaker while patients exist.
4. Output in the digest: `Offices: 6/6 filled` or `OFFICES: BROKER dead (Adil), MANAGER empty -> suggest 4621 Kol (Mechanic)`; emit one wake line per state change (not every cycle).
5. `--apply`: only with an entry in the exception register (assigning a position is a nobles-menu action, no fair-play issue, but it changes the fort): call the existing `claude/aemter vacate/assign`; log old state (the Lua already writes `tools/out/aemter-log.json`).
6. **Trade flow precheck:** before `PAUSE` the trade automaton asks `offices` for BROKER state; if not `ok` it fails early with a clear message instead of timing out later (see BUG-221/222).
7. Optional repeat job (`offices watch`, every ~1200 ticks) with the same state-change rule.

## Data needed from the game
`claude/aemter status` already returns positions, holders, index fields. Extra needed for fitness: unit alive flag, `mood`, `body.wounds` count, stress (`status.current_soul.personality.stress`), `military.squad_id`, `profession`, skills (appraiser, negotiator, leader). One new Lua entry point is enough; no new write path.

## Safety / fair play
Reading is free. Writing = existing `aemter` functions only (the same thing the nobles menu does), logged. Never assign a unit that is in a mood or hospitalized. No item or unit manipulation.

## Acceptance criteria (fixture based)
1. Fixture "siege aftermath": all six holders dead or empty -> `offices` prints 6 problems, suggests six distinct living adults, none of them wounded or in a mood.
2. Fixture "broker in mood": holder alive but `mood >= 0` -> state `unfit (mood)`, suggestion = next best trader.
3. Fixture "all ok" -> `Offices: 6/6 filled`, exit 0, no wake line on the second run.
4. The trade automaton with the "broker dead" fixture fails at `IDLE -> PAUSE` with the offices message and does not write `pause.hold`.
5. State change `ok -> dead` produces exactly one wake line (event dedup).
6. Pure Python test for the scoring function (skills, stress, wounds, squad membership).

## Info needed
- Recorded answer of `claude/aemter status` and a unit dump (mood, wounds, stress, skills) from the live game: the local orchestrator can supply `Bugs/evidence`-style files on request.
- Decision: should the captain of the guard be a mandatory office (the player says yes: "king of the guard is important")?

## Nachtrag 2026-10-03
After the second attack the militia commander and the chief medical dwarf were dead again (assignment points to a dead histfig). Reassigning via `claude/aemter vacate` + `assign` worked live. `offices --apply` should use exactly this sequence for dead holders.
