# Fixtures spec v3-07 (item hygiene) - SYNTHETIC

All JSON files here are **synthetic** (hand-written from the J109 measurements in the spec, not recorded live):
`lua/pilot_hygiene.lua` has not run in a real game yet. Each file carries a `"_synthetic"` note.

| File | Shape of | Based on |
|---|---|---|
| status_j109_block0.json, status_j109_block1.json | `claude/pilot_hygiene status <start> <n>` | J109: 12,549 loose stacks (BOULDER ~10,000, THREAD 930, GOBLET 410, CORPSE/CORPSEPIECE ~900) |
| status_490_marked.json | same, one block | "1 DumpItem job at 490 marks" |
| report_no_zone.json | `claude/pilot_hygiene report` | J109: no dump zone |
| report_far_zone.json | same | 1 dump zone far from the marked items, 1 DumpItem job |
| muell_status_j109.json | `claude/muell status` (live prototype) | loose boulders 7,808 (z split invented) |
| hygiene_mock.lua | DFHack mock for the Lua script | copy/variant of tests/lua_mock/dfhack_mock.lua |

Gaps: no live recording of pilot_hygiene; zones A-C coordinates unknown (only zone D z130 x86..88,y112..114 known);
no data for "stockpile full -> items on the floor" and for hauling rate per hour.
