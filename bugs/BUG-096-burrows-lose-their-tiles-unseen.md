# BUG-096 Kern+ and the refuge lose their tiles or vanish and nothing in the kernel sees it
Status: fixed in the K1 commit (offline, live-untested): the cause is not in this repository's code and cannot be proved
offline (see "Not decided offline"); the missing observability is fixed: seal's burrow guard reads Kern+ and the refuge
once a game day and at a load, keeps the last good reading, announces a loss (BURROW_SHRUNK, A, with the data that tells
how it happened) and keeps R0 when a well or the refuge was among the lost tiles (`burrow_lost`). The repair is BUG-097.
Severity: high (wrong decision: `hospital_out` came back a fourth time and the game session debugged the symptom, a
hospital zone outside the alert burrow, three times before it looked at the burrow itself)
Found: 2026-10-23, Run 14 Trussroads y585-y586 (note 70 of `bugs/RUN11-offene-bugs-und-FR.md`), kernel of b2b9435
Module: `lua/dfllm/seal.lua` (burrow guard), `lua/dfllm/burrowkeep.lua`, `lua/dfllm/readiness.lua`

## Actual
Note 70, read with `df.global.plotinfo.burrows.list` and `dfhack.burrows.isAssignedTile`: hospital zone 24422 (73-79,26-30
z129, unchanged since the y578 fix) lay on 35 of 35 tiles outside Kern+. The second burrow of the status, Tiefe+, was not
in `plotinfo.burrows.list` any more; one burrow was left, Kern+ with id 8. A sample over the map (block centres, all z) found
ONE tile of Kern+, far from the fort core. Between the y578 fix and y586 no `bp.place` or zone action touched the burrows on
purpose. The game session painted the 35 hospital tiles into Kern+ by hand (`dfhack.burrows.setAssignedTile`, the burrow
screen's paint brush) and `hospital_out` went away.

What the kernel did meanwhile: nothing. It read the burrows many times a day (sense, siege, seal, water, readiness) and
none of those readers keeps a count over time.

## Cause (base b2b9435; what the code proves and what it cannot)
Every path of this repository that can take a tile from a burrow or delete / re-create one, with the condition under which
it would:

| Path | Can it shrink a burrow? |
|---|---|
| `act.burrow_tiles` (`lua/dfllm/act.lua:1238`, the write at `lua/dfllm/act.lua:1260` is `setAssignedTile(b, pos, true)`) | No. It adds. With `create` it makes a missing burrow (a new id). Callers: seal `job_paint` (`lua/dfllm/seal.lua:2895`: the interior burrow Innen+, and the dead end behind the deepest stair as `Tiefe+` when the refuge is missing, `lua/dfllm/seal.lua:2870`) and `lever_burrow` (`lua/dfllm/seal.lua:3468`, Hebel+). |
| `act.burrow_units` (`lua/dfllm/act.lua:1210`) | No. It writes the unit list of a lever room (`setAssignedUnit`, `lua/dfllm/act.lua:1226`). |
| `act.alert_burrows` (`lua/dfllm/act.lua:547`; `remove_civalert_burrow`, `lua/dfllm/act.lua:563`) | No. It edits the id list of the civ alert; DFHack's `gui/civ-alert` deletes no burrow. |
| quickfort burrow blueprints, `a` cells with `create=true` (`dfpilot/bp/fortcore.py:158`, `:206`, `:278`; every room: `dfpilot/bp/rooms.py:87`) | No when run, run again after a park, a reclaim or a smaller rectangle: quickfort adds the tiles of the rectangle, it never replaces the burrow (the cells are the item's rectangle cut into pieces of at most 40 tiles, `dfpilot/bp/emit.py:139`). One effect: with no burrow of that name, `create=true` makes it again with that rectangle only (`test_model_create_true_makes_a_vanished_kern_again_with_one_rooms_tiles_and_nothing_notices`). |
| quickfort `e` cells without a name (`dfpilot/bp/defense.py:81` gallery_o1 `g2.unburrow`, `dfpilot/bp/rooms.py:632` the cistern's `unburrow`) | Yes, deliberately: DFHack erases the tile from EVERY burrow (Kern+, Tiefe+, the lever rooms) when `e` has no name or the name matches nothing. Bounded by the cells: the strip, the corridor, the pipe and the shaft of one project, a few dozen tiles (`test_model_gallery_o1_unburrow_is_the_strip_and_the_corridor`, `test_model_the_unburrow_stages_erase_from_every_burrow_but_only_their_own_tiles`). |
| quickfort `undo` of a burrow stage: `bp.cancel {undo: true}` (`lua/dfllm/runner.lua:4579`, `cancel` `lua/dfllm/runner.lua:2407-2420` walks every stage back to 0) and `undo` (`lua/dfllm/runner.lua:1974-1994`, the call `qf(K, {mode = st.mode, ... command = 'undo'})` is made for every mode including burrow) | Yes. DFHack inverts the key: an `a ... create=true` cell becomes an erase of its rectangle from the burrow, and the burrow is DELETED once its block list is empty. The tiles that were in Kern+ before the project (grown by the burrow plugin) leave with the rectangle. Bounded by the project's rectangle and its door tile (`test_model_a_burrow_cell_adds_and_its_undo_removes_exactly_its_own_rectangle`, `test_model_the_undo_of_a_projects_burrow_stage_deletes_a_burrow_only_when_it_is_left_empty`). The breach undo (`lua/dfllm/runner.lua:2024`) runs on dig stages only; the other undo calls (`lua/dfllm/runner.lua:1522`, `:2920`, `:3490`) are build stages. |
| reflex, siege, sense, gate, water, care, military, economy, drill, baseline | No. `findByName`, `isAssignedTile`, `listBlocks` and the alert list only (`rg 'setAssignedTile\|clearTiles\|setAssignedBlockTile' lua/dfllm` finds `act.lua` alone; a test pins it). |
| `dfpilot/cmd.py`, `dfpilot/supervise.py`, `dfpilot/plan.py` | No. They read the manifest and the state; `supervise` restarts DF and loads a save (see below). |

What DFHack itself does (source read: DFHack scripts and plugins at the checkout of 2026-10-16, `hack/scripts/internal/
quickfort/burrow.lua` `do_burrow` and `do_run_impl`, `plugins/burrow.cpp` `expand_burrows`, `library/modules/Burrows.cpp`):
the burrow plugin only ever ADDS (`expand_burrows` grows every burrow whose name ends in `+` over the dug tile's
neighbours); `findByName(name, true)` ignores the final `+`, so quickfort's `Kern+` and a burrow `Kern` are one; setting
the last tile of a block off deletes the block's mask (no residue); `clearTiles` is called by the `burrow` command's
`tiles-clear` and by quickfort's undo of an emptied burrow, nowhere else; DFHack stores no burrow data of its own, the
tiles are DF's (`plotinfo.burrows`, `map_block.block_burrows`, saved with the fort).

One more fault of ours that hides it (found on the way): seal keeps a burrow's tile count for `CFG.bsize_stale` (7 days) while
its block count is unchanged (`lua/dfllm/seal.lua:501`), and readiness asks only whether a burrow of that NAME exists
(`lua/dfllm/readiness.lua:359-361`, `no_kern`/`no_refuge`): a Kern+ of one tile, or one that a room project made again with
its own rectangle (`create=true`), passes. `hospital_out` (`lua/dfllm/water.lua:981`) saw the symptom, per hospital zone,
which is why it "came back" while the burrow stayed broken.

So nothing in this repository can take "almost all" of a burrow: the writers are bounded by one project's rectangle. The
rest is DF, DFHack or a hand outside the kernel (the game session itself used raw Lua on the burrows).

## Not decided offline
- Whether DF drops burrow masks or whole burrows by itself on a SAVE/LOAD (note 70 suspects the `region2` unretire reloads,
  note 71 says DF crashed and was loaded again at the end of that session), on a RETIRE/RECLAIM (a fresh plotinfo has no
  burrows; Trussroads is a reclaimed fort), or a block that is unloaded and rebuilt; whether the console `burrow` command or
  a script of the game session (`tiles-clear`, `tiles-set`) ran. The ids will say a lot: Kern+ is id 8 in note 70, which
  fits a Kern+ made again after the other burrows were gone (a hypothesis: the notes do not give its first id).
- Live, read-only data that decides it, all of it in the first BURROW_SHRUNK event of the next loss (no extra command needed):
  `cause` (`load` = the first reading after a boot, `runtime` = while the kernel ran); `id` and `rid` (the burrow id now and at
  the last good reading: another id = the burrow was made again, a smaller one than before = the list was reset, a reclaim);
  `nl` and `nx` (burrows in the list, the id the next one gets: `nx` grown past the old id and the old id gone = deleted,
  `nx` small = reset); `nbw`/`nb` (blocks then and now: blocks gone = tiles erased, blocks kept with tiles gone = masks lost).
  Before that, from the log: `grep '"mode":"burrow"' commands.log` shows every quickfort burrow call with its command (`undo`,
  or a stage `g2.unburrow`/`unburrow`), and kern.log has `cancelled at stage` for each `bp.cancel`: they settle whether
  one of the in-repo writers above ran. From the DFHack console (the developer's, never the orchestrator's: RULES section 1), read-only:
  `#df.global.plotinfo.burrows.list`, `next_id`, and for each burrow its `id`, `name`, `#block_x` and whether each listed
  block's `block_burrows` list holds its id (a mismatch is a DF bookkeeping loss).

## Fix
- `lua/dfllm/burrowkeep.lua` (new library, pure rules): runs (`pack`), the share rule (`shrunk`), the judgement of one
  reading (`judge`), what is missing and in which order (`missing`), the knobs (`conf`) and the persisted record (`load`).
- seal's background job `bguard` (`lua/dfllm/seal.lua:4472`, the BG table from `lua/dfllm/seal.lua:4208`): once a game day
  and at least `burrow.guard.every_s` (120) real seconds after the last reading (`schedule_periodic`; a game day is 2-12 real seconds
  at the speeds of the runs) and `CFG.bg_boot` (100) ticks after a boot it reads Kern+ and the refuge by the manifest roles: blocks,
  tiles, id and the tiles as runs (`BG.read`, `lua/dfllm/seal.lua:4228`; 256 work units a block, one per tile read, sliced by
  seal's token bucket, never in a frame of its own, waits while `K.busy()`); one record per burrow in the persist key `burrows` (owner seal; not the
  state document; a record of another adoption is dropped, so a reclaimed fort starts over).
- A drop of more than `burrow.guard.shrink_pct` (30) % between the last good reading and this one, or a burrow that is gone, opens
  an EPISODE: BURROW_SHRUNK (A) once (util/cadence; again for news: a well or the refuge among the lost tiles; at least a game
  day and 10 real minutes apart), with `was`, `now`, `cause`, blocks, `id`/`rid`, `nl`/`nx`, `crit` and `fix`; state
  `alert.bg` and the status line `burrows: Kern+ 12 of 3120 tiles (load), 40 painted again, repairing; held: well`; the wake
  line has its next move. A baseline under 20 tiles is judged only when emptied. A burrow of the player is never read.
- readiness R0 blocker `burrow_lost` (`seal.burrow_guard`): only when the lost tiles held an accepted well of water's state or
  the refuge; the hospital stays `hospital_out`'s (one blocker, not two); SIEGE_UNREADY `blost` names it.
- Bounds and safety: config `burrow.guard {on, shrink_pct, repair_per_day, settle_days, every_s}` (`lint --config`); one reading a game day and every_s real seconds apart (a big burrow, 600 blocks, is 150,000 work units: about 25 s of seal's background bucket, 12-25 % of it at the default 120 s);
  the record is at most `RUNS_MAX` (8,000) runs a burrow, about 14 bytes a run in JSON (a fort of 80: some thousand runs,
  tens of KB; see BUG-097); in SIEGE/BREACH nothing else changes.

## Tests
`tests/lua/test_burrow_guard.lua` (the daily reading, a shrink, a vanish, a load, an old or foreign record, a siege, a fort of
7, the cadence), `tests/lua/test_burrowkeep.lua`, `tests/lua/test_burrow_guard_ready.lua` (`burrow_lost`),
`tests/test_k1_burrows.py` (contracts, config, status/brief/wake, the model of DFHack's quickfort burrow mode applied to the real
blueprints, the inventory above: `test_the_cause_hunt_inventory_names_every_writer_and_its_lines_are_true`). All fail on b2b9435.

Related: BUG-097, FR-80, BUG-036 (`hospital_out`), BUG-040; note 70
