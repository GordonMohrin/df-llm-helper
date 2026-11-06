# BUG-530 `plan propose` leaves the year empty for years when explore and aqshaft find no site
Status: fixed (offline, live-untested)
Severity: medium (Plan y393/y396/y398/y399 "leer", Run 16a y407 "0 Bauten", Run 16c y387+: the fort did not grow, 15 of 38 adults idle)
Found: 2026-11-06, Run 16d i4 Trumpetrealms ("Plan y398 leer: explore/bedrooms ohne Sites"), Run 16a i1 y407, Run 16c i3 y387-y397 (`runs/run-16*/STAND.md`, `FR-BUGS.md`)
Module: `dfpilot/plan.py` (`offer_growth`, `OFFER_ALTS`, `run`)

## Actual
The phases' deliverables were done, parked or out of reach, `fit_explore` / `fit_placeable` removed the builds that found no site, and the draft ended with no new build. The player applied an empty plan year after year.

## Root cause
`propose` only drafts what the phases ask for (each deliverable once, `done` filter); nothing took over when everything it drafted was dropped by the placement fits. Together with BUG-528 (explore found no site) the year was empty.

## Fix
`plan.offer_growth` (run by `plan propose` after `fit_placeable`): a draft that adds no build at all (and a fort not under the rebuild policy) puts the alternatives of `OFFER_ALTS` into the current season, best first: bedrooms n=4 (beds for growth), stockroom (a stockpile room), dining, tavern, workshops; each is placed the way `apply` would (`fit_placeable`) and dropped when it finds no site; at most `OFFER_MAX` (2) stay. The line goes to the CLI and the notes ("BUG-530: the draft would add nothing (explore / aqshaft found no site): offered instead bedrooms@S1 n=4 (beds for growth), ..."); when none finds a site it says so and names `bp sites bedrooms --fresh` and `trade.want stone, block, wood`. The player strikes what he does not want; `plan check` judges the draft as any other.
Not done: `follow`'s minimal plan (`auto_plan`) keeps its rule (seal, tombs, hospital, food/drink, refuge only); the alternatives are offered to the player's `propose`.

## Tests
`tests/test_bug528_531_f33.py` (an empty draft gets bedrooms n=4 and the stockroom, the dining room that finds no site goes again, at most two; nothing finds a site: said; a rebuilding fort and a draft with builds: nothing).

## Live check
`dfllm plan propose` in a fort whose phases deliver nothing new: the summary lists `bedrooms@S1 n=4` and a second room, the line `BUG-530:` under the draft.
