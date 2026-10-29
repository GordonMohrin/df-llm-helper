# BUG-224 A made-again order flips rock/wood; a busy shop changes the material class
Status: fixed (offline, live-untested)
Severity: medium
Found: 2026-10-29, live round 4 (i-test3 Earthboat) and skeptic (BUG-201 residual)
Module: `lua/dfllm/economy.lua` (`wood_orders`, `T.stale`), `dfpilot/wake.py` (follow placement)

## Actual
kern.log: `order 644 ConstructChest x2: ... re-entered in wood`, then ORDER_STUCK `order 644 ... stale ... (Carpenters: 1 shop,
5 jobs (1 working), none from this order): made again in stone` (new order 650), 3 s later `order 650 ConstructChest x2: rock ->
wood (33 boulders, 274 logs)`, then `650 ... made again in stone`, and so on. One Carpenters shop held all jobs while 35
citizens with the CARPENTER labor stood mostly idle.
Causes: (1) `wood_orders` (live L3, free boulders < `boulders_below` 20) switched every open one-time rock order to wood and
never read the BUG-201 mark `p.ostale[id].sw` or the made-again mark; (2) `T.stale` made a stale wood order again in stone at
`stone_free >= left + 10`, overlapping wood_orders' 20; (3) the stale reason was the busy shop, not the material; (4) the stale
record was rebuilt without `sw`/`redo` whenever a job of the order stood in a shop (or the amount changed), and dropped when
the order left the stale pass for a while.

## Fix
- `M.stale_mark(p, id)`: sw == 1 or redo > 0. `wood_orders` skips marked orders.
- `T.stale` keeps `sw`, `redo` (and `told` while the amount stays) when it rebuilds a record; a marked record of an order that
  still exists survives a pass outside the stale scan.
- `M.shop_busy`: the order's shop type holds other jobs (>= one a shop): the made-again order keeps its class. Stone only at
  `stone_free >= left + max(10, boulders_below)`, so wood_orders never undoes it.
- `M.busy_request`: >= 3 waiting jobs a shop (jobs - working) and an idle citizen with the labor (Carpenters: CARPENTER,
  Masons: MASON) -> PROJECT_REQUEST workshops `why=busy` `types=[Carpenters]`, at most every `food.request_days` and 15 min,
  not while a workshops project builds that type. follow places it like `mandatory`/`slabs` (skip = the other moodable
  types, `need` keeps it although the manifest lists one).

## Tests
`tests/lua/test_economy_b2.lua` (three BUG-224 tests), `tests/test_bug224_busy_shop.py`; each fails on 5e9e719.

## Live check
On Earthboat (port 5002) with a stale stone/wood furniture order: kern.log shows no `rock -> wood` for an order id that had a
`made again` line before; a stale wood order in a full Carpenters shop is `made again` (not `in stone`); `dfllm events --type
PROJECT_REQUEST` shows one `workshops: one more Carpenters (1 shop, N jobs waiting, M idle carpenter)` with d.why busy, and
follow places a second Carpenters (cli.log auto:busy).
