# BUG-066 A destroyed workshop stays in the manifest as built; `bp sites workshops` says "nothing left to build"
Status: fixed in FIXCOMMITS (offline, live-untested): once a game day the runner
compares the manifest's workshops with the workshops that stand, a missing one leaves the manifest after two scans and
is listed in `manifest.gone`; follow/cmd take the workshops of `gone` out of every bp fragment older than the loss
Severity: high (wrong decision: a strange mood has no workshop, the fort asks for none and the dwarf is lost)
Found: 2026-10-23, Run 14 y560 (note 59 of bugs/RUN11-offene-bugs-und-FR.md): unit 34167 (Secretive, FORGE_FURNITURE)
got `DECISION_NEEDED mood_workshop` ("needs a workshop for FORGE_FURNITURE now") while `dfllm bp sites workshops --fresh`
said "nothing left to build"; a Lua scan found 0 workshops of subtype MetalsmithsForge in the whole fort, but
`manifest.json` listed `workshops[17] {type: MetalsmithsForge, pos: [73,62,129]}` (the shop had been "toppled", BUG-064
class). The session deleted the entry from manifest.json; the next `--fresh` request ignored it ("the kernel keeps its own
copy") and it placed a new forge by hand with quickfort (`wf`, 73-75,64-66 z129).
Module: `lua/dfllm/runner.lua` (merge_manifest, finish, the daily sync Q.sync), `dfpilot/cmd.py` (fort_manifest,
workshops_missing, place)

## Actual
- The manifest keeps a workshop for ever; every consumer that asks "does the fort have a X?" answers from the plan, not
  from what stands.
- `bp sites workshops`: `BpError bp.sites.rank(workshops): workshops: nothing left to build` (all 12 moodable types
  "present"), so follow's mood request (`PROJECT_REQUEST workshops why=mood`) ended in an AUTO_FAIL and no shop came.

## Cause (proved from the code at f17e2b3)
1. **The kernel's manifest only grows.** `M.merge_manifest` (runner.lua:395-410) replaces `workshops` per `pos`
   (`BY.workshops = {'pos', 100}`, line 392) and appends; nothing removes an entry. `finish` (runner.lua:1635) merges a
   project's fragment when the project is done and never looks at the buildings again.
2. **The phase deliverable trusts the same list.** `CHECK.workshops` (runner.lua:2789) takes `have[type]` from
   `K.manifest().workshops` first, so a destroyed shop also kept a phase `workshops` deliverable passed.
3. **Python merges every bp fragment, done or not, on top of the manifest.** `fort_manifest` (cmd.py:143-166) merges the
   kernel manifest and the `manifest` fragment of every `bp/*.json` (applied projects, running or done, are never
   removed from `bp/`), so deleting the entry in `manifest.json` by hand cannot help: the `y433`-style workshops project
   still lists the forge. `workshops_missing` (cmd.py:420-431) answers "missing" from that merge; `place()` (cmd.py:914,
   921) skips the types the merge has, and `rooms.workshops` raises "nothing left to build" when nothing is left (the same
   flaw as BUG-038 cause 3 for the fishery: the dedupe used what was planned, not what stands; that fix only added `need`
   for the kernel's fishery/tannery requests).
4. **Nothing read the buildings.** economy's `facts` (economy.lua:1099-1117) lists what stands for its own needs, runner
   and Python never did.

## Fix
- **Kernel (runner.lua `Q.stand`, `Q.sync`):** once a game day (end of a runner run, `runner.reclaim.on`, config/baseline.json)
  the manifest's workshops are compared with `buildings.other.WORKSHOP_ANY` / `FURNACE_ANY` (type name, x1..x2, y1..y2, z;
  any build stage, so a shop under construction counts). One that stands nowhere for `runner.reclaim.gone_scans` (2) scans
  in a row leaves `manifest.workshops` and is listed in `manifest.gone` `{type, pos, w}` (`w` = the wall clock, cap 50,
  kern.log `manifest: workshop X at x,y,z no longer stands`); a shop seen again before the second scan keeps its place.
  A vector that cannot be read (no type names, no coordinates) prunes nothing. `merge_manifest` removes the `gone` entry
  of a workshop a finished project brings back at the same place, and the sync removes the entry of one that stands again.
  State `adopt.gone` counts them; status `adopted fort: ..., N destroyed, out of the manifest`.
- **Python (`cmd._without_gone`, `fort_manifest`):** the fragment of a bp file written before the loss (`mtime <= w`) no
  longer lists the workshops of `manifest.gone` (exact type and pos); a file written after the loss is a rebuild and
  counts, so a rebuild under way is not asked for twice. Every consumer (`workshops_missing`, `place` skip/add, follow's
  starter, `bp sites workshops`) reads `fort_manifest`.
- **The phase test** `CHECK.workshops` now follows the pruned manifest.

## Not decided offline
- **Which event removed the forge in Run 14** (a tantrum, a ghost: B3/BUG-064) is not this bug; any loss is covered.
- **Is the standing check complete in DF 53.16?** `b.type` of a workshop and a furnace is read through `df.workshop_type`
  / `df.furnace_type` as economy's facts do; `x1..y2`, `z` are the building's extents. Live data that decides it: after a
  reload, kern.log `manifest: N standing workshop(s) adopted` must be 0 in a fort whose workshops our projects built, and
  `dfllm status` `adopted fort`/`workshops` must not list a MISSING shop that stands. `dfhack-run lua` read-only:
  `for _,b in ipairs(df.global.world.buildings.other.WORKSHOP_ANY) do print(df.workshop_type[b.type], b.x1,b.y1,b.x2,b.y2,b.z) end`.
- **Grace of two scans.** A building DF replaces under the same project (a rebuild by buildingplan) is never absent for two
  daily scans; if the live fort shows a false `no longer stands` line, `runner.reclaim.gone_scans` is the knob.

## Tests
- `tests/lua/test_runner_manifest.lua`: prune after two scans and `gone`, a shop seen again, a failed read prunes nothing,
  the merge cancels `gone`, the old `phases: workshops ...` test now has the Masons stand.
- `tests/test_c2_reclaim.py`: `manifest.gone` validates, `workshops_missing` and `place()` build the destroyed forge again,
  a file written after the loss is a rebuild, a `gone` entry without a clock filters every fragment.
- All new tests fail on f17e2b3 (checked in a pristine worktree of the base).

Related: BUG-038 (the same flaw for the fishery), BUG-042 (tannery), BUG-064 (what destroys buildings), FR-76
