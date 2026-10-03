# Item hygiene: `python -m df_llm_helper hygiene` (spec v3-07, live-untested)

**What it does:** counts loose items, marks enemy/animal corpses and rotten food for the dump (garbage flag, like the
item menu), at most 300 per cycle, and explains why dumping does not work.

**Never marked (hard rules, config cannot change them):** boulders, dwarf corpses (and any named corpse), bones,
skulls, shells, skins, leather, hair, trade goods (goblets, crafts, figurines, thread, cloth), weapons, armor, bars.
`autodump` (item teleport) is never used.

## Commands
- `python -m df_llm_helper hygiene` (= `status`): digest line, types, areas (fort/surface/cavern), corpses (dwarf/other),
  pending marks, dump jobs, cause + zone proposal, goblet cap hint, coffins vs. dwarf corpses, measurement time.
  `--dry-run` does not record the history (growth per hour).
- `hygiene zones`: existing dump zones (warns "UNDER A STOCKPILE") and the proposal from `hygiene.dump_zones`.
- `hygiene mark`: dry run (shows how many items would be marked). `hygiene mark --apply` marks for real.
- `hygiene mark --unforbid` (FEATURE-002): the **forbidden** loose reachable non-dwarf corpses/parts/remains (legacy
  piles: DF forbids what it dumped, the standing order `forbid_other_dead_items` forbids enemy corpses at the kill zone)
  are listed with their ids; `--apply` sets forbid off + dump on exactly those (same hard rules: never dwarf/named
  corpses, bones/skins, trade goods). `hygiene status` shows `forbidden reachable non-dwarf corpses: N` and warns when
  the standing order is on (never changed automatically: it protects haulers during sieges).
- `hygiene flow [--hours 24] [--caps]` (FEATURE-002, read only): one block per item group

  ```
  FLOW 2h    type            stock reach_loose inflow/h  sink/h free_slots  state
             BOULDER         11553       11550       +0      +0         24  flat (no inflow), never dump
             CORPSE+PIECE     1305         455       +0      +0  dump zone  flat (bridge not pulled: 654 on landing)
             GOBLET            400         369       +0     +10          0  shrinking, stuck: needs 4 bins
             CRAFTS(7)        3440          57      +88     +18          0  GROWING, cap 450 x 7 kinds above sale capacity 800 -> lower cap
             BLOCKS            690         569       +0      +5        105  shrinking
             unreachable      2190           -        -       -          -  ignored (cavern 2190, surface 0, webs 1340)
  ```
  `reach_loose` = loose stacks the haulers can reach (unreachable cavern/surface items and webs are one line and never
  part of a KPI or wake line). Rates come from flow snapshots in `state.db` (table `item_flow`): every measurement
  (`hygiene status`, `check` every 30 min, `flow`) stores stock, reachable loose stacks and the items created since the
  previous snapshot per type; inflow/h = new items, sink/h = what disappeared (built in, sold, dumped, eaten). The first
  run has no rate ("rates need a second snapshot"). `free_slots` = free tiles of stockpiles that accept the type.
  `--caps` adds the cap audit.
- `hygiene caps` (read only): every manager order with an item cap vs. the real stock: `cap above stock` (production
  runs until the cap), `cap exceeded` (fine), `cap counts differently` (condition flags or container contents decide),
  and for crafts `cap per kind x kinds > flow.sale_capacity` (default 800 trade goods per caravan season) and
  `stock = Nx the sale capacity`.
- `hygiene bins [--pile ID] [--apply]`: bins needed for the loose reachable finished goods (ceil(n / 100)), wood cost,
  existing bins (empty, outside a stockpile), the finished-goods stockpiles, and a warning when the stockpiles' `max_bins`
  add up to more bins than exist. `--apply` needs the register entry FP14 and the wood gate (free logs >= bins +
  `flow.wood_reserve`): ONE one-off `ConstructBin` order (never a standing order: one ran away 13 -> 25 bins in a minute)
  and `max_bins` of the biggest finished-goods stockpile (or `--pile`) raised to its bins + N (never lowered). Refused
  while a ConstructBin order is open.
- `hygiene zones` also shows **garbage bridges** (a bridge under a dump zone): raised/lowered, items on the landing by
  type, the linked lever; over `flow.landing_warn` (300) items: "pull the lever (player action)". The lever stays a
  player action.

## When nothing is marked
- "No dump zone": build the proposed zone first (zone D z130 x86..88,y112..114 near refuse room/crypt/barracks).
  df-llm-helper only proposes zones, it never builds them.
- "N marks still pending": the haulers have not caught up; wait.
- "Loop protection": at most `max_marks_per_hour` (2) mark cycles per hour.

## Causes when marks are not hauled (DumpItem jobs < 10 % of the marks)
| Cause | Meaning | What to do |
|---|---|---|
| no dump zone | marks without a zone pile up | build the proposed zone |
| zone under a stockpile | Run 1: 0 DumpItem jobs | move the zone onto free tiles |
| path blocked | ≥ half of the marks unreachable | open the path / check doors |
| haulers busy | no idle citizen | more haulers or wait |
| zone too far | marks far from every zone | build the proposed closer zone |
| unclear | wild/rotten corpses are often never hauled | `kb search kadaver` |

## In `check`
Measures every `measure_every_s` (30 min) and only prints lines on a problem (cause, ghost risk, many corpses).
Marking inside `check` only with `hygiene.auto_mark: true` (off until live-tested). Every measurement stores a flow
snapshot; `CRAFTS growing` and `garbage bridge landing > 300` give one line + one wake line per state change (crit
warning), never again while the state stays. The forbidden-supply warning (BUG-125) defers to `forbid-watch` while that
one reports.

## Configuration (`config.yaml`, section `hygiene`)
`mark_batch` (≤ 300), `pending_max`, `mark_types`, `mark_rotten`, `exclude_types`, `keep_goods`,
`dump_zones` (list of `{name, z, x: [x1, x2], y: [y1, y2], note}`), `block` (items per Lua call), `max_block_s`,
`far_tiles`, `measure_every_s`, `auto_mark`, `max_marks_per_hour`, `corpse_warn`, `goblet_cap`.
Sub-section `flow`: `hours` (24), `sale_capacity` (800, player decision pending), `bin_capacity` (100), `wood_reserve`
(10), `landing_warn` (300), `flow_rows` (8), `flow_eps` (0.5/h), `max_bins_per_order` (50).

## Not done (FEATURE-002)
- "lever last pulled": DF keeps no such time; df-llm-helper only shows the current bridge state (raised/lowered).
- Sinks from game events (finished `ConstructBuilding`/`DumpItem` jobs, trade sales) are not counted one by one; the
  sink per hour is what disappeared between snapshots (built in, sold, dumped, eaten together).
- Bins "planned": only the loose reachable finished goods count (no forecast of production).
- `flow.sale_capacity` default 800 until the player decides (the request mentions 300 per kind locally).

## Install
`python -m df_llm_helper install-lua --apply` (or copy `lua/pilot_hygiene.lua` to
`hack/scripts/claude/pilot_hygiene.lua`). Without it df-llm-helper falls back to `claude/muell status` (types only); an
older copy without the flow fields makes `hygiene flow` say "reinstall the Lua scripts". `claude/muell dump` never
dumps bones/skulls/shells/horns/teeth/hides any more (craft material, counted as `uebersprungen.knochen`).
