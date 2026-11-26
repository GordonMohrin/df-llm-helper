# BUG-931 WOOD_UNMARK works, autochop marks the same unreachable trees again: the kernel marks a few REACHABLE trees itself (WOOD_FELL_MARK)
Status: fixed (offline, live-untested)
Severity: high (i1 Diedplank: 6 dwarves died for want of drink while more than 1000 reachable trees stood, no usable log for 1,300 game days)
Found: Run 17 i1 Diedplank (26.11.), kernel main 53ad979a, DF "E:/Program Files (x86)/Steam/steamapps/common/Dwarf Fortress", runs/run-17a/FR-BUGS.md "Runde 10 i1"
Module: `lua/dfllm/economy.lua` (`M.wood_fell_mark`, `M.wood_fell_follow`, `M.pts_home`, `M.fell_candidates`, `M.fell_safe`, hooks in `M.wood_stuck` / `M.wood_watch`), `lua/dfllm/act.lua` (`tree_mark`), `dfpilot/schema.py` + `lua/dfllm/util/contract.lua` (event WOOD_FELL_MARK, act `tree_mark`), `config/baseline.json` (`economy.wood.fell*`)

## Symptom (PROVEN, player notes + events.jsonl)
- #16613 y435 win d52 WOOD_UNMARK "7 fell designations off the citizens' walk group taken down"; #16617 "marked trees 5 (before 7), trees felled 0, new logs 0"; #16628 / #16643 the same trees (173,91,144 162,134,144 74,159,144 ...) marked again and taken down again; #16658 "taken down 3 times and still no usable log: stopped for this episode, no further cure is guessed" (ph stop, run 3).
- WOOD_STUCK #18015 ... #18125 (events.jsonl) "no usable log for 1126 ... 1322 game days: 263 of 264 loose logs lie on tiles with no walk group, all 5 open FellTree jobs lie off the citizens' walk group" (`ff 5 fo 5`), mode PEACE the whole time.
- `autochop status`: accessible trees 1485 (1035 earlier), inaccessible 0, designated 5-7: the plugin counts every tree it can see as accessible and marks the unreachable ones again after each removal.

## Cause
- economy.lua `M.wood_unmark` only TAKES designations down (3 runs per episode, then `rec.stop`); nothing in the kernel ever SET a designation on a reachable tree. After the stop the only wood source left was the plugin, which does not know the citizens' walk group (cause of the re-marking: INFERRED from the three cycles, the plugin source is not on this machine, only `E:/DF-test4/hack/docs/docs/tools/autochop.txt`).

## Change
- `act.tree_mark(positions)` (act.lua, beside `tree_unmark`; economy only): `dfhack.designations.markPlant` on the trees at the positions that are not marked now (<= 24); the call quickfort's `dig_chop` makes (`scripts/internal/quickfort/dig.lua:115`, `markPlant(plant)` with the plant from `getPlantAtTile`). `markPlant` answers false for what it cannot mark: not counted.
- `M.wood_fell_mark` (economy.lua, called from `M.wood_stuck` after `M.wood_unmark`): when WOOD_STUCK holds, the removal has stopped / run (`wunmark.stop`, `runs >= 1`), is switched off (`wood.unmark = false`) or cannot apply (no open FellTree job off the walk group, i.e. a logs-only episode with `rd.trees` false; or its look found no marked tree to take down: `wunmark.try` set, no run; or `act.tree_unmark` missing), its measurement is not pending, and mode is PEACE / RECOVERY (`HUNT_MODES`), choose up to `wood.fell_n` (6) trees: unmarked trees within `wood.near_d` (40) of a built Carpenter's workshop, nearest first (`M.fell_candidates`, `M.wood_rect_dist`); each must touch the citizens' walk group (`M.pts_home`: `snapshot.groups` positive answer only, unknown = no), have a readable tile, no READABLE water tile (`flow > 0`) and no open-air-over-open-air column (`shape == EMPTY` at z and at z-1 or unreadable below) within `wood.fell_clear` (3) tiles on its level (`M.fell_safe`; fails closed on the tree's own tile and on an unreadable tile below open air, but a HIDDEN neighbour tile is skipped like in the water scans), at most `wood.fell_reads` (600) tile reads a pass. A pass every `wood.fell_days` (3), `wood.fell_season` (36) trees in 84 game days (`rec.st`, `rec.sn`).
- Event WOOD_FELL_MARK `ph did` (`n`, `asked`, `sample`, `shop`, `season`, `runs`), `ph result` after `wood.fell_measure` (7) game days (`n`, `trees` felled, `still` standing, `new` / `newnw` logs, `days`), `ph stop` (`why` `not_felled` when none of the marked trees was felled (with the open FellTree jobs said), `unwalkable` when the new logs again lie on tiles with no walk group, `cap` for the season cap). The marking stops for the episode on every stop; the episode ends with the stuck state (the season count stays). kern.log lines `economy: wood fell mark ...`; a choice with nothing qualifying says why once a week (`none of the N nearest trees qualifies (x off the walk group, y water ...)`).
- Excluding the unreachable trees from autochop (`autochop chop <burrow>` restricts it to burrows, docs/tools/autochop.txt) was READ and NOT used: it needs a burrow of reachable trees that the kernel would have to build and keep, and that the plugin honours the walk groups inside such a burrow is not shown anywhere on this machine.

## Tests
`tests/lua/test_bug931_fell_mark.lua` (6: choice by distance / walk group / water / drop / near_d, caps and passes, modes / switches / no shop, unreadable groups and tiles, measurement and the not-felled stop, tile-read budget), `tests/lua/test_act_supply.lua` (`tree_mark`), schema / contract mirror tests.

## Live-Erwartung
i1: WOOD_UNMARK stops (run 3) or has run once; the next `wood_stuck` pass (daily) logs `economy: wood fell mark: no usable log: 6 reachable trees marked for felling nearest the Carpenter's workshop at 94,96,144 (e.g. ...)` and one WOOD_FELL_MARK `did` with `n` 6. `autochop status` shows designated trees incl. those positions; after 7 game days WOOD_FELL_MARK `result` with `trees` > 0 and `new` > 0 proves the cure (logs near the shop count as `wood`); `trees` 0 gives `stop not_felled` naming the open FellTree jobs. If logs fall where nobody can walk the stop says `unwalkable`.

## Known limits (stated, not coded)
- Hidden neighbour tiles are skipped in `M.fell_safe`: an unrevealed pond or cliff within 3 tiles of a tree is not excluded (test: `documented limit`).
- No zone / burrow / fruit-tree check: a tree in a garden or gather zone, or a fruit tree, may be marked; the damage is bounded by `fell_n` / `fell_season`.
- Verifier gap fixed on top of the first commit: a stuck episode with NO open FellTree job (logs-only, `rd.trees` false) never ran WOOD_UNMARK, so `wunmark.runs` stayed 0 and the marking waited forever; it now starts when the removal cannot apply (test `a logs-only episode`).

## Not proven
- That the plugin does not unmark or ignore our designations (it only designates; its `undesignate` is a command, not a periodic act: from the docs).
- That DF's woodcutters take the marked trees: a Woodcutter labor holder with an axe is needed (`tools axe 0` was seen on i1 earlier); not checked here.
- Whether "the citizens' walk group" (`snapshot.home_set`) is the group of the woodcutters' reach; a tree touching it is the same rule `M.pts_far` used for BUG-917.
