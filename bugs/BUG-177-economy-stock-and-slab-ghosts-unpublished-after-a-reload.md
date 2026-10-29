# BUG-177 After a reload economy publishes no stock until its first daily run ends, and its slab pass reads 0 ghosts
Status: fixed (offline, live-untested)
Severity: medium (status `stock  hospital ok` without drink/food for ~15 game days; slab restock cap 0 while ghosts wait)
Found: 2026-10-29, live test round 2 i1 (NEW1: after a reload the carry ran out at ~sum d76, complete again at aut d7) and i4 (NEW7: view.care
nil for ~15k ticks after a reload, slab pass ghosts 0)
Module: `lua/dfllm/economy.lua` (`T.days`, `M.state`, `M.slab_ghosts`, `M.slab_pass`)

## Actual
- `st.out` (drink_d, food_d, meals) was set only in `T.finish`, the last of about 45 tasks; demoted x8 and paced, the first run after a boot took
  about 40 game days, longer than the kernel's 28-day carry.
- `slab_pass` took the ghosts only from `K.view().care.ghosts`; care publishes it only after its own first full run, so a reload gave 0.

## Fix
- `T.days` sets an early `st.out` (stock days, meals, hungry; `early`) when none exists; `M.state` publishes labor only from a complete one (the
  kernel carries labor meanwhile).
- `M.slab_ghosts`: care's view, else `#census.g.ids` while census.g is fresh (two days, as care's memorial pass), else unknown: no restock and no
  request on a guessed 0, `slabs.why` says so.

## Tests
`tests/lua/test_economy_b2.lua` BUG-177 (two tests; fail on b805745).

## Live check
`dfhack-run dfllm reload` in a large fort (economy demoted), then `dfllm status` every few game days: `stock drink Nd food Nd` comes back
within a few game days (before kern.log shows the economy run's end) and never stands bare; `dfllm cmd inspect '{"what":"orders"}'` right after
the reload: `slabs.ghosts` equals the fort's ghosts (census) or `slabs.why` 'ghost count unknown ...'.
