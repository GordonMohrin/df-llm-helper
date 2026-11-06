# BUG-509 A strange-mood dwarf (a child among them) dies of thirst; the only line has two inspect commands
Status: fixed (offline, live-untested); open: the dwarf cannot be given water at his shop
Severity: critical (24 deaths in one fort)
Found: 2026-11-06, Run 16d i4 Trumpetrealms y389-y410 (events.jsonl: 24 `DEATH ... found dead: mood (... incident THIRST; thirst 75000)` after `DECISION_NEEDED thirst_unit`); the Fey child Urvad y389 (DECISION thirst_unit, StrangeMood)
Module: `lua/dfllm/care.lua` (`mood_seen`, `M.mood_cmds`, `M.mood_help`, `M.thirst_step`), `lua/dfllm/economy.lua` (`M.solo_check`), `dfpilot/wake.py`

## Actual
With 130-480 days of drink in the fort, moody dwarves (Fey / Secretive / Possessed, adults and children) stood at their shop (`StrangeMoodCrafter at 99,109,136`) until thirst 75,000. The only decision was economy's `thirst_unit` at thirst 50,000 / hunger 70,000 with `inspect what=unit` and `inspect what=reach`. Child 26965: MOOD_START 156817313, first MOOD_RISK at thirst 50,179 (held back by the wall-clock cadence `wake_wall_s` 600); child 26786 got none at all between MOOD_NEED and the death; the drink nook (`mood_act` 40,000) was queued at 50,179. Where the nook stood (26276, 26591: "drink nook stands") the dwarf still died, so the nook does not draw him away (the one DrinkItem job, unit 21775 at 87,90,139, came after his mood ended "done").
DF fact the code already states: a mood job cannot be cancelled and a moody dwarf drinks nothing at his shop; the mood fails (insane / dead) when its material does not come (here gems, bone, silk "none in the fort").

## Fix
- `care.mood_seen`: DECISION_NEEDED `mood_thirst` (A, urgent wake) at every step of the dwarf's thirst (30,000 / 40,000 / 50,000 / 60,000) or hunger (40,000 / 50,000 / 60,000 / 70,000), whatever the wall-clock cadence (`rec.dth` is the step). d: unit, kind, child, thirst, hunger, `days` to 75,000, `ws`, `nook`, `missing` (the slots still short), `cmds`.
- `care.mood_cmds` (factored out of `mood_deadline`): the commands that bring the material (`trade.want` for the tokens asked and for stone / blocks none in the fort, `bp.place workshops only=... surface=1` for the missing shops) + `inspect what=unit`. `care.mood_help` gives the same picture for one unit.
- `economy.solo_check` (`thirst_unit`): the unit's mood (kind, child, what is short) in the text, `d.mood` = the moody units, the mood commands in `cmds`. `d.q` was cut at 400 bytes although the contract allows 200 (a longer text is refused and the DECISION lost): now 200.
- wake: `mood_thirst_hint` ("dies of thirst in ~N days; send the commands that bring his material", or "nothing missing: nothing to send").

## Not done / open
Water cannot be brought to him: no verb and no DF screen gives a drink to a dwarf at a mood job (GiveWater serves patients). The lever is the material (the deadline) and, when nothing is missing, only his own finish. Whether the nook helps at all is unproven (the deaths above stood beside a nook).

## Tests
`tests/lua/test_bug507_509_water.lua` (one DECISION per step incl. hunger, no repeat within a step, days / short / ws / inspect command, `mood_help`, `thirst_unit` with the mood and its commands), `tests/test_bug506_509_f32.py` (wake lines). Adapted: `test_care_moods.lua`, `test_care_mood_slots.lua` read the first DECISION that is not `mood_thirst`.

## Live check
The next strange mood with a missing material: `dfllm events --cls A` shows `mood_thirst` at thirst 30,000 with the days left and the `trade.want` command; `MOOD_END done` before 75,000 after sending it means the material came in time.
