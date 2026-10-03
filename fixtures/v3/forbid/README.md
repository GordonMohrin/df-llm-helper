# Fixtures FEATURE-003 (forbid-watch) - SYNTHETIC

Hand-written from the Run 5 incident in `Features/FEATURE-003-forbid-watch.md` (1043 forbidden own items, drinks 475,
`cancels Drink: Forbidden area`); `lua/pilot_forbid.lua` has not run in a real game yet.

| File | Shape of | Based on |
|---|---|---|
| forbid_all_barrels.json | `claude/pilot_forbid status` | Run 5: 1043 forbidden (300 containers, 743 blocks), all 475 drinks in forbidden barrels |
| forbid_none.json | same | nothing forbidden |
| gamelog_forbidden_37.txt | `gamelog.txt` excerpt | 37 `cancels ...: Forbidden area` lines (30 Drink, 7 Eat) plus noise |

The Lua tests build their items in the test (`fixtures/v3/hygiene/hygiene_mock.lua` runs `lua/pilot_forbid.lua`).
Gap: no live recording yet (the feature request asks the player for one `pilot_forbid status` answer and 20 game-log
lines with `Forbidden area`).
