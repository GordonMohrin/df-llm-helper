# BUG-063 Strange-mood dwarves die of thirst and hunger: MOOD_RISK said "nothing missing", the mood check ran too late
Status: fixed in ee72cb1 (offline, live-untested; whether a drink beside the workshop makes a moody dwarf drink is not
decided offline)
Severity: critical (a dwarf with a mood is a master craftsman; three died, one raved)
Found: Run 11 (Kilrudrabed) y484 (Fey, unit 28872, thirst 75000, hunger 76725) and y485 (Possessed, 28844, thirst 75002,
hunger 100339, a patient); Run 14 (Trussroads) y558 (unit 34119, Masonry, no workshop, thirst 63513/75000, already
"Raving"); notes 14 and 58 in bugs/RUN11-offene-bugs-und-FR.md
Module: `lua/dfllm/care.lua` (mood_seen, mood_watch, M.step, M.on.REPORT, mood_relief), `lua/dfllm/runner.lua`
(mooddrink), `dfpilot/schema.py`, `dfpilot/wake.py`, RULES §7

## Actual
- MOOD_RISK reported only "nothing missing; a mood job cannot be cancelled": the materials were there, the workshop job did
  not happen, the dwarf neither ate nor drank, and nothing else in the kernel acted on his thirst.
- The game session's own mood check ran every 15 minutes; at timestream speed that is a game year. A dwarf noticed at thirst
  63,513 was already Raving.

## Causes (from the code at f17e2b3)
1. **The kernel's mood check shared care's full run.** `mood_seen` ran in `phase_units` of the 1,200-tick run (care.lua:431+,
   `M.every = {ticks = 1200}` line 91), and care is a scaled and demotable module (sched.lua:45 `S.SCALED`; the period is
   1,200 x the demotion factor x the load stretch up to 3), so a mood and its thirst were read every game day at best,
   after the whole corpse and tomb run of the previous period. Nothing reacted to the game's own announcement
   (STRANGE_MOOD, MOOD_BUILDING_CLAIMED).
2. **The hunger line was 50,000** (care.lua:112 `mood_hunger`), the thirst line 30,000; one MOOD_RISK per cause per 2 days
   and 10 minutes (util/cadence), no stage above it, no name of the dwarf or the workshop in the line.
3. **Nothing on the drink side.** MOOD_RISK asked for the missing material only (reserve, MOOD_NEED); when nothing was
   missing it had no lever. Fair play allows no job and no item for the dwarf (decision 15), but a stockpile beside the
   workshop is a zone like any other.

## Fix
- **Earlier check** (decision 15): care reads the game's STRANGE_MOOD and MOOD_BUILDING_CLAIMED reports at once (`M.reports`,
  `M.on.REPORT` -> `mood_watch`: the citizens' mood and, for a moody one, the whole `mood_seen`), asks for a full run at
  the next step (material first), and while a mood is open switches its cadence to `mood_fast` (300 ticks, `M.every` is
  read every frame): between full runs only the mood check runs (a read of the citizens' mood and the moody dwarves'
  thirst/hunger; no new per-tick scan). The full run keeps the period measured between two default calls.
- **MOOD_RISK** names thirst and hunger both and the workshop type (`ws`); the hunger line is 40,000 (`mood_hunger`), the
  thirst line stays 30,000.
- **The drink nook** (`mood_act` 40,000 thirst or hunger): `runner.mooddrink` queues a project of a one-tile food stockpile
  `dfllm-mood`, drink only (`f{name=dfllm-mood barrels=1 take_from=dfllm-stock}:=booze(1x1)`, quickfort place, cell <= 64
  bytes) on the nearest free floor tile within 3 of the claimed workshop (revealed '.', no building, zone or stockpile,
  walkable from the workshop; `nook_site`), priority 1; once per mood (`p.nook`), only in PEACE/RECOVERY, one at a time
  (`pending mood_drink`), `mood_nook` false switches it off; the line says `drink nook queued at x,y,z (mdr...)` or why
  not (`no free floor within 3 tiles of the workshop`). Nothing is given to the dwarf and no job is made for him.
- **MOOD_CRITICAL (A)** at thirst `mood_crit` (50,000; hunger `mood_crit_hunger` 60,000): the dwarf (id and name), the
  workshop and its first tile, thirst and hunger, the missing classes and the nook; once per cadence. RULES §7 (shared row
  with MOOD_RISK), wake hint.
- Safety: a fight (SIEGE/BREACH/ALERT) queues no nook; a missing runner module or a refused project only reduces the line;
  a quiet fort keeps the 1,200-tick cadence; the fast cadence ends with the last mood record.

## Not decided offline
- **Does a moody dwarf drink from a barrel beside his workshop?** DF's own rule for strange-mood dwarves is not in the repo.
  Live data: after `kern.log mood nook: unit N ...` and the project's done state (`dfllm status` proj), the unit's thirst in
  MOOD_RISK/MOOD_CRITICAL (`d.thirst`) falling, or MOOD_END ok; if his thirst keeps rising with the nook standing and a
  drink in it (`inspect census` / the stockpile), the nook does not help and the remedy is the material and the workshop
  (MOOD_CRITICAL names both).

## Tests
`tests/lua/test_care_b3.lua` (BUG-063 group): the report starts the check within a few ticks, the fast cadence reads a
thirst within 450 ticks, hunger 41,000 is a MOOD_RISK naming thirst, hunger and the workshop, MOOD_CRITICAL, the nook (cell,
site, once, no act on the dwarf, none in SIEGE/without runner/without floor); `tests/test_care_b3_files.py` (events on the real
kernel). Each new test fails on f17e2b3.
