# BUG-527 Still and Kitchen missing for years (89 orders stuck) and, with 7 civilian adults, every project 'set aside, no runner slot'
Status: fixed (offline, live-untested)
Severity: high (no brewing / cooking orders for years)
Found: 2026-11-06, Run 16b i2 Brotherarrow y392-y393 (`runs/run-16b/FR-BUGS.md` "Orders: Still+Kitchen fehlen seit Jahren", "Nur 7 arbeitsfaehige Erwachsene ... alle Projekte set aside, no runner slot"; read only)
Module: `dfpilot/plan.py` (`essential_shops`, `run`), `lua/dfllm/runner.lua` (`Q.ess_scan`, `Q.ess_proj`, `sorted`, `Q.idle_keep`)

## Actual
brief: `orders 180 stuck 89 (workshop missing 4: Still x3, Kitchen x1)` although 21 shops stood; plan propose did not draft them; the workshops project that held them sat 1795 days `set aside`; with 3 slots and 7 workers nothing started.

## Root cause
(1) propose drafted Still / Kitchen only in an emergency (`emergency_drafts`: drink / food days below 30) or ahead of a dining / furnaces / tavern build (`reserve_shop_room`, BUG-461); with food for 800 days and no such build nothing drafted them. (2) The runner's queue puts the plan's older projects first (seal, care, mood, then prio / age); a workshops project of Still / Kitchen had no priority, sat behind bedrooms / tombs / explore, made no progress, and after `idle_days` was set aside (idle_keep exempted it only in a food / drink emergency).

## Fix
(1) `plan.essential_shops` (propose, after reserve_shop_room): a Still or Kitchen that no workshop of the fort manifest has, built or planned, and no workshops build of the draft or of this year's applied plan makes, is drafted as `workshops only=<missing>` at the end of seasons[0] with a BUG-527 note. (2) runner: `Q.ess_scan` (each scheduling pass) marks the live workshops projects whose manifest has a Still or Kitchen that no BUILT workshop of the map has (`S.ess_ids`); `sorted()` puts them in the hospital's class (before the plan's other projects, after seals), `Q.idle_keep` never sets them aside and brings a set-aside one back. Once the shop stands the project is ordinary again.

## Tests
`tests/lua/test_bug527_essential_shops.lua` (4: slot ahead of three older projects, no priority once the Still stands, Kitchen yes / Carpenters no, never set aside), `tests/test_bug523_527_f33.py` (4 for essential_shops).

## Live check
`plan propose` of a fort whose manifest lacks Still / Kitchen prints a `BUG-527:` line and a `workshops only=Still,Kitchen` build in seasons[0]; kern.log shows the project running while idle adults are few; `status` no longer lists it `set aside`.
Open: a workshops project that the manifest counts as planned but that is stale / set aside for years still hides the shop from propose (the manifest merges every bp file; BUG-435's stale announcement and `bp.cancel` remain the way); officials without work as builders (the other FR of that note) is not done; the `workshops` site can fail on its own (build_lost).
