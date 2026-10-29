# BUG-278 STRANDED for hunger 30000 and for citizens on a trip: no hunger a player sees, one read, no job check
Status: fixed (offline, live-untested)
Severity: low (noise: A wakes for founders who came back on their own)
Found: 2026-10-29, Run 15 Earthboat (y372-y374), fix6-alarm-noise
Module: `lua/dfllm/siege.lua` (`M.STRAND_THIRST/HUNGER/CONFIRM`, `cut_off`, `rescue_step`, `M.rescue_close`, `failed_bridge`)

## Actual
`runs/run-15b-earthboat/FR-BUGS.md`: #40 STRANDED (spring d73) 'thirst 29216, hunger 30004' for 26275 at 3,126,141, again #754 and
#823 for 26272/26277 at 1-4,126,141; the wake line at d77 repeated the values while the unit stood with the others (job none,
content).

## Cause
`cut_off` counted a citizen at hunger above `STRAND_HUNGER` = 30,000 (DF's Hungry starts at 50,000; Thirsty at 25,000), on one read
of seal's walk groups, without looking at his job.

## Fix
Marks = DF's lines: thirst 25,000, hunger 50,000. A citizen counts only when reads `STRAND_CONFIRM` (1,200 ticks, a game day) apart
find him off the stock (`mem.str_seen`, reset once nobody is over a mark); a citizen on a trip job (`seal.trip`, the list of BUG-277)
is not stranded (kern.log 'siege: not stranded, on a job outside: id:job', once per set). The day's delay showed a race: a rescue that
ends in a SIEGE older than T+900 wanted its bridges up and the same step read them still down ('B1 not up at T+900' -> BREACH);
`M.rescue_close` now gives each bridge a grace until its raise deadline (`mem.rs_grace`, read by `failed_bridge`).

## Tests
`tests/lua/test_siege_strand_noise.lua` `BUG-278: ...` x4 (fail on 2b9c009); `tests/lua/test_fix5_gate.lua` hunger 45000 -> 55000
(the old fixture sat below DF's Hungry line); `tests/lua/test_stranded.lua` BUG-028 (a)+(b) passes again with the grace.

## Live check
At the next citizen away from the food: no STRANDED below hunger 50,000; kern.log 'siege: not stranded, on a job outside: ...' for a
hunter/gatherer; a really stranded one gets STRANDED about a game day after his first read (`dfllm events --type STRANDED`, d.thirst
and d.hunger above the marks). In a siege rescue: no BREACH 'not up at T+900' right after STRANDED done.
