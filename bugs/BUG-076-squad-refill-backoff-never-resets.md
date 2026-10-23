# BUG-076 A refused addToSquad backs a squad off for good, and one refused unit blocks the refill of the whole squad
Status: fixed in 23c1ab9 (offline, live-untested): a successful refill clears the squad's backoff; a unit `addToSquad` refuses is
passed over for `M.ADD_BAD` (33,600 ticks) and the next candidate is tried (`M.ADD_TRIES` = 3 refusals per refill before the
squad backs off); the refusal's text goes to kern.log (at most every `NOTE_EVERY` ticks per squad)
Severity: medium (wrong decision: a squad stays under strength for up to a game month per refusal; it was in the way of
FR-79, where the same adds are the militia turnover)
Found: 2026-10-23, reading `lua/dfllm/military.lua` for package D1 (FR-79, notes 64 and 67 of bugs/RUN11-offene-bugs-und-FR.md);
the note 64 follow-up ("the kernel fills and empties all three squads continuously and very fast, a hand-made membership is a
race") sent the reading to `fill`
Module: `lua/dfllm/military.lua` (`fill`, `retry_ok`, `backoff`, `cleared`), at base 9bcb14f

## Actual
Nobody saw it live; it is what the code does when DF refuses an add (`dfhack.military.addToSquad` returns false: no leader in
position 0, no free position, a unit without a historical figure, a unit already in a squad: `act.lua:691-695`).

## Cause (proved from the code at 9bcb14f)
1. **The backoff of an add is never cleared.** `fill` (`military.lua:1221-1245`) calls `backoff(K, 'add' .. k)` on a refusal
   (`:1230`) and checks `retry_ok(K, 'add' .. k)` (`:1225`). `backoff` (`:665-669`) doubles `t.wait` from `M.RETRY` (1,200) up
   to `M.RETRY_MAX` (33,600) and keeps the record; `cleared` (`:670`) is called for `create`, `uni`, `wpn` and `lead`
   (`:773`, `:1120`, `:1162`, `:1211`) but nowhere for `add` (`grep -n "cleared(" military.lua`). A successful add does not
   reset anything, so every later refusal in the same boot waits twice as long as the one before: 1,200, 2,400, 4,800 ...
   33,600 ticks (a game month) without any squad_add in between. The record is in `rt`, so a reload resets it; a long-running
   kernel does not.
2. **A refused unit stays the head of the line and blocks the squad.** The candidate list is `M.recruits` sorted by combat
   value (`:497-502`), the same order every upkeep. The loop (`:1227-1231`) takes the first candidate, and on a refusal does
   `backoff` and `break`: the other candidates of the step are not tried, and at the next upkeep the same unit is first again
   and is refused again (with the doubled wait of cause 1). One unit DF will not take in thus keeps the squad short for
   good. The text of the refusal (`err` of `act.squad_add`) was thrown away: kern.log said nothing.
3. **Not a cause (checked): SIEGE_FILL/HOLD_MIN.** The note 64 follow-up named them for the squads that change "within
   seconds". `SIEGE_FILL` is checked at `:2315` and acts only in SIEGE/BREACH (`low`, `:1224`; `hold_floor`, `:2272-2282`). In
   PEACE the upkeep runs every `M.SLOW` (3,600) ticks (`:2304`), outside it every `M.FAST` (600); at timestream (~450 ticks/s)
   that is 8 s and 1.3 s, which is what "within seconds" of real time looks like. In PEACE `fill` tops a squad up to its
   target `want` from the best fighters and removes the weakest member only above `want + KEEP_EXTRA` (`:1237-1243`); a
   hand-made cohort smaller than `want` is topped up around itself at the next upkeep, which is the race of the note (see FR-79).

## Fix
- `fill`: `cleared('add' .. k)` after a successful add; a refused unit gets `rt.add_bad[uid] = now + M.ADD_BAD` and is skipped
  (also in `M.rot_pool`: it is not a candidate for the rotation either), the next candidate is tried; after `M.ADD_TRIES`
  refusals in one refill, or when nobody was added, the squad backs off once; one kern.log warning per squad every
  `M.NOTE_EVERY` ticks: `squad B: unit 8 was not taken in (addToSquad refused); passed over for 33600 ticks`.
- Unchanged: the first backoff is still 1,200 ticks; the other squads' retries; the siege refill rules.

## Not decided offline
- **Why DF refuses a unit.** The act returns the fixed text `addToSquad refused`; the DFHack source is not in the repo. The new
  kern.log line names the unit; `inspect` of that unit by hand (hist figure, entity links) would tell. Read-only data that
  decides: the unit's `hist_figure_id`, `military.squad_id` and the squad's positions at the moment of the refusal.

## Tests
`tests/lua/test_military_d1.lua`: `BUG-076: one unit that addToSquad refuses does not block the refill of the squad` (fails on
9bcb14f: squad A stays at its leader), `BUG-076: a successful refill clears the backoff` (three refusal series, each retried
after 1,200 ticks; the base waits 2,400 and 4,800).

## Live check
See the CHANGELOG entry (2026-10-23, package D1): kern.log `was not taken in` lines; squads at their target a day after a
refusal.

Related: FR-79 (the militia turnover uses the same adds), BUG-050 (the other kit-related upkeep), notes 64 and 67
