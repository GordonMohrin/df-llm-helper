# BUG-524 Phase P3 'waits for orders_rockstock' for 8+ years and the status never says what is missing
Status: fixed (offline, live-untested) as the missing item named; the gate itself is unchanged by design
Severity: medium (P4/P5 builds never came; the cause was invisible)
Found: 2026-11-06, Run 16c i3 Sealcertain y385-y393 (`runs/run-16c/FR-BUGS.md` "Phase P3 'waits for orders_rockstock' ohne Grund seit >8 Spieljahren"; kern.log `r16c4-sealcertain-site97`: `orders library/rockstock of the plan held until its stage is ready (config economy.stages)`, read only)
Module: `lua/dfllm/economy.lua` (`M.held_why`, `M.lib_ready`, `facts`), `lua/dfllm/runner.lua` (`Q.dv_text`)

## Actual
status/brief: `phase P3: waits for orders_rockstock`; the plan lists `library/rockstock`, hospital and furnaces stand, the phase never moves.

## Root cause
The P3 deliverable `{k: orders, lib: library/rockstock}` is met when `economy.imported(lib)` (runner.lua CHECK.orders). economy imports the library only when its config stage is ready (`economy.stages`: `workshop:Masons` AND `stone`, i.e. 60 free furniture-grade boulders: `rock - max(ore + flux, rock_bad) >= 60`, BUG-202, so that rockstock does not queue 98 orders that cannot start). Sealcertain is a stone-poor fort: the stone count never reached 60, kern.log said so once per boot (info), and `Q.dv_text` printed the bare key `orders_rockstock`.

## Fix
`economy.held_why(lib)` returns the missing parts of that stage (`no Masons,stone 12/60`, `cit 4/10`, `no Smelter,no fuel`) and nil when the library is imported, has no stage or the stage is ready. `Q.dv_text` appends it to an `orders` deliverable: `phw.wait` now reads `orders_rockstock stone 12/60` (cut at the 40 bytes the state allows, no schema change). The threshold itself is kept: lowering it would queue rock orders without boulders; a fort that really cannot reach it waives the deliverable with `phase.waive orders_rockstock` (BUG-300).

## Tests
`tests/lua/test_bug524_orders_held.lua` (2: the text with and without Masons / stone, imported or unknown libraries), `tests/lua/test_bug524_phase_wait.lua` (3: the status line, the 40-byte cut and the contract, no answer = the plain key).

## Live check
`status` of a fort that waits for `orders_rockstock`: the line names `no Masons` / `stone N/60`. If it is the stone, `phase.waive orders_rockstock` (or a stone dig / a trade for boulders) is the way on.
Open: whether the waiver should be automatic after N days is a design decision (a fort without 60 free boulders keeps its rock orders held, which is wanted); not done. The live stone count of Sealcertain was not read (logs only), so 'stone short' is the reading of the config, not a measurement.
