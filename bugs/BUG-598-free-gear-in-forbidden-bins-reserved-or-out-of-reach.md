# BUG-598 Gear that lies "free" but no soldier can take: forbidden bins, other walk groups, reservations
Status: fixed (offline, live-untested)
Severity: high (squads fit 0-1 of 9 for years while 12-18 pieces of gear "lay free"; every siege starts with stood-down squads)
Found: 2026-11-09, Run 16a i1 Basementflew y441-y447 (`inspect what=military`: A 5 fit 0 armor 2, B 2, C 2 beside "free usable: body 18, weapons 12", unchanged three years after the round-38 reload), Run 16b i2 Brotherarrow y413 (gear 0/12 beside 27 free weapons), Run 16d i4 Trumpetrealms y428 (armor 0-1/10 beside 10 free body armors)
Module: `lua/dfllm/military.lua` (`piece_block`, `reservations`, `M.stock_mats`, `M.stock_detail`, `M.weapon_detail`, `M.release_kit`, `M.kit_bins`, `M.inspect.military`)

## Actual
Round 38 (BUG-591) made the stock count true armor only and re-specced stuck slots to any material. In the logs the same line came back every game day (`squad A: body of 2 positions to any material (the slot stayed empty over two looks ...)`, tick 180739489 and again 180754644 for the same slots): the spec was never the blocker, the pieces were not takeable.

## Root cause
`military.free_item` (military.lua:813) judged a piece by its own flags only. `stock_mats`, `stock_detail`, `weapon_plan`, `stale_weapons`, `free_weapons` and the missing-text counted as free what
1. lies in a **forbidden bin or chest** (DF treats the contents of a forbidden container as forbidden; economy has read this for drink and food since FR-50, economy.lua:965, but never for gear; the trade module found 136 crafts in forbidden bins in the same fort, `bin_forbid`),
2. lies on **another walk group** (the flooded z117 complex of Basementflew; economy's census has `w_*_far`, military never asked `snapshot.far`),
3. was **made by another race** (looted goblin armor),
4. is **reserved by DF for a squad position** (`plotinfo.equipment.items_assigned`): a vacant position (squads have 10 positions, 2-5 occupied), no position at all, or an occupied one whose soldier never fetched it,
5. is **worn by a soldier already** (a squad member's piece passed `free_item`, so worn armor inflated the stock the refit compared with the empty slots).

## Fix
- `piece_block(it)` (new) names why a piece that passed `free_item` is no stock: `worn`, `bin`, `far`, `alien`, `reserved`, `stuck`. `stock_mats` counts the rest only; `stock_detail` carries `worn bin far alien reserved stuck`; `weapon_plan`, `stale_weapons`, `free_weapons` use `free_weapon` (reachable, in no forbidden bin; worn weapons still count, their specs are the claims).
- `M.release_kit` (upkeep, every `REL_EVERY` 1200 ticks, at most `REL_MAX` 30): armor and melee weapons that DF keeps assigned to a vacant position or to none (waited `ORPHAN_MIN` 1200 ticks) or that the soldier of an occupied, on-duty position has not fetched for `PEND_MAX` 2400 ticks go back to the stock through `act.squad_release` (the squads screen's unassign; DF hands them out at its next equipment update). A piece released `STUCK_AFTER` 2 times and still lying is written off (`rt.stuck`: not stock, named). An off-duty militia squad keeps its kit reserved.
- `M.kit_bins` (PEACE, or RECOVERY with no hostile in sight, every 3600 ticks, at most 10): a forbidden bin or chest on a tile the citizens reach that holds nothing but gear is unforbidden (`act.item_flag`, the loot pass' rule for single items).
- The missing-text, the stand-down line and `inspect what=military` name the causes (`N in forbidden bins`, `on another walk group`, `made by another race`, `reserved for a squad position`, `released and still lying`); inspect adds `out_of_reach`, `reserved {pending, released, stuck}`, `training_free`.

## Tests
`tests/lua/test_bug598_599_kit_reach.lua` (7: the stock by cause; `release_kit` for a vacant position and an orphan, then `stuck`; `kit_bins` pure gear vs a bin with food; the Run 16a i1 live state rebuilt (12 free melee weapons, 18 "free" body armors of which 6 in a forbidden bin and 6 reserved for vacant positions); inspect), `tests/lua/test_bug591_594_kit.lua` unchanged, `test_fr100_kit.lua` (its world now stocks wooden weapons, BUG-599)

## Live check
`dfllm cmd inspect what=military` on a fort with free gear and bare squads: `lying free but out of reach: N bin, N far, N alien, N reserved` explains the difference between "free" and what the squads wear; kern.log `N gear pieces DF kept assigned to a squad position that does not wear them given back` and `N forbidden bins or chests of gear unforbidden`; `worn` rises within a few game days where pieces were really free. If `stock.<cat>.free` stays > 0 and the slots stay empty after two `release_kit` rounds, the next cause is DF's own match (size / material), not a dfpilot one: `stuck` counts those pieces.

## Open
Which of the five causes was the live one in each fort is inferred (the runtime logs hold counts, not item flags); `alien` (a piece with `maker_race` other than the fortress race does not fit) and DF's handling of an item in a forbidden bin are inferred from the game's rules, not verified live. A reservation of an occupied position released again by `release_kit` may be handed to the same soldier by DF; the `stuck` counter then writes it off after two rounds.
