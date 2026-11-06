# BUG-560 forbidden mood material outside Kern+ stays forbidden in PEACE: '12 forbidden' leather, two moods died
Status: fixed (offline, live-untested)
Severity: high (a strange mood dies)
Found: 2026-11-06, Round 35 care/mood/trade (fix35-care), from the Run 16 FR-BUGS files and the runtime logs (read only)
Module: lua/dfllm/care.lua (need_item, slot_text)

## Actual
Run 16d i4 Trumpetrealms y407 (events #10337-#10365 of `E:/DF-test4/dfllm-runtime/r16d4-trumpetrealms-site97/`; `runs/run-16d/FR-BUGS.md`): Possessed 27084 and
26868 died; MOOD_NEED "leather x2: none free [12/0/0, 12 forbidden]" for 26 days in PEACE (after a DRILL), no animals to slaughter, bone and silk also missing.

## Root cause
`care.need_item` freed a forbidden item only when `inside(r, x, y, z)` held. `inside` reads Kern+ alone when the fort has a Kern+ burrow (`r.clean_ok` only counts
when there is none), while every other clean-up of care reads `r.clean_ok or inside(...)`. Forbidden leather, bone, cloth or gems outside Kern+ (a stockpile, the
bailey) counted as 'forbidden and care cannot free it' for ever, even in PEACE. The slot text did not say why.

## Fix
`safe = r.clean_ok or K.mode() == 'DRILL' or inside(...)`: no danger (PEACE, RECOVERY after a day, a DRILL) frees a reachable, seen forbidden mood item wherever it lies;
in a SIEGE / BREACH / ALERT the Kern+ rule stays. The slot text names the first reason care could not free the forbidden items (`(Kern+ only, SIEGE)`, `(far)` =
unreachable, `(unseen)`, `(cap)`) and, after a fix, `unforbade N` (`leather x2: enough exist (unforbade 2)`); kern.log has one line per item
(`care: mood unit 7: unforbade item 51 for leather (outside Kern+, no danger)`).

## Tests
tests/lua/test_bug560_mood_unforbid.lua (2); tests/lua/test_care_moods.lua and test_care_mood_slots.lua adapted (`1 forbidden (far)`).

## Live check
See CHANGELOG "Round 35 (care)".
