# BUG-723 fortcore aquifer=pass counts a shaft that ended above the core's deepest level as passed
Status: fixed (offline, live-untested)
Severity: high
Found: 2026-11-10, Run 16c i3 Doorwings y372-y373 (aqshaft 94,98 done at z134 with no aquifer met, the heavy aquifer z131-z133 lay below its depth; `bp.place fortcore aquifer=pass` dug at once and hit heavy_aquifer at 109,106,131 and 51,55,132, CAVERN_PLUG 'no automatic plug for fortcore', 16 chunks undone; player note E13)
Module: `lua/dfllm/aqshaft.lua` (`A.passed`), `lua/dfllm/runner.lua` (`Q.aq_wait`)

## Root cause
`runner.lua` `Q.aq_wait` held a fortcore with p.aquifer=pass until `M.AQ.passed(S.rt)` found ANY finished, not heavy shaft (`aqshaft.lua` `A.passed`, `r.done == 1`). A shaft that ended after its depth with no aquifer met is `done`, but it has seen only the levels down to its bottom: the layers under it (and under the core's levels) were unknown, the core then dug in observe mode into a heavy layer with no ring and no plug.

## Fix
`A.passed(rt, lowest)`: with `lowest` (the deepest z of any cell of the core project, read from its stages in `Q.aq_wait`) only a shaft with `bot <= lowest` counts (a record without `bot` from an older kernel still counts). A second result names the best too shallow shaft: the project row says `shaft ends z134, core z127` (the state row is cut at 40 characters). Without `lowest` the old behaviour.

## Tests
`tests/lua/test_aqshaft.lua`: the existing pass test uses a core at the shaft's bottom level; new test 'BUG-723': a shaft z100-z99 (done, no aquifer) and a core at z90 -> the core does not dig, the row says `shaft ends z99, core z90`; `AQ.passed(rt)` still returns the shaft, `AQ.passed(rt, 90)` nil with the short shaft named.

## Live check
A fortcore with p.aquifer=pass beside a finished shallow shaft shows `paused: shaft ends zN, core zM` and digs only after a shaft reached zM. Open: nobody places the deeper shaft by itself when no aquifer level is known yet (`plan propose` after BUG-724 draws the route).
