# BUG-585 `zone.place type=office` draws an empty zone; the manager-stuck warning comes after 14 (in practice 24) days
Status: fixed (offline, live-untested)
Severity: high (a manager who validates nothing stops brewing and forging)
Found: 2026-11-09, Run 16b i2 Brotherarrow y406 (manager Onget 48 days, office zone 17764 outside Tiefe+, the refuge zone 18786 empty)
Module: `lua/dfllm/zonelib.lua` (`Z.office_furniture`, `Z.verb`), `lua/dfllm/economy.lua` (`orders.mgr_stuck_days`), `config/baseline.json`

## Actual
The refuge office zone existed with no chair and no table; the question about the stuck manager came 24 days after the orders began to wait.

## Root cause
`zonelib.lua` `Z.verb` only drew the zone; the furniture was added only by `economy.office_check` for an office the manager owns. `mgr_stuck_days` was 14.

## Fix
`zone.place type=office` places the chair and the table the zone lacks on free floor tiles of it through `runner.repair` (buildingplan waits for the items), the chair beside its table, answers `...; chair at x,y,z, table at ... placed` (`data.furniture`) or `no chair/table: <why>`; `orders.mgr_stuck_days` 14 -> 5.

## Tests
`tests/lua/test_zone_place.lua` (+1), `tests/lua/test_economy_drink.lua` (manager_stuck after 5 days; the BUG-458 tests keep 14 by config)

## Live check
`zone.place type=office bbox=...` in the refuge: furniture placed, answer names the tiles; a stuck manager is asked after 5 days.
