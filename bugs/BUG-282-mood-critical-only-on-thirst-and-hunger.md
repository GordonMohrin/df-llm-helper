# BUG-282 MOOD_CRITICAL fires only on thirst and hunger; DF's mood timer kills the dwarf first
Status: fixed (offline, live-untested)
Severity: critical (four citizens died, three moods without any MOOD_CRITICAL)
Found: 2026-10-29, Run 15 (read-only: E:/DF-test4/dfllm-runtime/r15d-drillchamber-site97, E:/DF-test2/dfllm-runtime/r15-guildcleans-site97,
kern.log + events.jsonl; runs/run-15*/FR-BUGS.md)
Module: `lua/dfllm/care.lua` (mood_seen), new library `lua/dfllm/mood.lua`

## Actual
- Drillchamber y375: fey glassmaker 26535, MOOD_START tick 151370909, MOOD_RISK `missing` and DECISION_NEEDED #1261 (glass
  furnace), claimed the Glass Furnace at 151407628, MOOD_END failed at 151462109 (54,481 ticks after the claim), died of thirst
  after going insane. No MOOD_CRITICAL.
- Drillchamber y376: Possessed carpenter 26396 (silk + plant cloth, none in the fort, no thread), claimed the Carpenter's shop at
  151605424, went berserk and was killed at 151658967 with thirst 13,991 and hunger 19,572. No MOOD_CRITICAL.
- Guildcleans: Udil 26415 (Fey, gems) and Alath 20997 (Secretive, leather + plant cloth) got MOOD_CRITICAL only at hunger 60,300
  (53,000 ticks in) and thirst 50,370 (72,000 ticks in), days before the end.

## Root cause
`care.lua:633` (base 64df679): `local crit = th >= c.mood_crit or hu >= c.mood_crit_hunger`. MOOD_CRITICAL knew only the
thirst and hunger timers. DF ends a mood by its own clock, `unit.job.mood_timeout` (df-structures: counts down from 50,000 from the
claim, insanity at 0), whatever the thirst: a dwarf who drank before his mood reaches insanity long before thirst 50,000. After
the insanity the mood is no strange mood any more, `mood_seen` is never called again (`care.lua:754`), so the late bar never comes
either. A missing workshop or a material with no item in the fort was only MOOD_RISK/DECISION_NEEDED, never the emergency.

## Fix
`M.mood_emergency` (called by every mood check, every `care.mood_fast` = 300 ticks): `dfllm.mood` reads DF's timer
(`MD.timer`, pcall; else the estimate claim + `care.mood_timer` 50,000, said `est`; no claim: unknown) and the reasons
`workshop` (no claimed shop after `mood_crit_nows` ticks or his shop type missing on the map), `material` (a slot none in the fort),
`waiting` (still missing `mood_crit_wait` 5 days after the start), `timer` (within `mood_crit_left` 10 days). MOOD_CRITICAL (A)
`[unit N reasons] MOOD <name> <kind> needs <items>: <have/missing>, <days left>; <what the kernel did>`, d.why/reasons/left/lsrc/
need/ask/webs/slots; again at each step of days left (20, 10, 5, 2: a cadence token), `mood_crit_every` ticks and
`mood_crit_wall_s` s apart. The thirst/hunger MOOD_CRITICAL stays as it was.

## Tests
`tests/lua/test_mood_emergency.lua` (glassmaker at thirst 2,000; DF's timer 9 -> 4 -> 1 days; the estimate from the claim; the
mood library), `tests/test_bug282_285_moods.py` (contracts, guide). Updated: `test_care_b3.lua` (the thirst test filters why=thirst).
All fail on 64df679.

## Live check
Next strange mood: `dfllm events --type MOOD_CRITICAL` shows one within a day when a shop or a material is missing, `d.left`
counts down and `d.lsrc` is `timer`. If `lsrc` stays `est`, `unit.job.mood_timeout` is not readable in 53.16: read it
read-only once (`inspect what=unit key=<id>` does not show it; a selftest dump) and fix `MD.timer`. Compare `d.left` at MOOD_END
failed with 0.
