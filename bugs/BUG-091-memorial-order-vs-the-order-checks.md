# BUG-091 The kernel's own memorial order meets the order checks: the pruner's removal is made again at once, engravings at work count as a jam
Status: fixed in the integration audit J2 commit (offline, live-untested)
Severity: medium (an order made, cancelled ten times, removed and made again for ever; a wrong "jam" line while three engravings work)
Found: integration audit J2 (2026-10-23), BUG-078 (kernel orders the slab) read with the "Needs ..." pruner (FR-10) and BUG-061's jam scan
Module: `lua/dfllm/economy.lua` (`needs_cancel`, `M.slab_engrave`, `order_ctx` `has('slab_blank')`), `tests/lua/test_economy_b2.lua`

## Actual
1. **Order, ten cancels, removal, the same order again.** `needs_cancel` removes the order a "Needs ..." cancel names after
   `orders.needs_drop` (10) cancels in 7 days and keeps the own order's tag from being entered again for `orders.backoff_days` (10)
   (`p.orders[tag]`, `st.backoff[tag]`). The kernel's memorial order (BUG-078, `act.engrave_order`) has no tag, so the removal left no
   back-off: the next daily pass found the ghost again (no memorial, no order, a blank slab counted) and made the order again. When the
   counted blank slab is one the masons cannot reach, the job cancels "Needs unengraved slab" and the cycle repeats for ever (the
   order was made, cancelled 10 times, removed, made again within a day).
2. **Running engravings are a jam.** `OF.engrave_split` and `slab_engrave` keep `blank + busy` orders (a blank slab a running job holds
   keeps that job's order, 322bd4b), but `order_ctx` `has('slab_blank')` counted `blank` only. With the kernel's order (up to
   `slabs.max_orders` 3 at a time) the three slabs of three working engravings are all `busy`, `blank` is 0, every one of the three
   orders got the reason "no unengraved slab", and `jam_scan` (`jam_min` 3, half of the shop's jobs) reported "masons' slots full of
   cancelling jobs (EngraveSlab x3: no unengraved slab)" (state `orders.jam`, status line `JAM`) for jobs that were being worked.

## Fix
- `needs_cancel` remembers the figure of a removed EngraveSlab order (`p.slab_drop[hf] = tick`, read before the order is deleted);
  `slab_engrave` skips that figure for `orders.backoff_days` and counts it in `slabs.unserved`, prunes the entries when the days are
  over. No new config key: the pruner's own `backoff_days` (10).
- `has('slab_blank')` is true while `blank + busy > 0`, as the trim counts.
- Safety: only fewer orders for a figure whose order the pruner removed; nothing is removed that was not before; an old state has no
  `slab_drop`; the entries are bounded by the removals of ten days.

## Tests (fail on c038ce9)
`tests/lua/test_economy_b2.lua`: "an order the pruner removed (10 cancels) is not made again for orders.backoff_days" (order made, ten
cancel reports, order removed, three days later no order, after the back-off the slab is ordered again) and "engraving jobs that hold the
only blank slabs are no jam" (three orders, three `in_job` slabs, three working jobs: no `orders.jam`, no ORDER_STUCK, nothing removed).

## Not decided offline
Why the masons could not reach a counted blank slab (the walk group of the slab, a burrow); `blank` still counts no reachability
(BUG-061). Live: `inspect orders` -> `slabs` (`blank`, `busy`, `unserved`), kern.log `order N EngraveSlab removed after 10 ...`.

Related: BUG-078, BUG-061, FR-10
