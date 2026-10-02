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
Marking inside `check` only with `hygiene.auto_mark: true` (off until live-tested).

## Configuration (`config.yaml`, section `hygiene`)
`mark_batch` (≤ 300), `pending_max`, `mark_types`, `mark_rotten`, `exclude_types`, `keep_goods`,
`dump_zones` (list of `{name, z, x: [x1, x2], y: [y1, y2], note}`), `block` (items per Lua call), `max_block_s`,
`far_tiles`, `measure_every_s`, `auto_mark`, `max_marks_per_hour`, `corpse_warn`, `goblet_cap`.

## Install
Copy `lua/pilot_hygiene.lua` to `hack/scripts/claude/pilot_hygiene.lua`. Without it df-llm-helper falls back to
`claude/muell status` (types only).
