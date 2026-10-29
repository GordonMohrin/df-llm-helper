# BUG-241 plan propose drafts explore in every season although only one or two explore sites are free
Status: fixed (offline, live-untested)
Severity: high (the draft fails `plan check` with ERROR "only 0 free site(s) for explore", so the year's plan waits for hand edits)
Found: 2026-10-29, Run 15: Earthboat y374/y375, Inkintense y373/y374 (FR-BUGS.md)
Module: `dfpilot/plan.py` (`draft_supply`, `fit_explore`, new `explore_room`)

## Actual
While the fort had no ore, `draft_supply` put `explore@S1` into every season from the current one. `fit_explore` only checked
that a depth with at least one ranked site exists. The apply places the builds one after another, so the second explore found
the first one's site taken: check refused the draft, "taken by y375s0b0" (Earthboat, 1 site) and "taken by ... y373s0b0, y373s1b0"
(Inkintense, 2 sites). The draft also put the explore ahead of a new seal ("seal comes after explore: seal first").

## Fix
`explore_room(save_dir, sites, params)` emits each ranked site of the chosen depth and counts the ones whose footprint touches no
project in `<save>/bp` (applied and kept ones too) and no explore counted before it. `fit_explore` keeps only that many new
explore builds (the earliest seasons') and removes the rest; the line and the notes say "N free site(s): N of M drafted, the next
one: propose next season". With 0 free sites (Earthboat y374: a `bp.place workshops` took the only one) no explore is drafted,
so the draft no longer collides with itself. `draft_supply` puts the explore after the season's new seals and after the water and
food builds BUG-243 puts first. Not changed: `cmd bp.place` of other templates can still take the only explore site (cmd.py).

## Tests
`tests/test_bug241_244_plan_propose.py`: `test_explore_room_counts_sites_that_fit_together`,
`test_fit_explore_drafts_only_as_many_as_free_sites`, `test_draft_supply_puts_the_explore_after_a_new_seal` (fail on 6dc0f19).

## Live check
In a fort with no ore: `dfllm bp sites explore --fresh`, then `dfllm plan propose`: the printed line ends "K free site(s): K of
M drafted" when fewer sites than seasons are free, the draft holds K explores, and `plan check` has no "only 0 free site(s) for
explore" ERROR.
