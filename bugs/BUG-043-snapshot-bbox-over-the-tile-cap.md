# BUG-043 The audit and sites snapshots are refused: the fort's bounding box grew past 250,000 tiles
Status: fixed in e0be1c7 (offline, live-untested): one default box composition for every purpose (the fort's pieces), explore shafts
as narrow column parts of a union export (' ' = not exported, the outside for bp.topo), the margin shrunk stepwise
(16,16,2 -> 8,8,1 -> 4,4,1 -> 0,0,0) before a refusal, `max_tiles` 400,000 (config `snapshot.max_tiles`), a refusal
that names the box per axis and the piece that stretches it; readiness asks without a box of its own, keeps the
refusal in its state and fails an audit whose snapshot left fort pieces out; finished seals, plugs, repairs and
explores stay in the audit box
Severity: high (wrong decision: no fresh audit, readiness `audit_old`/`audit_fail`, the seal reach audit stale; no fresh
sites, `bp sites` without `--fresh` ranks on an old snapshot)
Found: 2026-10-17, Run 11 fort Kilrudrabed (site98), y479 winter d79, kernel 2eea070, from the game session
Module: `lua/dfllm/snapshot.lua` (`CFG.max_tiles`, `default_bbox`/`manifest_bbox`, `M.export`), `lua/dfllm/readiness.lua`
(`audit_bbox`, `request_audit`), `lua/dfllm/runner.lua` (`M.bboxes`, `KEEP_BOX`)

## Actual
```
dfllm audit                      ->  audit: snapshot refused: bbox has 252108 tiles > 250000
dfllm bp sites <tpl> --fresh     ->  snapshot refused: bbox has 252108 tiles > 250000
kern.log (readiness, monthly)    ->  readiness: audit snapshot not exported: bbox has 308132 tiles > 250000
                                     ... soon after: 370414
```
All 260 bp files of the fort (done ones too) have anchors in x 59-189, y 37-136, z 129-146 (coordinator's read-only
check): minx 59 the shrub-door seal (59,62,146), maxx 189 the seal doors far east, miny 37 explore y451s0b0
(128,37,139), maxy 136 temple/office/farms, minz 129 a seal at (127,62,129). New: explores c1a14b1a6cc8ca4801
(153,52,139) and c1a14b1a7266974401 (89,125,142), digging, and refuge_drink (118,114,136).

## Expected
An audit snapshot always covers what seal and readiness need (the entrances, the refuge, the shafts) and fits the cap;
a sites snapshot never needs the audit's extras; a refusal says which box, how big per axis, what stretches it and the
way out; nothing is left out silently.

## Cause
1. **Proven from the code: two box builders, both a single bounding box.** (a) `snapshot.default_bbox` (2eea070:507;
   `dfllm audit`, `bp sites --fresh`, follow's sites, `dfllm cmd snapshot` without `bbox`): `manifest_bbox` (bridges,
   levers, zones, killboxes, rooms, stations, stairs, refuge anchor, pit, depot) + `margin` 16,16,2, clamped to the map;
   no running project, no `edge`. (b) `readiness.request_audit` (2eea070:202-218): `audit_bbox` (the same without
   `rooms`, with `edge`) + `PAD` 8,16,1, widened by every `runner.bboxes()` box + PAD: each running project with its
   whole planned extent (all stages) and the kept boxes of finished rooms. `M.export` refused any box over
   `max_tiles` 250,000 ('100 x 100 x 25') with only its tile count.
2. **The live numbers: every level of the box is a whole plane of the fort, and the fort spans its map.** 252,108 =
   149 x 94 x 18, 308,132 = 149 x 94 x 22, 370,414 = 149 x 113 x 22 (the prime 149 is common to all three; the most
   plausible shape): x 149 = 43-191, the map's east edge (192 tiles wide) clamps the box, the westmost piece lies at
   x 59 (59 - 16 = 43). An explore is a 1-wide stair `depth` (12) levels down with 13-tile arms every 3 levels
   (`bp/mine.py`); its project box enters readiness' box with all 12 levels at once, and each level costs a whole x-y
   plane of the fort (149 x 113 = 16,837 tiles) although the shaft has about 30 tiles a level. Readiness' z 22 vs the
   default 18: explore y451s0b0 / c1a14b1a6cc8ca4801 reach z 127 (139 - 12; + PAD 1 = 126). The y growth 94 -> 113
   between the two readiness refusals is exactly the new explore c1a14b1a7266974401 at (89,125,142): its south arm ends
   at y 132 (+ PAD 16 = 148), while y 36 = 52 - 16 comes from the explore at (153,52,139): 36-148 = 113.
3. **Reproduced offline:** `tests/lua/test_snapshot_box.lua` "BUG-043 live": a manifest spanning x 59-175, y 52-113,
   z 132-145 on a 192-wide map gives the live default box 149 x 94 x 18 = 252,108; on 2eea070 `dfllm audit`'s request
   and `bp sites --fresh`'s are refused with the live text. "an explore shaft is its own column": the 4 levels a
   12-level explore reaches below the fort box cost 816 tiles as a column part instead of 4 whole planes (63,176).
4. **Not the cause:** the cavern list (manifest `caverns`) never entered a box; the depot and the pit lie inside the
   fort. Seals are no manifest pieces: the seal doors far east (187-189) were inside only through the margin and the
   map-edge clamp.
5. **A coverage gap beside it:** `dfllm audit` (the kernel default) left out the running projects readiness put in
   (live L2: a dig at the box edge reads as a bypass), and finished seals (the entrances) and explores (the shafts)
   were in no box once done.

## Fix
- **snapshot (one composition, `pieces`):** the default box of every purpose is made of the fort's pieces: the manifest
  geometry (bridges and levers, zones, killboxes, rooms, stations, `edge`, stairs, refuge, pit, depot); for an audit
  also `runner.boxes()`. The main box = the pieces' bounding box + a margin; an explore (an audit's) is a **column
  part** of its own: its box + `col_margin` 2,2,1 (at most `parts_max` 24 parts). The export reads only the union of
  the parts (`max_tiles` counts those tiles), writes ` ` for the other tiles of the file's bounding box (`grid_max`
  1,500,000), lists `parts` and `margin` in the head, keeps traps and marks of exported tiles only.
