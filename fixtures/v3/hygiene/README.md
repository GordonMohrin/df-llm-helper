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
| flow_post_siege.json | `claude/pilot_hygiene status` with flow fields (FEATURE-002) | Run 5 J122: 13,000 reachable (11,550 boulders), 1,340 webs + 850 cavern corpses unreachable |
| report_bridge.json | `claude/pilot_hygiene report` with a garbage bridge | dump landing on a raised bridge with 654 items |
| piles_bins.json | `claude/pilot_hygiene piles` | 30 bins, max_bins 147 over 12 stockpiles, finished-goods piles 57+27+21 tiles full |
| caps_crafts.json | `claude/pilot_hygiene caps` | craft cap 450 per kind, stock 3,300 over 7 kinds; goblet cap 60, blocks cap 400 |
| hygiene_mock.lua | DFHack mock for lua/pilot_hygiene.lua and lua/pilot_forbid.lua | copy/variant of tests/lua_mock/dfhack_mock.lua (stockpiles, bridges, manager orders, standing orders, workorder stub) |

Gaps: no live recording of pilot_hygiene; zones A-C coordinates unknown (only zone D z130 x86..88,y112..114 known);
no data for "stockpile full -> items on the floor" and for hauling rate per hour.
