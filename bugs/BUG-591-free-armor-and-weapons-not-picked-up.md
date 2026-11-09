# BUG-591 Free armor and weapons lie unused while the squads stand unequipped
Status: fixed (offline, live-untested)
Severity: high (a fort with 21-96 body armors "free" and squads in none; every squad stands down in a siege, soldiers 61 -> 1)
Found: 2026-11-09, Run 16c i3 Sealcertain y422 summer (96 free body armors and 8 weapons, squad A "not equipped", `squad.sortie` refused), Run 16b i2 Brotherarrow y406 (`free: 2 melee weapons, 54 body armors`), Run 16d i4 Trumpetrealms y411 (`free: 0 melee weapons, 15 body armors`)
Module: `lua/dfllm/military.lua` (`M.stock_mats`, `M.refit`, `ensure_weapons`, `stale_weapons`, `M.kit_missing`, `M.inspect.military`), `lua/dfllm/kit.lua` (`KIT.refit_plan`), `dfpilot/schema.py` (inspect `military`)

## Actual
Round 35 BUG-555 re-specs an empty armor slot to any material and only *reports* missing weapons. In the three falls the kern.log said `missing: weapon 3, body armor 3; free: 2 melee weapons, 54 body armors; the pieces lie free but are not worn` for days and nothing changed: the squads stayed bare.

## Root cause
1. `military.lua` `M.stock_mats` (and so `refit`, `best_mats`, the "free: N body armors" text) counted every item of `world.items.other.ARMOR` / `HELM` / `PANTS`, the clothes (tunics, robes, caps, trousers: raws `ARMORLEVEL` 0) included. Economy's census (`g_body`) already counted true armor only. The "96 free body armors" were mostly clothes, which no uniform slot takes; the refit believed the stock covered the squads and did nothing.
2. `kit.lua` `KIT.refit_plan` trusted the count of free pieces in the spec's own material (`own`): a metal slot with "enough free metal pieces" was never changed, even when the pieces do not fit the spec (copper or silver is metal but not the entity's armor class), and the slot stayed empty for ever.
3. `ensure_weapons` re-planned only positions with *no* weapon spec. A position with an explicit subtype spec that more positions claim than the fort holds weapons of (3 spear specs, 1 spear, 2 swords free) was never filled and never re-planned, so the swords lay unused ("8 free weapons" beside 11 bare soldiers).
4. The missing-text named neither the cause (clothes, forbidden, owned, tools held for the workers) nor the empty head/pants/gloves/shoes slots.

## Fix
- `M.stock_mats` counts true armor (`ARMORLEVEL >= 1` for body, head, pants; an unknown itemdef counts); new `M.stock_detail(cat)` (free, clothes, forbidden, owned/carried) and `M.weapon_detail()` (melee, tools held for the workers, wooden, forbidden, owned).
- `KIT.refit_plan(mems, stock, {prev, hold})`: a slot that was empty at the previous look (`rt.rfe`) as well, with pieces free in the category, goes to any material even where the own-material count "covers" it; such a slot is not sent back up to metal (`rt.rfh`). Returns the plan, the empty slots and the stuck ones.
- `stale_weapons`: a weaponless soldier whose explicit melee spec is over-claimed is re-planned (guarded: another subtype by `weapon_plan`, the over-claimed specs claim nothing; unguarded: individual choice), at most as many as spare melee weapons exist; kern.log names it.
- `M.kit_missing` adds `weapons N usable (X axes/picks stay with the workers, Y forbidden, Z owned or carried)`, `body armor N usable (54 clothes, 1 forbidden, 1 owned or carried)` and `slots empty: helmet 3, ...`.
- `inspect what=military` (read only): per squad n/fit/weapon/wood/armor/empty slots/spec material/standing down, the free stock by cause, the weapons by cause, `manager_in_squad`.
- A squad that stands down (BUG-510) gets its refit and weapon re-plan at once (`e.rf = 0`, the `wpn`/`uni` backoffs cleared) instead of after `refit_days` / the next backoff.

## Tests
`tests/lua/test_bug591_594_kit.lua` (8: stale weapon spec guarded / unguarded / no spare, true armor stock and the text, `refit_plan` stuck slots and the hold, `inspect what=military`), `tests/lua/test_fr100_kit.lua` (the refit test now expects the stuck slot at the second look)

## Live check
`dfllm cmd inspect what=military` in a fort with free armor and bare squads: `stock.body.free` is the true count, `soft` the clothes; after two refit looks (1 day apart in a danger, `refit_days` in peace) the empty slots show `any` material in kern.log (`the slot stayed empty over two looks`) and `worn` rises; a stale spear spec is replaced (`hold a weapon spec no free weapon fills`). What is still missing when nothing fits is named in the stand-down line and the `squad.sortie` refusal.
