# BUG-199 After back-to-back reloads status had no stock line for ~21 game days
Status: fixed (offline, live-untested)
Severity: high
Found: 2026-10-29, live test round 3 i1 (BUG-177a-stock; skeptic confirmed)
Module: `lua/dfllm/economy.lua`, `lua/dfllm/kern.lua`, `lua/dfllm/util/sched.lua` (`M.boot_out`, `M.first_boost`, `T.days`; kern `M.carry` and the boot restore of `kern.carry`; `S.BOOST`)

## Actual
After reload 1 the stock line was carried; after reloads at aut d7 and aut d25 the status had no stock line at aut d37 (state stock null),
and it came back at aut d46. The only early `st.out` came from `T.days`, task 2 of economy's first run, which waits for a full item census
(48.8k items, ~245 slices) paced at 3 ms/s with cadence x3; the kernel carry ages from the leaf's own tick (28 days) and a boot never
renewed it, so repeated reloads let it run out.

## Fix
- economy `M.init` publishes the stock days of the save's last daily run from the persisted `p.prev`/`p.hist` at once (`early`, no labor),
  when that run (`p.days_t`, new) is at most two days old or of unknown age; an older one is left to the carry. `T.days` replaces it with the
  live value and stores `p.days_t` and `p.meals`.
- economy holds a boost (`util/sched` `BOOST.modules.economy`, `BOOST.shares.economy` 8 ms/s, never busy) from its first step after a boot
  until `T.days` ran, then unboosts.
- kern: the carry window counts from the leaf's tick or from the boot (`rec.boot`), whichever is later; `stale` keeps the true age.

## Tests
`tests/lua/test_economy_b2.lua` (BUG-199), `tests/lua/test_kern_gaps.lua` (BUG-199); `tests/lua/test_kern_load.lua` uses care as the module
that may not boost. Each fails on bd27973.

## Live check
Two `dfllm reload` back to back on a big fort: `dfhack-run dfllm status` shows `stock drink Nd food Md` right after each boot; kern.log
`economy boosted: first run since the boot`, later `economy boost ended (unboost; ...)`.