- **margin steps:** 16,16,2 -> 8,8,1 -> 4,4,1 -> 0,0,0 (`margin_steps`); the first whose union fits wins; kern.log once
  per change `snapshot: the audit box is over N tiles at margin 16,16,2: margin 8,8,1 used (N tiles, x .. y .. z ..)`.
- **the cap:** `max_tiles` 400,000 (config/baseline.json `snapshot.max_tiles`, 10,000-1,000,000, `lint --config`). The
  export stays sliced (`slice` 1000 tiles a frame, a tile not exported costs a char, not a read).
- **the refusal:** `bbox 117x62x14[ + N shaft columns] = 101556 tiles > 100000 at margin 0,0,0 (x 59-175 y 52-113 z
  132-145; stretched most by room cistern118_88_132r0 at z132: 29016 tiles less without it); way out: [bp.cancel <proj>
  if it can go, or ]raise snapshot.max_tiles in config/baseline.json (<= 1000000), dfhack-run dfllm reload`. An
  explicit box: `bbox WxHxD = N tiles > CAP (x .. y .. z ..); way out: a smaller bbox, or none`.
- **coverage:** an explicit audit box names the fort pieces it leaves out (reply `leaves out N fort pieces: <first>`,
  SNAPSHOT_READY `out`/`first`); readiness fails such an audit (`coverage: N pieces left out (...)`, `audit_fail`).
  SNAPSHOT_READY `margin` (when it shrank) and `cols`; the inbox reply data `{id, tiles, margin, cols, out, first}`.
- **readiness:** asks with no box (`{purpose = 'audit', by = 'readiness'}`, once the manifest has geometry): the same
  box `dfllm audit` gets. A refusal stays in `ready.audit.why` until the next request is accepted or an audit is
  stored; `ready.audit.cov` = what the last audit's snapshot covered (`out 2: ...`, `margin 8,8,1`, `2 shafts`).
  status/brief: `audit snapshot refused: <why>` in the SIEGE UNREADY line, `next: the refusal's way out, then dfllm
  audit`; `audit ok 3d (margin 8,8,1, 2 shafts)`.
- **runner:** `M.boxes()` names each box `{b, id, tpl}` (`bboxes` stays); `KEEP_BOX` + `seal`, `plug`, `repair` (the
  entrances) and `explore` (m.runner `kk`: a kept shaft stays a column after the list forgets it; `kept_in` answers with rooms only).
- **sites (task d):** the sites box is the manifest's main box (no project boxes, no shafts) with the same margin
  steps: 252,108 tiles live, within the cap. No narrower box per template from Python: the newest sites snapshot is
  shared by every template, by seal's openings, `plan propose/check` and follow's placements; a room needs the whole
  Z4 (public anchors, stair distances).

## Not done (judgment)
- Finished seals and explores that left the project list before this fix (done_keep 16) are not recovered: that needs
  every bp file decoded (260 in Run 11; BUG-033's cost lesson). Their shafts stay watched by the runner's daily shaft
  check (CAVERN_PLUG, readiness `caverns`), the far-east doors lie inside the box by its margin today.
- No new R0 token: a refused audit request shows as `audit`/`audit_old` with the reason in `ready.audit.why`; a partial
  audit is `audit_fail` with its coverage line.

## Tests (fail on 2eea070)
`tests/lua/test_snapshot_box.lua` (new, 6 of 6), `tests/lua/test_readiness.lua` (the request without a box; the
refusal in `ready.audit.why`; a partial audit fails), `tests/lua/test_runner.lua` (`boxes`, the kept seal and explore),
`tests/test_snapshot_box.py` (new: schema of a union snapshot and the state, status texts, config validation),
`tests/test_snapshot_files.py` (the union file on the real kernel, the reply data), `tests/bp/test_bp_topo.py` (an
unexported tile is the outside).

## Live check
See the CHANGELOG entry (2026-10-17).

Related: BUG-033 (the snapshot queue, the boost), BUG-039 (pacing, a huge step), live L2/L4/L7 (projects and kept boxes
in the audit box), FR-65 (`dfllm audit`)
