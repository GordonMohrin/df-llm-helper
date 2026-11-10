# BUG-691 A start with not one free usable boulder drafts the shaft and the depot, no stone dig, no wood and block from the caravan
Status: fixed (offline, live-untested)
Severity: high
Found: 2026-11-10, Run 16b i2 Rocksblush y414-y415 (state stock rock 0, rock_need 6; first plan seasons[0] = aqshaft, seasons[3] = tradepost) and Whirledrampart (34 boulders, 0 usable: 21 economic / soft, 21 ore / flux)
Module: `dfpilot/plan.py` (`start_dry`, `propose`, `quarry_fallback`, `stone_first`)

## Actual
`inspect workload`: 'no rock, no blocks, no logs'; the shaft stage l1.dig 'waits (no stone for the plug and the soil walls)', five depot projects finished and a sixth `build_lost` for lack of material, 'useful backlog empty: no action' with 6 of 7 adults idle. The draft carried no stone dig: `rock_goal` needs `rock_need > rock` (0 at the first plan), the bedrooms dig was left out by `fit_stone_dig` (no Z4 floor yet), and `quarry_fallback` (the explore quarry) ran only after a MATERIAL_SHORT event, which the first waiting build produces later. `trade.want wood,block` came only with that event too.

## Root cause
`plan.py` `propose` (stone block, `rock_goal` / `famine.rock0`) and `quarry_fallback` (`fam.short and fam.rock0`) all waited for a signal that a dead start does not give before its first build waits. The census (BUG-665) already counts only stone a job can take, so `stock.rock == 0` is the exact state of both forts.

## Fix
`plan.start_dry(state)`: phase <= P2 and `stock.rock == 0` gives the reason text. `propose` drafts the stone dig (`STONE_DIG`) on it, `quarry_fallback` runs on it (the explore quarry when no bedrooms site), `stone_first` (BUG-497) already puts the dig before the shaft and the depot, and the draft's `trade.want` starts with wood, block (as BUG-430 does once the shortage is logged). Tree cutting stays autochop's (`baseline.lua` sets its target at boot; `economy.chop` follows); with no tree on the map there is nothing to order: the caravan list and the dig are the way out.

## Tests
`tests/test_bug690_691_f44_start.py`: `start_dry` (phase, zero, unknown), `propose` (dig + trade.want + note, nothing with stone or with a dig under way), `quarry_fallback` without a logged shortage, `stone_first` puts the dig before aqshaft / depot.

## Live check
`plan propose` on a fort with `stock.rock 0` in P0: notes carry `BUG-691: start: no free usable boulder ...`, the first season starts with bedrooms / explore, `trade.want` starts wood,block. With free boulders the notes and list are unchanged.
Open: with no Z4 floor and no explore site at any depth the draft still has only the shaft (the notes name the missing site; the shaft's own dig through hard stone yields the first boulders); a start-time stone dig on open ground (no core) is not a template (`surfacecore` builds from constructed walls).
