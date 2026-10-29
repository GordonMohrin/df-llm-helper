# BUG-309 a leather mood costs a breeding pair; butcher.mark names no species or sex
Status: fixed (offline, live-untested; FR parts open)
Severity: medium
Found: 2026-10-29, Run 15d (Drillchamber, FR-BUGS Runde 2, y376 win)
Module: `lua/dfllm/economy.lua` (M.leather_trade, trade_wants, verb butcher.mark), `dfpilot/schema.py`

## Actual
Possessed mood of Atír Vabôkegul (#1926/#1929) needed leather x1; leather 0-1, hunters `nothing caught for 10 days (no game in sight?)`, only breeding pairs: `butcher.mark {"n":2}` -> `no animal to mark (8 tame ... one breeding pair per race stay)`; with Gordon's `keep_pairs:false` the reply was `1 marked for slaughter: 26280` (a stray dog, said nowhere). Root cause: economy.trade_wants asked the caravans for leather only while a mood needed it (the moods' tokens), never for the mood stock (`supply.mood_stock`, 10) that the hunters could not fill; the butcher.mark reply listed ids only and had no sex filter.

## Fix
`M.leather_trade`: leather short of the mood stock that the hides in the fort do not cover is a trade want `leather` (n <= 15, why `leather L + H hides < mood stock S`) for every caravan. butcher.mark: `sex` male/female (schema), the reply `N marked for slaughter: 26281 DOG male, 26282 TURKEY male (young)` and d.animals [{id, race, sex, adult}]. RULES row.

Not built (FR): husbandry/pasture (breeding a herd up), a bone/shell stock route (no trade token `bone`), choosing which animal of a pair goes.

## Tests
`tests/lua/test_economy_food_run15.lua` (BUG-309), `tests/lua/test_economy_chains.lua` (the leather want beside the metal wants). Fail on 9ef2ccb.

## Live check
`dfllm cmd butcher.mark '{"n":1,"keep_pairs":false,"sex":"male"}'` names species and sex; at the next caravan with leather < 10 the trade ledger lists `leather` among the wants.
