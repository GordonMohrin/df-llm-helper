# BUG-556 A metal gear order that makes nothing for days is never given up for leather (armor 0 with leather in the stores)
Status: fixed (offline, live-untested)
Severity: high (soldiers worn 11 % for years; a manual leather order raised worn to 87 %)
Found: 2026-11-06, Run 16c i3 Sealcertain y395-y401 (`runs/run-16c/FR-BUGS.md` "Ruestung 0 trotz 30 Barren", "Leder-Ruestung per order.add (material_category leather) wirkte sofort: gear body 4/5, head 3/5, worn 11 % -> 87 %"; kern.log `gear: ... pants 4/7+1 ordered, gloves 1/14+8 ordered, shoes 10/14+2 ordered` for days; read only)
Module: `lua/dfllm/economy.lua` (`plan_gear`, `M.gear_stale`, `M.gear_leather_hold`)

## Actual
The planner tries the metals of `gear.metals` first and leather (and wood/bone) only when no metal route exists (`rec.route == 'none'`). An open metal order is `ordered` for ever: BUG-525 replaces it only when its bars are gone and another metal can be ordered. An order that stands but never runs (bars under the mood-reserve floor, the forge busy or jammed, no worker) kept the slot at `ordered` while leather lay in the stores.

## Root cause
`economy.lua` plan_gear: `if open(r, tag) then rec.route = 'ordered'` has no age, no progress check and no look at the other materials. Parts of the report that are not this bug: the wrong-metal order (bismuth bronze order, iron in the stores) is BUG-525 (`economy.lua:2220` `gear_wrong_metal`, called at `:2252`), already fixed; the 17 x "Forge iron war hammer/mace/spear/short sword" that took the iron bars were not `dfllm:gear_*` orders (the planner's only weapon slot is the spear and `miss` is 0 with 27 free, so it orders none), they come from the manager list outside the planner and are not touched here.

## Fix
`M.gear_stale`: per slot the planner watches the pieces at hand (`r.p.gstale[cat]`: `h`, `t`, `seen`); an open **metal** order (material INORGANIC) of a slot with a leather route (`it.leather` and a Leatherworks) that raised nothing for `gear.stale_days` (12) game days is removed (`act.order_remove`) when leather for one piece is at hand, and the slot is planned again in the same pass; `M.gear_leather_hold` then skips the metal route for that slot for `gear.leather_days` (30) days while leather lasts. kern.log: `gear body: metal order N (IRON) made nothing in 12 days, K leather at hand: leather first for 30 days`. A gap of more than 3 days in the watch starts a new look. Without leather, without Leatherworks, or for a leather/wood/bone order nothing changes.

## Tests
`tests/lua/test_bug556_gear_leather.lua` (iron order removed after 12+ days and entered again in leather, kept before; no leather: kept).

## Live check
A slot with `ordered` in the gear line for 12+ days and tanned leather in stock: kern.log shows the line above, the next gear line `body ... leather`.
Open: `gear.stale_days` / `gear.leather_days` are code defaults (not in config/baseline.json); the surplus-weapon orders are outside the planner (`orders.cancel` can remove them).
