# BUG-379 'pop 1' beside 'deaths unknown 67': the death census names no cause for a siege's dead
Status: fixed (offline, live-untested)
Severity: medium
Found: 2026-11-04, Run 16d (Plankscale, i4, `runs/run-16d/FR-BUGS.md` "FORT GEFALLEN y382"), kernel main ec9bd8e
Module: `lua/dfllm/care.lua` (classify, died_set, died_prune, death_recheck, pop_stress), `lua/dfllm/deaths.lua`, `dfpilot/brief.py`,
`dfpilot/schema.py` (DEATH `fight`)

## Actual
After the fall the brief read pop 1 and the year census `unknown 67`; the gamelog showed a slaughter. Events of the run: 71 DEATH
with cause unknown (`not found yet, missing in the unit list`), 55 killed, 15 bled; most unknowns were revised to killed later,
the last ones never (nobody was left to find the bodies).

## Root cause
1. care.lua `UNIT_DEATH`: `p.dlog` (the year's census, FR-74) got the cause of the FIRST answer; a death missing from the unit list
   is `unknown` then and `death_recheck` revised the DEATH event, never the dlog entry: killed units stayed `unknown 67` in
   `care.died_y` / the brief's `deaths in 365 d`.
2. `died_prune` kept 40 records (`while #out > 40`): a siege of 67 deaths dropped the oldest 27 before their bodies were found,
   they were never asked again.
3. A death unfound (or never found) in a fight had no word for it: `unknown` is also the label of a death nobody can explain.
Fair play stays (deaths.lua: no cause until the incident is discovered or a report names the unit): the cause is not guessed.

## Fix
- care.lua `classify`: an `unknown` cause in SIEGE / BREACH / RECOVERY carries `res.fight = mode`; DEATH gets `d.fight` (schema
  `fight:s`), the line reads `unknown, in a SIEGE (not found yet, ...)`, the record keeps `e.fl`.
- `deaths.key(e)`: `siege` for an unknown or pending record with `fl` (care.died season tally, DEATHS_3PLUS causes, clusters,
  `deaths.tally`, the year census `care.died_y`); the brief's `## deaths` groups DEATH events with cause unknown and `fight` as
  `siege N: ...` apart from `unknown`.
- The year census follows the revision: `death_recheck` writes the found cause into the unit's dlog entry (`u`).
- `died_prune`: 120 records, the found ones dropped first.

## Tests
tests/lua/test_care_deaths.lua (+3: siege naming and tallies, the year census revised, 60 missing kept and revised),
tests/test_bug377_379_defense.py (brief `siege 3: ...`). Fail on ec9bd8e.

## Live check
A siege with unfound dead: DEATH `died: unknown, in a SIEGE (...)`, DEATHS_3PLUS causes `<id>:siege`, brief `deaths ... siege N`,
`care.died_y` {siege = N}; after the bodies are found the DEATH revisions follow and the year census shows killed/bled.
