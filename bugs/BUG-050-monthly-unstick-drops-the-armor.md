# BUG-050 The monthly `uniform-unstick --all --drop --free` makes every soldier drop his kit; the armor coverage falls from 53 % to 4 %
Status: fixed in 63191ea (offline, live-untested): the monthly run is `uniform-unstick --all --free` and only while a uniform
slot is empty; `--drop` is an opt-in (`military.unstick.drop`) after `drop_after` plain runs found the same proven conflict
(`military.conflicts`); never in a lockdown, with a hostile in sight or outside PEACE (`military.danger`); kern.log names the
worn % before and a day and a week after every run
Severity: high (wrong decision: the gate input `worn` falls to 4 % again and again, soldiers hang in PickupEquipment for
weeks, R2 and the intake waves refuse on `worn`)
Found: 2026-10-23 (note 53 of bugs/RUN11-offene-bugs-und-FR.md), Run 14, y529-y535, from the game session
Module: `lua/dfllm/military.lua` (`M.step`, `M.unstick`, `M.conflicts`, `M.danger`, `M.conf`), `config/baseline.json`
`military.unstick`, `config/allowlist.json:43` (unchanged: every argument variant stays allowed)

## Actual
Armor coverage fell from 53 % to 4 % several times between y529 and y535 (Run 14). The session saw every soldier drop his
equipment after the monthly `uniform-unstick --all --drop --free` and hang in PickupEquipment for weeks; it made it worse
once by hand.

## Expected
A repair command that fixes a stuck uniform does not take the uniform off an army whose uniforms work.

## Cause
1. **Proven from the code (f17e2b3): the command runs every month, whatever the uniforms look like, and always with
   `--drop`.** `military.lua:1897-1898`: `if mode == 'PEACE' and soldiers > 0 and (st.unstick == nil or now - st.unstick >=
   M.UNSTICK)` then `K.act.run('uniform-unstick', '--all', '--drop', '--free')`; `M.UNSTICK = 33600` (line 57) is exactly one
   game month, the cadence of the note. Nothing reads the worn % first: a fully equipped army is "unstuck" too, and `--all`
   reaches every soldier, not the ones with a wrong assignment (the script takes no unit argument).
2. **Not provable offline: what `--drop` does inside DFHack.** The script is not in the repo. The note's observation (the
   gear lies on the floor, the soldiers fetch it again for weeks) is the evidence; the monthly cadence matches the
   periodic fall. See "Not decided offline".
3. Pinned by tests: `tests/lua/test_military.lua:503-508`, `tests/lua/test_wp6_kern.lua:106-108` expected the four tokens.

## Fix
- `M.unstick` (military.lua): at most every `unstick.every` (33600) ticks, only in PEACE with soldiers, only while the worn %
  is below `unstick.below` (100: a slot is empty), not while `M.danger` names a reason (`mode <M>`, `lockdown` =
  `reflex.holding`, `hostile` = `census.h.vis` > 0). Args `--all --free`.
- `--drop` only with `unstick.drop` (false by default) and only once `M.conflicts` counted a soldier with a proven conflict
  (he wears an armor piece no spec of its category holds while that category has an empty slot: what the script exists for)
  in more than `unstick.drop_after` (2) consecutive due runs; the run that adds it logs `uniform-unstick --drop: N soldiers
  keep an armor piece no spec holds after K plain runs` and resets the count.
- Diagnostics: kern.log `military: uniform-unstick T ticks ago (--all --free): worn X% before, Y% now` at +1,200 and +8,400
  ticks after each run (persisted `us_w`, `us_a`, `us_n`).
- Config `military.unstick {on, drop, every, below, drop_after}` (`fairplay.MILITARY_UNSTICK_LIM`, `lint --config`).
  `unstick.on = false` switches the monthly run off.
- Docs: DESIGN §4 cost table, DOCTRINE (uniform), CONTRACTS §7 (`military.danger`, `military.conflicts`), §9.17.

## Not decided offline
- **Does the plain run (`--all --free`) also strip gear?** If `--free` or the script itself drops worn kit, the log line
  shows it: `worn X% before, Y% now` a day after a run with Y far below X. Then `military.unstick.on = false` in
  config/baseline.json (and `dfhack-run dfllm reload`) stops it. Decides: the kern.log `uniform-unstick ... worn` lines
  of one game year (read-only); during a siege BUG-052's `off.equip` counts the soldiers in a PickupEquipment job.
- **Is the conflict test the script's own?** `M.conflicts` is the kernel's reading of the stuck state; if it never fires
  while the army stays stuck, nothing escalates to `--drop` (the safe side).

## Tests (fail on f17e2b3)
`tests/lua/test_military_a3.lua` (new: no `--drop` by default, a filled army left alone, the opt-in escalation after
`drop_after` plain runs, never without the opt-in, no run in a lockdown / with a hostile / outside PEACE, the worn-% log),
`tests/lua/test_military.lua` and `tests/lua/test_wp6_kern.lua` (the run is `--all --free`), `tests/test_military_a3.py`
(config validation, the Lua defaults mirror).

## Live check
See the CHANGELOG entry (2026-10-23, package A3).

Related: BUG-052 (soldiers not on station: `off.equip`), DOCTRINE (Replace clothing), note 53
