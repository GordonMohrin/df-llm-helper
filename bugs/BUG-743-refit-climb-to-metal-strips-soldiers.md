# BUG-743 The uniform refit climbs back to metal and strips the soldiers (worn 76 % -> 21 %); unfetched kit counted as gear
Status: fixed (offline, live-untested)
Severity: high
Found: 2026-11-11, Run 16d i4 Pagedsculpture y384-y403 (FR-BUGS: 'Soldaten nehmen Ruestung nicht auf (fit 0, armor 0 bei body 13 frei)'; state mil.kit armor 1 of 5 soldiers, weapon 0, free body 27, bars 178, worn 18 %); Run 16a i1 Basementflew (worn 28 %)
Module: `lua/dfllm/kit.lua` (`refit_plan`), `lua/dfllm/military.lua` (`M.refit`, `M.RF_HOLD`, `release_kit`, `stuck_ids`, `item_why`), `lua/dfllm/economy.lua` (`M.wearable`, census `stuck`)

## Actual
i4 `kern.log` / `commands.log`: 139 `act.squad_uniform` calls in the log; 'squad A: pants of 3 positions to metal material (free metal pieces cover them)', 11,000 ticks later 'to any material (the slot stayed empty over two looks ...)', again 'to metal' (ticks 158937338 / 159193224 / 159577349 / 162484919 / 162513719 / 162808289 for shoes, gloves, body, pants); the worn % read 76 -> 12-26 -> 76 across them, with 178 bars, no metal ore and 5 metal pieces in the fort (`stock.metal ''`, `mfree 5`). 'N gear pieces DF kept assigned ... given back (... unfetched for 2400 ticks by the soldier of an occupied one)' again and again.

## Root cause
1. `kit.lua` `refit_plan`: a soldier wearing a soft (non-metal) piece in an `any` slot goes UP to a metal spec as soon as `stock.metal >= slots` (the `up` branch). The hold that keeps a slot from climbing (`opts.hold`) was filled only for the BUG-591 'stuck' slots, never for the plain down move. The stock counts every metal piece (copper, silver) although the uniform spec's armor class takes only the entity's armor metals, so the metal spec stayed empty, the refit moved the slot down again and the cycle repeated; every replace of a spec makes DF drop what the soldier wears.
2. The other side of the worn swing is not a kit defect: a squad that goes `Ready` with a station order for a drill or an alert re-equips (the i4 gear lines read 12 % right at a drill start and 76 % a day later; commands.log 159573749 `squad_routine Ready` / `squad_order station`). The kernel's defense hold read that instant value (BUG-742: now the 45-day median).
3. A piece DF keeps assigned to a squad position and nobody fetches (released STUCK_AFTER times and still lying, or reserved for an occupied position and lying on another walk group than the squad's soldiers) still counted as a piece of the fort's gear in the census, so the slot read 'ok' and no fresh piece was ordered while the soldier stayed bare ('body 25/3 ok' beside armor 1).

## Fix
- `kit.refit_plan` returns a fourth result `freed` (every position moved down to any material). `M.refit` keeps `rt.rfh[squad][cat][pos] = {t, n}` for those and the stuck ones, persisted in the squad record (`e.rh`, `M.refit_hold_save/load`); a position stays off the climb to metal `M.refit_hold_ticks(n)` = `RF_HOLD` (72,000 ticks = 60 game days) x 2^(n-1), at most `RF_HOLD_MAX` (8x); records are dropped after twice that.
- `M.stuck_ids` (stuck pieces plus `rt.unreach`: pieces reserved for an occupied position that lie on another walk group than the squad's `home_group`) feeds the census (`acc.stuck`); `economy.wearable` does not count them, so the slot reads missing and a fresh piece is ordered. `M.item_why` names a soldier standing on another walk group than the piece; the release log says how many lie off the squad's group.

## Tests
tests/lua/test_bug743_744_refit_climb_thirst_cycle.lua (5 for BUG-743: `freed`, the climb waits for a held position, the hold grows with repeats and survives JSON, the refit writes `rh`, `stuck_ids`), tests/lua/test_bug689_gear_census.lua (`wearable` stuck). No alert, lockdown, drill, bridge or siege behaviour changed (a uniform material in PEACE upkeep and a census count).

## Open
Not proven live: which pieces of the older Trumpetrealms reading ('37 bin, 8 alien, 29 reserved') apply to Pagedsculpture now (its census says body 26/3 ok with no alien piece); the unreachable-piece rule reads snapshot walk groups. The 60-day hold and the 8x cap are judgements. A Kernel reload is needed.
