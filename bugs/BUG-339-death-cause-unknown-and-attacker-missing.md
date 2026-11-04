# BUG-339 deaths "unknown" in DEATHS_3PLUS although DF had shown them; bled deaths without the attacker
Status: fixed (offline, live-untested)
Severity: high
Found: 2026-11-04, Run 15c (Inkintense y379 sum d64-67, i1 r15c-inkintense-site97)
Module: `lua/dfllm/care.lua` (UNIT_DEATH, death_recheck), `lua/dfllm/deaths.lua` (classify)

## Actual
11 DEATH `unknown (not found yet, missing in the unit list)` (#2929-#3016, ticks 152989557-152992530), DEATHS_3PLUS #2995
`3 citizens died within a day: unknown 3`. gamelog shows `..., Farmer has been found dead.` for the first victims right after
the attack started, but every revision came in one batch at tick 152994878 (#3030-#3039), 5300 ticks after the first death:
6 `killed by cave dragon 26704` / goblin, 5 `bled (incident BLEED ...)` with no attacker, although all five died at
84-87,70-72,131 under the dragon.

Root cause:
- `lua/dfllm/care.lua:4278` (finish): death_recheck runs only when care's full run has finished, which takes days in a siege;
  UNIT_DEATH (care.lua:4545) counts the earlier deaths as they stood (`pend`) for DEATHS_3PLUS.
- `lua/dfllm/deaths.lua:392` (classify): the incident's attacker (`criminal`) was read only for a `killed` type; a BLEED,
  DRAIN_BLOOD, ... incident with a criminal named nobody.
Fair play kept: an undiscovered incident still says "missing" (the unit list does too).

## Fix
- care: every UNIT_DEATH asks the deaths still missing again first (revised DEATH before the new one and before
  DEATHS_3PLUS); every care run start asks too, not only the end of a full run.
- deaths: any death type with an incident criminal carries `killer` and `by` (race); the line reads `bled (incident BLEED; by
  cave dragon 26704)`, clusters `26241:bled by cave dragon`.

## Tests
`tests/lua/test_care_deaths.lua` (2 new: bled by the cave dragon names killer and race; DEATHS_3PLUS names `1:killed`,
`2:bled` after both were discovered). Both fail on b35af6d.

## Live check
Next deaths in combat: DEATH lines name `by <race> <id>` also for bled; a third death in a day lists the causes of the
earlier ones once DF shows them found. Uncertain: whether DF sets the incident criminal for bleed-outs (deathcause.lua names it
for every type); a death nobody has found yet stays unknown by design.
