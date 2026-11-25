# BUG-889 Container reserve switched off for good at total_cap; the way-out text did not say where the stone is
Status: fixed (offline, live-untested)
Severity: medium
Found: Run 17 i3 / i4: 'container reserve: total_cap 200 reached (201 ordered) ... nothing more is ordered' while DF still cancels brews; i1: 33 boulders, all built into buildings, 'none is free (held by a job, out of reach or reserved)'; i3 109 boulders with 0 usable (claystone, mudstone, chalk, sandstone are refused as non-economic hard stone).
Module: `lua/dfllm/economy.lua` (`M.plan_reserve`, `M.rsv_year`, `M.reserve_dead`)

## Root cause
CONFIRMED (C5 and the cap line): `RESERVE.total_cap` was compared with the cumulative `made` count, so after 200 containers the reserve never ordered again. The census-vs-DF stone difference was already handled by the kernel's own usable-stone test (`M.reserve_stone` / `hard_denied` = isSuitableMaterial, BUG-879, 0 usable on i3), so the reserve does not plan rock barrels from a boulder count; what was missing was the cap as a rate and the statement.

## Fix
`total_cap` is containers ordered per game year (`M.rsv_year`: `rs.wn` since `rs.wt`, starts over RESERVE_YEAR_D = 336 days after its start; the old cumulative `made` stays for the log; a taken-back batch leaves the count). The weekly 'nothing to make them of' line splits the boulders: built into buildings / forbidden / dumped, out of reach, held by jobs, ore/flux/economic/soft; and names the way out 'trade.want wood at the next caravan (the fort asks for it itself: stock.want, barrels are wood)'. NOT built: a Kiln large-pot order (MAKE_LARGE_CLAY_POT, diagnosis C6) or glass/metal containers: untested reaction, no workshop fact for a Kiln in the kernel; left for a live-tested round.

## Tests
`tests/lua/test_bug887_891_fass.lua` (201 ordered inside the year: capped with the per-year line; 340 days later it orders again, `wn` = the new batch; i1: one weekly line with '33 boulders exist but none is free: 31 built into buildings...'), `tests/lua/test_bug854_reserve.lua` (cap test uses `wn`).

## Live-Erwartung
i3/i4: after the first game year of the cap the reserve orders again while DF cancels for containers; i1: one weekly kern.log line says the boulders are in buildings and that wood is asked from the caravans. NOT promised: i1 gets containers without any material (no logs, no usable stone, no trade): the line and the trade want are all the kernel can do; no clay/glass/metal pots.
