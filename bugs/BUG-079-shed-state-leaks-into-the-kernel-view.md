# BUG-079 A state document over 4 KB is shed for the kernel's own modules too
Status: fixed (integration audit I1; offline, live-untested): `K.view()` is the complete document, only the file the readers
see is shed to 4 KB
Severity: medium (a big fort loses the caravan window of its bridges and the walk-group split of its plant gathering exactly when
it is busiest)
Found: 2026-10-23, integration audit I1 (BUG-071's shed order read together with the modules that read `K.view()`)
Module: `lua/dfllm/kern.lua` (`compose`, `SHRINK`, `K.view`)

## Actual
A fort of 80 with every optional field (ready R0 blockers, a lockdown with its cause, a refuge audit, 8 bridges, 8 projects, a
reclaimed fort's adopt record, the care counters) writes about 5.5 KB. `compose` removes `proj, alert, mil, trade, care, ...`
from `doc` until 4096 bytes fit and then sets `st.view = doc`: the kernel's shared view lost the same keys.

## Cause
kern.lua (base 9bcb14f) `compose`: the shed loop removes keys from `doc`; `st.view = doc` came after it. Readers of
`K.view()` among the shed keys: `gate.lua` `window_open` (`v.trade.caravan`: the PEACE window that lowers the outer bridge for a
caravan; shed = no window, the merchants stand outside), `drill.lua` `M.merchants`, `economy.lua` (the cover pass reads
`bridges` to tell a split walk group from plants off the citizens' group for good; `care`), `care.lua` (`proj`: the coffin
project's percent; `stock`), `readiness.lua` (`stock`), `military.lua`/`economy.lua` (`phase`). The 4 KB limit is a limit of the
FILE the Python readers parse (CONTRACTS 9.3); nothing says the kernel's own modules should see less than it knows.

## Fix
`compose` keeps a shallow copy of the complete document before it sheds and publishes that as the view; the file and the
`inspect state` reply stay within 4 KB with the order of BUG-071 unchanged.

## Test
`tests/lua/test_i1_state.lua`: a gate with 400 bridge entries and a trade module with a caravan: the file lacks `trade` and
`bridges`, `K.view().trade.caravan == 1` and `K.view().bridges.B0001 == 'down'` (fails on the base).
