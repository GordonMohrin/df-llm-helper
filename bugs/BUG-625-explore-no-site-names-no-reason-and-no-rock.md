# BUG-625 `explore: no site at depth 2..12` for years in a mudstone fort, with no word on what blocks or which rock the probes saw
Status: fixed (offline, live-untested); open: explore still starts only from the public floor of the core
Severity: medium (no ore, no hard stone, no flux for 5 years; the player could not tell a full core from a bad rock)
Found: 2026-11-09, Run 16d i4 Trumpetrealms y430-y433 (`plan propose`: 'no site at depth 2..12: not drafted'; `bp sites explore` 'no free rock for it beside the core ... [1205 anchor tile(s): 566 have a shaft ... that meet the core's own open rooms ...]')
Module: `dfpilot/bp/sites.py` (`_explore`, `_fail_why`, `_geo_text`, `_explore_none`), `dfpilot/cmd.py` (`explore_rocks`, `explore_rock_note`, `rank_sites`), `dfpilot/plan.py` (`fit_explore`)

## Actual
Replayed offline on the Trumpetrealms sites snapshot (z131-z146, 40 earlier probes): all 1205 explore anchors lie on two core levels (z136, z139); 4038 door tiles are not rock; 566 anchors have a door and every one is refused by geometry. The message said only that the shaft 'meets the core's own open rooms, water or a mark'.

## Root cause
Anchors are only the public Z4 floor of the core (`_anchor_tiles`); round it the 3x2 shaft top (anchor level) and the tile two levels down are already open or built (earlier probes' stairs, rooms): 421 anchors refused on the anchor level, 145 two levels down. The ranking did not say so, and the rock the finished probes saw (PROJECT_DONE `rocks`, BUG-584) was not shown anywhere a failed ranking is read.

## Fix
(1) `_explore` counts the first refusal of each anchor by (anchor level, kind: open / mark / wet / map edge, shaft level `w`); `_explore_none` adds `[BUG-625: explore starts only from the public floor of the core, level(s) z136, z139; the shaft was refused by: 268 anchor(s) of z136: an open or built tile on the anchor level; ...]`. (2) `cmd.explore_rocks` reads the `rocks` of the PROJECT_DONE events of finished explore probes (per rock: lowest / highest z, probes); a failed explore ranking (`rank_sites`) ends `the finished probes saw (PROJECT_DONE rocks): MUDSTONE z134-z138, CLAYSTONE ..., LIMESTONE z130; none went below z130; flux stone seen: LIMESTONE z130 (dig there for flux, or trade.want flux)` (or `no flux stone and no ore seen: trade.want ore, bars, flux`). (3) `plan.fit_explore`'s final line and the plan note carry both when no depth has a site.

## Tests
`tests/test_bug623_625_f40_econ2.py` (5 for BUG-625)

## Open
No site farther away or deeper is found: an anchor outside the core's public floor (the bottom of an earlier probe, a new core level) is not ranked. The explore needs a new core level (deepcore / fortcore) or the caravans; the message now says which.
