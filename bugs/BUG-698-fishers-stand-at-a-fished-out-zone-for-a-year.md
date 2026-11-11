# BUG-698 Fishers stand at a fishing zone with 'job none' for a year, raw fish 2600 -> 6, no second zone is ever searched
Status: fixed (offline, live-untested)
Severity: medium
Found: 2026-11-11, Run 16c i3 Wallfree y431-y433 (zone `dfllm-fish` 90-92,58-60 z143, a 3x3 pond; 'Fisherdwarves target 3, on=1', fisher 26429 'job none'; fish_raw 2616 (y426) -> 2007 -> 745 -> 6)
Module: `lua/dfllm/economy.lua` (`M.fish_dry`, `M.fish_zones`, `M.fish_start`, `M.fish_step`, `M.food_block`)

## Actual
`M.fish_start` returned at once while ANY fishing zone stood (`st.fishzone`), so the first zone was the only one for good. A 3x3 pond of a cavern fishes out; the fishers then have no Fish job, the raw fish stock falls to 0, the food decisions list no blocker ('fish_zone' only when there is NO zone) and the player sees only 'Fisherdwarves target 3, on 1'.

## Root cause
`economy.lua` `M.fish_start` (`if st.fishzone then st.fishz = {zone = true}; return nil end`): the zone is never judged by its catch.

## Fix
`M.fish_dry(c, r, zone, fishers, fish_jobs)` (daily): fishers are wanted (famine, pre-alarm or food below `want_days`), a zone stands, members are on the detail, no Fish job exists (`tool_jobs` count) and raw fish is below `fish.min` for `fishing.dry_days` (20) days in a row (`p.fishdry`, reset by the first Fish job or raw fish). Then `M.fish_start` searches again (same pacing, `scan_days`, same safety rules: no cavern water, a bank on the walk group, never on the attack path) and skips the water within 8 tiles (+-1 level) of every zone that stands (`M.fish_zones`); a second `dfllm-fish` zone is painted (kern.log 'SECOND zone (the first is fished out)'); none found: `fishz.why` = 'fished out, no second water: ...'. `M.food_block` lists the blocker `fish_dry` ('fishing: N fishers, no Fish job and no raw fish for D days: the water is fished out') for the food decisions.

## Tests
`tests/lua/test_bug697_698_famine.lua`: `fish_dry` day counting and resets; fishers on a zone with no fish: after the dry days a second zone on the other pond (x 90), none beside the old one (x 56), no third zone; no other water: no zone and the reason says 'fished out'; raw fish in the fort: no second zone.

## Live check
kern.log `fishing: SECOND zone (the first is fished out) dfllm-fish at ...` after 20 dry days; the food decisions' `block` list carries `fish_dry`. The 20 days are a judgement (a Fish job runs for days; a fisher between jobs counts as dry only when no Fish job exists on the whole job board on that day).
Open: the zone search reads the same box and levels as the first (`fishing.r` 48 around the citizens' median); in Wallfree the only other water may be cavern water (never zoned); the old zone is not removed (the fishers may still use it when the water refills). Whether the Wallfree pond was really fished out (and not unreachable) was not read from the logs: the zone's bank was on the citizens' walk group when it was painted, `stranded_drink` says the pond water is 3 tiles off their group now.
