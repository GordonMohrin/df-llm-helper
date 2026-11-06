# BUG-550 `plan check` refuses the year plan for `drink inside Kern+ lasts 50 d < 90` and demands a stockroom although no stockroom site exists
Status: fixed (offline, live-untested)
Severity: high (the year plan is not applied, PLAN STALE, nothing is built)
Found: 2026-11-06, Run 16b i2 Brotherarrow y400/y401 (`runs/run-16b/FR-BUGS.md` "BUG (KRITISCH G2) plan apply y400 unmoeglich"; `E:/DF-test2/dfllm-runtime/r16b4-brotherarrow-site97/` read only)
Module: `dfpilot/plan.py` (`check`, `stock_site`, `fort_facts`)

## Actual
After the siege of y399, `alert.core_d` (drink inside Kern+) read 50-73 d while the whole fort held 411-485 d of drink (3194 drinks in barrels outside Kern+). `plan check` ERROR `drink inside Kern+/the refuge lasts 50 d < 90 ... the doctrine minimum since the fort's first siege`; the only fix named, tpl stockroom, had no site (`bp sites stockroom` 0 ranked, `plan check` with stockroom@S1 `only 0 free sites`); a refuge_drink in the plan did not count as `stocked`. `plan apply` refused, the y399 plan stayed active.

## Root cause
`plan.check` (BUG-028): `after_siege and not stocked` -> error for core_d and core_f, `stocked` = a stockroom room in the manifest or a stockroom build in the plan. Nothing asked whether a stockroom CAN be placed, and the refuge drink store (the other barrel store inside the core, FR-69) was not counted for drink. The sites were gone for BUG-549's reason.

## Fix
- `plan.stock_site(save, state)` (in `fort_facts` as `stock_site`): `free_sites(stockroom)` has a free site; asked only while core_d or core_f is below CORE_DAYS (the ranking is not cheap); None when not asked or when there is no snapshot (unknown keeps the old error).
- `check`: for drink a standing / applied / planned `refuge_drink` (fort.refuge.drink_room, fort.refuge.drink, a plan build) counts like a stockroom; where `stock_site` is False the demand is a WARNING that says no stockroom site exists, how many days of that stock the fort holds in all (`stock.drink_d` / `food_d`) and to open room sites first (deepcore, or explore) and then add the stockroom; the `core stock: add tpl stockroom` hint is left out then. Before a siege, and with a site, the old texts and errors are unchanged.

## Tests
`tests/test_bug549_553_f35.py`: error without a site fact and with `stock_site` True, warning with False (text, 420 d of drink, no hint), refuge_drink counts for drink and not for food, `stock_site` asked only when short and False on a `0 free site(s)` refusal but None on `no snapshot`.

## Live check
`plan check` after a siege with a fort that has no stockroom site: WARN `... no stockroom site exists (BUG-550 ...)` and `plan apply` goes on; once a site exists the ERROR returns.
Open: the drink stays outside Kern+ until a stockroom is built or the stockpile is re-assigned (no verb for that, FR); the check does not read where the fort's barrels stand.
