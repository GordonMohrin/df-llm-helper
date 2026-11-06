# BUG-525 Armor orders stay in BISMUTH_BRONZE / BRONZE while 28-30 iron bars lie unused, soldiers 0 % armor
Status: fixed (offline, live-untested)
Severity: high (soldiers without body armor and helms for years)
Found: 2026-11-06, Run 16c i3 Sealcertain y395-y397 (`runs/run-16c/FR-BUGS.md` "Ruestung 0 trotz 30 Barren"; kern.log `gear: ... body 0/5+1 ordered, head 0/5+2 ordered`; gamelog `cancels Forge bismuth bronze breastplate: Needs 3 bismuth bronze bars` 37x; read only)
Module: `lua/dfllm/economy.lua` (`plan_gear`, `M.gear_wrong_metal`)

## Actual
`gear.metals` is STEEL, IRON, BRONZE, BISMUTH_BRONZE, COPPER, so a new order goes to iron first, yet body/head stayed `ordered` with an order in bismuth bronze that DF cancelled every day.

## Root cause
`plan_gear` plans a slot only when no order of its tag is open (`open(r, tag)` -> `route = 'ordered'`). The open order keeps the material it was entered in; when its bars are used up (bismuth bronze made one breastplate, the rest went into the well chain) it cancels 'Needs 3 bismuth bronze bars' for ever (needs_cancel counts per 7 days and removes only after `orders.needs_drop` 10 cancels in one window) while the slot never looks at the iron bars again. Reproduced offline: the test world shows `body 0/2+1 ordered, head 0/2 metal:IRON` with the old code.

## Fix
`M.gear_wrong_metal`: for an open gear order of a metal slot, read its material token; when the stores hold fewer of its bars than one piece takes AND another metal of `gear.metals` could be ordered right now by the very rules the planner uses (`left(bars:TOKEN) >= bars`, `left(bars) >= bars`), remove the order (act.order_remove), free its tag, give its pieces back to `miss` and plan the slot again in the same pass (iron first). kern.log: `gear body: order N in BISMUTH_BRONZE removed, 0 bar(s) of it left and IRON has them: planned again`. An order whose bars are still there, or when no other metal can be ordered, is left alone.

## Tests
`tests/lua/test_bug525_gear_metal.lua` (2: bismuth order replaced by an iron one, left alone while its bars are there / when nothing better exists).

## Live check
A fort with `gear: ... body 0/N+1 ordered` and gamelog cancels naming a metal it no longer has: kern.log shows `gear <cat>: order N in X removed ... planned again` and the next `gear:` line `metal:IRON`.
Open: the 'left bars' floor (mood reserve) can keep the planner from ordering iron too; then the wrong order stays as before (nothing better can be planned). Melting the surplus weapons is not done; DF's own library/military orders are not touched (BUG-515 clears their jam).
