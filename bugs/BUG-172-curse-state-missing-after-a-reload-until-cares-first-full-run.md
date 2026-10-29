# BUG-172 After a reload the state has no `curse` key (no CURSED line) until care's first full run
Status: fixed (offline, live-untested)
Severity: high (27 game days without the CURSED line, across a transformation and a death)
Found: 2026-10-29, live test round 2 i2 (M4-STATUS, NEW1; skeptic confirmed after a `dfllm reload`: 13 samples over 50 s without `curse`)
Module: `lua/dfllm/care.lua` (`M.state`), `lua/dfllm/curse.lua` (`M.view`)

## Actual
`care.state` returned `{}` while `st.out` was nil, and `st.out` is set only at the end of care's full run (paced and demoted after a boot:
tens of game days). The curse view does not depend on `st.out`, and `curse.reset()` at init also dropped the built view until the next report
or daily watch.

## Fix
- `care.state`: without `st.out` it returns `{curse = <view>}` (care's own values still wait for its run).
- `curse.view(K, c, p)`: a view not built since the boot is built at once from the persisted records (`m.care.cur`).

## Tests
`tests/lua/test_curse_live2.lua` BUG-172: a reload (`care.init`) and `W.state()` at once: `curse.n 1, ids {1}`, no `care` (fails on b805745).

## Live check
`dfhack-run dfllm reload` in a fort with cursed units, then `dfllm status` at once (paused is fine): the `CURSED n (ids ..)` line is there
before care's first run (kern.log `tombs:` line) has come.
