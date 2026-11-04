# BUG-353 bp.cancel leaves the project's dig designations (and queued jobs) in the map
Status: fixed (offline, live-untested): a plain bp.cancel takes back the designations of the dig chunks the project applied
Severity: high
Found: 2026-11-04, Run 16c (i3, E:/DF-test3, run r16c-w9-18-site97: kern.log, bp/*.json read only), kernel main 8890b59
Module: `lua/dfllm/runner.lua` (cancel, undo, Q.applied_dig)

## Actual
All 13 citizens stood in walk group 1562; the fortcore sites S3 [72,128,125] and S2 [58,128,125] lay on the surface in walk
group 1 (the other side of the brook), unreachable. Project c1a1a6ad31b228f901 (anchor [58,128,125]) stalled 30 d at s1.dig 0%
('unreachable DigChannel'). After two `bp.cancel` + re-place about 1580 dig designations of the cancelled projects stayed on
z120-124 (blocks 7,7 / 6,7 / 4,7 / 5,7 / 4,8 / 6,8); the fort starved (food 0 d) because the miners kept walking to them.

## Root cause
runner.lua `cancel` (plain, no `undo`; was :2825-2837) only removed the project's unbuilt buildings (BUG-314, R.rm) and then
`remove`d it. The dig designations its applied chunks had made were only taken back by `bp.cancel undo=true` (walks back
every stage) and by a breach undo. A plain cancel forgot the project, so nothing owned the tiles any more.

## Fix
- `Q.applied_dig(P, d, R)`: the chunk indices of the current stage's dig the project applied (P.chunk, all after a
  re-apply). `cancel` (plain) sets `R.undo = {l = those, cancel = 0, plain = true}` with the BUG-314 pieces and blocks
  the project as `cancel`; the existing `undo` task walks it (one quickfort undo of the chunk's own cells per chunk,
  budgeted), then removes the project. Quickfort's undo clears a designation not dug yet and leaves dug ground.
  Only cells of that project's blueprint are named: the player's and other projects' designations elsewhere stay.
- It logs `<id> (<tpl>) cancelled: N dig designation(s) of its applied chunks removed` (N = quickfort's count), and the
  command answer says `cancelling <id> (K applied dig chunk(s) taken back...)`.
- Earlier stages are done (dug); a later stage is not applied yet; build pieces: BUG-314. Not touched: a tile the player
  designated inside the project's own blueprint cells goes with it.

## Tests (fail on 8890b59)
tests/lua/test_runner.lua `BUG-353`: designations of the project gone, a player's designation and another project's stay,
dug tiles stay, log line.

## Live check
`dfllm cmd bp.cancel proj=<a stalled dig project>`: the answer names the chunks, kern.log has the removed count, the
designations on the map are gone (`dfllm view`), the miners stop walking to them.
