# BUG-733 "stone free 0" beside 66-77 boulders after an explore finished, and nothing says where the boulders went
Status: partly fixed (offline, live-untested): exact count and a breakdown; the live cause is not proven
Severity: high
Found: 2026-11-11, Run 16b i2 Whirledrampart y431 (PROJECT_DONE explore c1a1c936677aea0401, CLAYSTONE z137-z134, CHERT z133-z131; `inspect workload`: stone free 0 need 29-32 for more than 65 days, Masons project "no builder has taken it", state `rhard` 1)
Module: `lua/dfllm/economy.lua` (`stone_free`, `M.usable_n`, `M.stone_why`, census BOULDER branch), `lua/dfllm/care.lua` (`hard_stone`)

## Root cause (what the logs prove, and what they do not)
kern.log of i2 shows 66-77 boulders in the census (`order ... rock -> wood (66 boulders, 596 logs)`) and the by-material line CLAYSTONE x9-14 (hard), TETRAHEDRITE x30-49 (ore, economic), KAOLINITE x24-40 (hard), SANDY_CLAY / SILTY_CLAY (soft). `state.a.json` has `stock.rock 0`, `rock_need 22`, `rhard 1`: DF's cancel memory (`M.hard_denied`, BUG-545) was set, so `stone_free` (`economy.lua:2663`) answered 0 whatever the census held; the memory is lifted only when the census `rock` grows by more than `M.HARD.new` (5) beyond the count at the denial. Nothing in the kernel wrote WHICH of the takers cut the boulders (walk group, a job holds it, ore / economic / soft, DF's denial memory, the reserve floor of open needs and holders), and the decision text is written once and then stays quiet (BUG-610). Whether the dug CLAYSTONE / CHERT lay on another walk group, in a job, or behind the denial memory cannot be told from the logs.
One real counting flaw found on the way: the census took `max(ore + flux, rock_bad)` as the unusable count, two sets that overlap only in part (an ore that is also economic is in both, a plain economic stone only in `rock_bad`, a non-economic ore only in `ore`); it under-counted whenever the two were disjoint (5 ore + 4 economic + 3 flux of 18: 8 counted, 12 true) and gave the masons boulders no job can use.

## Fix
`economy.lua` census: `rock_nouse` counts each ore / flux / economic / soft / refused boulder once; `M.usable_n(inv)` (rock - rock_nouse; the old formula for a census without the key) is used by `stone_free`, `hard_diag`, the stage facts and care's `hard_stone`. `M.stone_why(c, r)` / `M.stone_why_text`: boulders -> out of reach -> held by a job -> free -> ore / flux / economic / soft -> usable -> DF's refusal memory -> kept back for open needs and reserves -> free. It is written into `inspect workload` `stone.why` and, while stone is wanted and none is free, into kern.log `economy: stone free 0 (need N): ...` every 3 game days.

## Tests
`tests/lua/test_bug733_734_stone.lua`: 18 boulders (5 ore+economic, 3 flux, 4 economic, 6 plain) -> 12 unusable, 6 free (the old formula gave 9); a world with 7 boulders out of reach, 3 in a job and 5 economic ones and open rock orders -> workload `stone.why` {15, 7, 3, 5, 5, 0, 0} and one kern.log line in three days.

## Live check
After a Kernel reload: `dfllm cmd inspect '{"what":"workload"}'` in a stone-0 fort shows `stone.why`; kern.log names the step that takes the boulders. Open: the root cause of the i2 case is not proven. The candidates are boulders on a walk group other than the citizens' (the tunnel behind a raised bridge in a BREACH / SIEGE flicker), in a job that never ends, or the denial memory (`rhard` 1) outliving the new rock: it is by count, not by material, so a new material DF would take (CHERT) does not lift it until 5 more boulders come.
