# BUG-646 Stranded false alarm for citizens who drink outside
Status: fixed (offline, live-untested)
Severity: medium
Found: 2026-11-10, Run 16c i3 Wallfree y390-y391: 228 x `STRANDED ... no raised bridge leads to drink` for single citizens walking outside at thirst ~26,300 that drank at the cavern lake zone 17718 (0 dead in two years)
Module: `lua/dfllm/siege.lua` (`cut_off`, step, `M.DRANK_DROP`, `M.STRAND_DRINK_HARD`)

## Actual
A STRANDED line per wanderer every day, `DECISION stranded_drink` questions, the alert 'stays' for harmless surface walkers.

## Root cause
`cut_off` marked every citizen over `STRAND_THIRST` 25,000 (DF's 'Thirsty' line, the very point at which a dwarf goes to drink) on a walk group without drink, after two reads a day apart. A citizen who walks 20-35 tiles to a lake is over the mark for a while whatever happens; nothing told a walker who drinks from one who does not.

## Fix
The step reads every citizen's thirst each time (cheap counters): a fall of 3,000 or more since the last read is a drink he reached (`mem.str_drank`, kept one game year). Such a citizen with a drink-only need and thirst up to 40,000 is 'on a job outside' (`drinks outside`, kern.log), not stranded; a thirst past 40,000 or one that never fell is stranded as before.

## Tests
`tests/lua/test_siege_strand_noise.lua` (+2)

## Live check
Wallfree: wanderers at ~26k raise no STRANDED once one drink was seen; kern.log says `not stranded, on a job outside: N:drinks outside`. A citizen who never drinks (thirst rising past 40,000) still raises it.
