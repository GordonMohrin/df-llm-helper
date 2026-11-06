# BUG-515 forge slots clogged by cancelled MakeWeapon jobs, the hospital chain waited 99 days
Status: fixed (offline, live-untested)
Severity: high (the hospital's well waited for its chain; every order behind the forge stood)
Found: 2026-11-06, Run 16c i3 Sealcertain y385-y386 (`runs/run-16c/FR-BUGS.md` 'Hospital-Kette: Forge-Slots durch abgebrochene MakeWeapon-Jobs verstopft')
Module: `lua/dfllm/economy.lua` (`jam_scan`, `order_prune`), `lua/dfllm/water.lua` (`chain`)

## Actual
brief: `JAM forges slots full of cancelling jobs (MakeWeapon x3: no bars:INORGANIC:BRONZE)`, `well 18341 waits for a chain (7 BISMUTH_BRONZE bars) on order 576`: the forge's job list was full of bronze weapon jobs of library orders (no BRONZE bars for 180 days) that DF cancelled and made again; the MakeChain order for the well never got a slot (99 days set aside). `jam_scan` (BUG-061) named the jam and gave its victims the reason, but nothing removed the orders that caused it; `order_prune` (BUG-315) took only duplicates and orders above the cap.

## Root cause
`economy.lua` `jam_scan`: the orders whose jobs fill the jammed shop (`blocked`) were only counted, never kept; `order_prune` had no rule for them. `water.lua` `chain`: the chain order was entered at the end of the work orders (no `top`).

## Fix
- `jam_scan` keeps the culprits per jammed shop (`oq.jamc`: the orders whose jobs in that shop are blocked by a missing input or worker); `order_prune(K, c, p, now, oq)` removes them under its own rules: one-time orders only, stuck for `orders.stuck_days`, never a PRUNE_KEEP job or tag (chains, coffins, mood orders, pieces), at most `prune_per_day`; a standing order stays. kern.log / ORDER_STUCK (kind `prune`) say `jam: MetalsmithsForge 3`; the tag of a removed own order waits `backoff_days`.
- `water.chain`: the MakeChain order gets `spec.top = true` (first in the work orders).

## Tests
`tests/lua/test_bug515_forge_jam.lua` (2: three bronze weapon orders that fill the forge are removed, the standing one and the victims stay; no jam, no removal), `tests/lua/test_bug262_266_water.lua` (+1 assertion: the chain order has `top`).

## Live check
`inspect orders` JAM line gone after a day or two; ORDER_STUCK kind prune with `jam: <shop> N`; the well's chain order runs. Open: a standing (daily/monthly) order that is the culprit is not removed, only named by the existing JAM line.
