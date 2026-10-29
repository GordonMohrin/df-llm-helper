# BUG-267 Orders wait 344 days for a missing workshop, nobody asks for the shop
Status: fixed (offline, live-untested)
Severity: high (cloth, rope for the hospital well, flour and charcoal never came; 37 of 55 orders stuck in Drillchamber)
Found: 2026-10-29, Run 15 Earthboat and Drillchamber (FR-BUGS.md), fix6-econ-supply
Module: `lua/dfllm/economy.lua` (`M.order_reasons` kind.wsk, `T.ocheck`, `M.ws_ask`, `M.ws_missing`), `dfpilot/wake.py`

## Actual
Earthboat: 11 orders (Loom x3, Clothier x3, Millstone x2, Quern, WoodFurnace; one is the hospital well's rope) stood 344 days
with 'workshop missing'; Drillchamber status 'orders 55 stuck 37 (workshop missing 37)'. economy only asked for the tannery,
glass furnace, fishery, the slabs' Masons, a busy shop and the farmer's workshop; 'workshop missing' reached only the brief line.

## Fix
The stuck-order pass (BUG-205's groups) knows the shop key of each missing-workshop group. A shop the workshops template places
(`M.WS_PLACE`; not Farmers/Fishery/Tanners, which have requests of their own) whose oldest order waited 14 days
(`M.WSMISS.req_days`) is asked for: one PROJECT_REQUEST workshops why=missing d.types (sorted), not for a type a pending
workshops project builds or runner's mandatory request asks; the same set again only after 14 d x 2^(k-1) and 900 s x 2^(k-1)
(k <= 4), a new type at once (`p.wsask.missing`). follow (wake.py) places only those types. An order whose shop the kernel
cannot ask for (Millstone needs power, WoodFurnace, MagmaForge, custom shops) is removed after 112 days
(`M.WSMISS.cancel_days`, act.order_remove = the work orders screen, at most 10 a day) with kern.log and one ORDER_STUCK
dropped=1 kind=workshop.

## Tests
`tests/lua/test_economy_supply6.lua` BUG-267 x2, `tests/test_bug267_271_supply.py` (follow, why=missing) (fail on 2b9c009).

## Live check
Earthboat/Drillchamber: within 14 days `dfllm events --type PROJECT_REQUEST` shows why=missing types [Clothiers, Loom, Quern];
cli.log `auto:missing` places a workshops project with only those; after 112 days kern.log 'order(s) removed after 112+ days
without a Millstone/WoodFurnace' and the orders are gone from the work orders screen.
