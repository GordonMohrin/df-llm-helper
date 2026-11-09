# BUG-608 Hospital stays build_lost for materials that cannot be had, retried 8 times
Status: fixed (offline, live-untested)
Severity: high
Found: 2026-11-09, Run 16a i1 Basementflew y426-y429 (hospital bench=0, 7 parts `buildingplan: waiting for materials`, 8 retries, the stock in the flooded z117 complex)
Module: `lua/dfllm/runner.lua` (`Q.mat_why`, `retry_step`, `blocked_event`)

## Actual
Hospital stays build_lost for materials that cannot be had, retried 8 times.

## Root cause
A build_lost room whose pieces waited for material that was out of reach was dug and placed again every season (8 retries), and PROJECT_BLOCKED said `missing ...` only. Only seals asked economy whether their pieces can be made (`M.remake_why`).

## Fix
`runner.lua` `Q.mat_why(K, P, d)`: the missing pieces of the blocked build stage by kind (`b` bed, `t` table, `h` chest, `c` chair, `f` cabinet, `d` door, `H` hatch, `W`/`G` grate), each asked of `economy.mat_for`; the answer is the text `bed x3: no logs` plus the stock out of the citizens' reach (`rock_far`, `blocks_far`, `doors_far` ...: `out of reach (another walk group): 64 rock, 62 blocks`). `blocked_event` carries it for every template (`d.mat`), `retry_step` holds the season retry of a non-seal room while it stands (`build_lost retry held, the pieces cannot be made: ...`, once per text); more revealed tiles still retry.

## Tests
`tests/lua/test_bug608_612_runner.lua` (the text and the event, the retry hold against a fort that can make the pieces)

## Live check
A build_lost hospital: PROJECT_BLOCKED names the material and the far stock; kern.log `retry held` instead of `retry n/8`.
