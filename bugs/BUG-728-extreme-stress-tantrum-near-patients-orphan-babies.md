# BUG-728 A citizen at stress 99,880 smothers bedridden patients; babies starve after their mothers died; nobody was told
Status: fixed (offline, live-untested)
Severity: high
Found: 2026-11-11, Run 16b i2 Whirledrampart y430 sum d76-d77 (DEATH 'suffocated (by dwarf 29543; patient)' x2, 29543 a Dwarven Child, stress 99880, tantrum_ago 12186; 'Dwarven Baby' 29914 hungry / dehydrated after the mothers died of thirst in the hospital)
Module: `lua/dfllm/care.lua` (`M.XS`, `M.xs_look`, `M.xs_step`, `M.stress_ids`), `lua/dfllm/water.lua` (`M.xs_off`, caregiver pool), `dfpilot/wake.py`

## Root cause
care only counted stress categories (`getStressCategory`, FR-83 s0) and named the desperate by name in the state: nothing looked at the raw stress, nothing said that a mind that far gone attacks whoever is nearest, and the game's own GiveWater / GiveFood jobs kept such a unit among the hospital's helpers. Babies have no event at all: a baby whose mother is dead (`relationship_ids.Mother`) was never listed.

## Fix
- `care.xs_look` (per unit of the scan): raw stress >= `M.XS.stress` (80,000, not a baby) is collected (id, name, stress, child, position; at most `M.XS.ids` 6); a baby whose mother is dead, gone or inactive is collected as an orphan.
- `care.xs_step` (in `finish`): DECISION_NEEDED `stress_extreme` (A) once per set of citizens (util/cadence: a new id, else weekly): who, stress, where, the sources the scan found (ghosts, deaths, no beds, no drink: temple, tavern, bedrooms and tombs ease it, plan propose), `cmds` `inspect what=unit` and `inspect what=hospital`; DECISION_NEEDED `orphan_babies` (A, 2 days) with the baby ids. Both are urgent decisions in `wake.py`.
- `care.stress_ids()` is the set of the last scan; `water.xs_off` takes those citizens off the Orderlies work detail (once a week while they stay so, `act.work_detail`) and the caregiver pool never picks one.

## Tests
`tests/lua/test_bug728_stress_orphans.lua` (4): the child at 99,880 is named and in `stress_ids`, once per set; 70,000 is not; a baby with a dead mother is reported, one with a living mother is not; `water.xs_off` calls `work_detail('Orderlies', id, false)` once a week.

## Live check
kern.log 'care: N citizen(s) at stress >= 80000' and the DECISION_NEEDED; 'water: citizen N at extreme stress leaves the Orderlies detail'. Open: the hospital burrow itself is not closed to them (no verb confines one unit); a tantrum already running is not stopped; 80,000 is a judgement (DF's category 0 is above it); the babies get a report, not a feeding job.
