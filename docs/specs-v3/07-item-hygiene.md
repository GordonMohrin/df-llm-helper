# Spec v3-07: Item Hygiene (`dfpilot hygiene`)

Priority: P1 | As of: 01.10.2026 (Run 5, Y109) | Status: implemented (v3), not yet live-tested; Lua `claude/muell` exists (live prototype), new `lua/pilot_hygiene.lua` | Framework: see `../specs-v2/README.md`

## Goal and Benefit
Keep loose items under control (performance, miasma, overview). Measurement Y109: 9,823–12,549 loose stacks outside stockpiles (BOULDER approx. 10,000, THREAD approx. 930, GOBLET 410, CORPSE/CORPSEPIECE approx. 900, remains), no dump zone, dump jobs hardly ran (1 job). The build and economy agents built zones and marks by hand.
**Expected gain:** relieves pathfinding and FPS (> 10,000 loose items), prevents miasma/mood penalties, approx. 10 manual calls saved per action.

## The Player's Rules (binding)
- **Never mark boulders as garbage or dump them** (stone is building material). Only propose extra stone stockpiles.
- Do not dump trade goods (goblets, crafts, thread); instead stockpiles with room/containers and an order cap.
- Plump helmet rules apply unchanged.

## Measurement (`pilot_hygiene.lua`, read only, in blocks)
Loose stacks by type, level and reachability (`canWalkBetween` from the fort); corpse count with location (fort/surface/cavern); growth rate per type (from `state.db`).

## Rules
1. **Dump zones** (garbage dump; items stack without limit on one tile = quantum principle without machinery; minecart quantum is unnecessary here): one zone (3x3) per hall group in dead corners, plus one zone **near the refuse room/crypt/barracks** (economy: zone D z130 x86..88,y112..114), away from living, kitchen, water and food areas. The location is proposed, not built automatically.
2. **Marking rules** (UI `flags.dump`, in portions of ≤ 300 per cycle so haulers are not blocked): corpses/parts/remains of enemies and animals, plant remains/rotten food, broken items. **Exceptions:** boulders, dwarf corpses (burial/coffins), bones and skins (crafts), trade goods (incl. thread), weapons/armor (barracks stockpile).
3. **Check effectiveness:** number of `DumpItem` jobs and removals per hour; if it is < 10 % of the marks, show the cause (zone too far, haulers busy, path blocked) and propose a closer zone.
4. **Cap instead of clean-up:** standing orders that produce garbage (goblets, crafts) get a stockpile cap (`orders.lua`: goblets ≤ 60); report when a stockpile is full and items land on the floor.
5. **Dwarf corpses:** check coffin stock and burial (`gesund krypta`), report ghost risk.
6. **Digest:** `loose stacks 12.5k (+200/h): boulders 10k (ok), corpses 900 (dump 6 jobs), goblets 410 (cap)`.

## Configuration
`hygiene: {mark_batch: 300, exclude_types: [BOULDER, BAR, WEAPON, ARMOR, CRAFT], keep_goods: [GOBLET, FIGURINE], dump_zones: [...]}`

## Fair Play
Zones/stockpiles/orders/marks as in the interface; no item teleports (`autodump` forbidden).

## Acceptance Criteria
1. Scenario "900 corpses, no zone": proposal with zone location; marking ≤ 300 per cycle.
2. Test "boulder in the marking list": never marked (property test over random item lists).
3. Test "dwarf corpse": not marked.
4. Scenario "1 DumpItem job at 490 marks": cause `zone too far` and proposal `zone D`.
5. Digest line ≤ 140 characters; measurement runtime ≤ 5 s without a freeze.

## Fixtures/Tests
`claude/muell status` outputs, item counts (loose boulders 7,808 etc.), zone coordinates A–D.

## Implementation (v3)
- **Code:** `dfpilot/features/hygiene.py` (command `dfpilot hygiene status|mark [--apply]|zones`, `check_hook`), `lua/pilot_hygiene.lua` (`status <start> <n>` read only in index blocks, `report` read only, `mark <n> <TYPES> [--rotten] [--apply]`), config section `hygiene` (feature defaults).
- **Hard rules in two places:** Python (`HARD_NEVER`, `effective_types`: config can never unlock boulders, goods, gear) and Lua (`NEVER`, dwarf corpse = fort race, a fort-race unit or any named/historical corpse; bones/skins via corpse flags and material flags; read errors count as "never mark").
- **Marks:** only when a dump zone exists, only while fewer than `pending_max` marks are pending, at most min(`mark_batch`, 300) per cycle, only reachable, visible, unforbidden items; loop protection `max_marks_per_hour` via `state.db` actions. `check` only measures (every `measure_every_s`); marking in `check` needs `hygiene.auto_mark: true`.
- **Diagnosis order:** no dump zone → zone under a stockpile (Run 1 lesson) → path blocked (≥ 50 % of the marks unreachable) → haulers busy (no idle citizen) → zone too far (centroid of the marks > `far_tiles` from the nearest zone, Chebyshev + 3 per z level) → "unclear" (wild/rotten corpses, KB hint).
- **Runtime:** block size adapts (a block slower than `max_block_s` halves it, stored in `state.db`); without `pilot_hygiene` installed the live prototype `claude/muell status` is used as a fallback (types only).
- **Tests:** `tests/test_hygiene.py` (property tests in Python and through the Lua script with a DFHack mock, J109 and "490 marks" scenarios, block timing, CLI). Fixtures: `fixtures/v3/hygiene/` (synthetic).
- **Deviations:** "broken items" are not marked (every candidate type is in the player's exclusion list); thread is never marked (player rule beats rule 2); "stockpile full → items on the floor" and the hauling rate per hour are not measured yet (no data); zones A–C are unknown, only zone D is configured.
- **Open live checks:** field names `corpse_flags.*`, `civzone_type.Dump`, `flags.rotten` and `dfhack.maps.canWalkBetween` in DF 53; runtime of one 20,000-item block; whether marked wild corpses get `DumpItem` jobs at all.
