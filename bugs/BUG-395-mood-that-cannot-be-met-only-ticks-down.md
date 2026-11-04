# BUG-395 a mood that cannot be met in time only ticks down: MOOD_CRITICAL repeats, nothing ready to send before the deadline
Status: fixed (offline, live-untested); open: no verb confines one dwarf
Severity: high
Found: 2026-11-04, Run 16 round 2 (i3: 4 mood deaths incl. a Fey strangling; i2: 5 failed moods and a berserker; `runs/run-16b/FR-BUGS.md`, `runs/run-16c/FR-BUGS.md`)
Module: `lua/dfllm/care.lua` (mood_deadline, rock_short, mood_emergency), `dfpilot/wake.py` (URGENT_DECISIONS, next_hint)

## Actual
i3 #1243-#1312: for 40 days the dwarf got MOOD_CRITICAL (`material`, `waiting`, `timer`) and one `DECISION_NEEDED mood_material` with a hint but no command line (`dig stone (bp.place
bedrooms prio=1)`, which cannot be placed without a fortcore); the player had nothing to send before the dwarf went insane. i2: MOOD_RISK said `route bars: no ore: explore dig (plan), trade.want
bar:iron` (18 MOOD_CRITICAL with `missing:["bars"]` alone) and the moods failed; no command line reached the player.

## Root cause
`care.lua` `mood_emergency` ended at `K.emit('MOOD_CRITICAL')`: a status line, no `cmds`; `mood_material` (`mood_report`) carries the class hints as text; `mood_workshop` the `bp.place` text of
`ws_fix` without the surface case. Nothing turned "N days left, still short" into a decision with ready commands, and a repeat of MOOD_CRITICAL at 20/10/5/2 days is news without an action.

## Fix
- `care.lua` `M.mood_deadline` (:798), called by `mood_emergency` (:728): within `care.mood_decide` (15) days of DF's insanity line, while the reasons hold a missing workshop, a material none in the fort,
  items out of reach or a wait of days (a mood that only runs out the clock gets nothing), `DECISION_NEEDED mood_deadline` (A) at each step of days left (20, 10, 5, 2; `util/cadence`):
  q = `<name> <kind>: N d to insanity, still short: <slots>; if it fails he turns on others: send these, the squad is the last line`, cmds = `dfllm cmd trade.want {"want":[...]}`
  (the mood's tokens `bar:iron`, `cloth:silk` ..., `stone`, `blocks`), `dfllm cmd bp.place {"tpl":"workshops","site":"S1","p":{"only":"<shops>","surface":1}}` for the shops he waits for (no fortcore needed,
  BUG-394), opts = their names, auto = what the kernel already does (`stone dig`, `caravans asked`).
- `wake.py`: `mood_deadline` is an urgent decision (never held longer than a game day, like drink/food) and its wake line carries the first command like the famine decisions (`food_hint`).
- MOOD_CRITICAL's line names the stone dig of BUG-393 or why none.

## Tests
tests/lua/test_bug393_395_mood_stone.lua (2 for this bug: steps, commands, size, no repeat in a step, workshop case, nothing to send when nothing is short), tests/test_bug393_395_mood_stone.py (schema, command validity, wake hint, urgent).

## Open
No verb confines one dwarf (a mood job cannot be cancelled, a lock needs a room): if a mood fails, the dwarf turns insane and the soldiers' `squad.sortie` (approve:true) is the last line;
the text says so. A kernel-made refuge cell for the moody dwarf would be a feature (zone/door/burrow verb), not done here.

## Live check
A mood with a material none in the fort: at <= 15 days `events --cls A` shows `DECISION_NEEDED mood_deadline` with `d.cmds` (JSON valid, `dfllm cmd` lines), the wake line prints the first command; at 10/5/2 days again.
