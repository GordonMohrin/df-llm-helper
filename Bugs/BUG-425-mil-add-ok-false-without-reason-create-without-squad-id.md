# BUG-425: `claude/mil add` returns `ok:false` without a reason when the squad leader slot is empty/orphaned; `mil create` sometimes returns no squad id; squads cannot be deleted via DFHack

- **Status:** fixed in 908dc28
- **Severity:** S2 (silent failure of the military build-up during a siege)
- **Area:** `lua/claude/mil.lua:360-376` (`add`/`remove`), `mil.lua:~296-350` (`create`), docs
- **Reported:** 2026-10-02, commit `22b9b03`
- **Environment:** Windows 11, game running (DF 53.16 + DFHack), siege

## Command / steps
```
dfhack-run claude/mil add <squad_id> <unit_id> --apply
```
with a squad whose leader position (slot 0) is empty or points to a dead/orphaned histfig.

## Expected
Success, or `ok:false` with a `reason` (e.g. `leader slot empty`, `squad full`, `unit already in squad`) and a documented fallback.

## Actual
```lua
local okk, r = pcall(dfhack.military.addToSquad, uid, s.id, -1)
plan.ok = okk and r          -- false when addToSquad returns false, no reason given
```
Output: `{"ok": false, ...}` with no explanation. Workaround found live: `dfhack.military.addToSquad(uid, squad, slot)` with an **explicit slot >= 1** succeeds, so slot `-1` ("first free") apparently lands on the empty/orphaned leader position and fails.
Also: `mil create` (makeSquad branch) sometimes returned no squad id in its answer (observation, not recorded).

## Evidence
none recorded (raw answers were not kept).

## Suggested fix
1. In `add`: return `plan.error`/`plan.reason`; on `false` retry with the first free slot `>= 1` (scan `s.positions` for `occupant == -1`); report the `slot` used.
2. In `create`: always print the `squad_id` of the created squad or an error; run a status query afterwards.
3. Docs (`mil` header, `COMPANION.md`): **squads cannot be deleted through DFHack (no API)**; empty squads stay in the list - reuse them (rename, `add` with slot >= 1) instead of creating new ones.

## Acceptance (fixture)
Fixture squad with `positions[0].occupant = -1` (empty leader) and free slot 1: `mil add` succeeds with `slot = 1`, or returns a non-empty `reason`. Fixture with a full squad: `reason = "squad full"`.

## Info needed
Player: raw answer of the failing `mil add` and the `mil status` of that squad (positions with occupants).

## Fix
- `mil add`: checks first and answers `ok:false` + `reason` for: not an adult citizen, dead, no historical figure,
  `unit already in this squad`, `unit already in squad N (mil remove first)`, `squad full` (with the orphaned slots: occupant whose
  histfig/unit is gone or dead). It never passes slot `-1`: free slots `>= 1` are tried in order, the leader slot 0 last; the answer
  carries `slot`, `free_slots`, `orphaned_slots`. If every slot is refused: `reason = "addToSquad refused every free slot (...)"`.
  Labors are only removed after a successful add. The dry run shows the slot it would use.
- `mil remove`: `ok` reflects the return value of `removeFromSquad`, with `reason` on failure; `unit not in this squad` is checked.
- `mil create`: `squad_id` (and `squad`) is set right after `makeSquad`; the leader/assignment steps run in their own pcall, a failure
  there gives `ok:false` + `warning` but still the id (before, the outer pcall printed only `error`, which explains the missing id).
  A status query (`status.members/of/name`) follows. Missing `MILITIA_CAPTAIN` position is reported instead of crashing.
- **Deleting squads:** DFHack has no API for it and there is no player action we can mirror safely, so the scripts do not try.
  Documented in the `mil` header and `COMPANION.md`; `mil status` marks `empty = true`; `mil create` lists empty squads as
  `reuse_hint`; new `mil rename <squad> <name> [--apply]` (UI: squad name) to reuse them.
- Tests: `tests/test_bugs_live_mil.py` (orphaned leader slot -> slot 2, full squad, already in squad, all slots refused, dry run,
  create id + warning, rename).

## Info needed
Raw answer of `claude/mil add <squad> <unit> --apply` and `claude/mil status --squad <id>` the next time a squad is filled, to confirm
that the explicit slot works live and which slots show up as `orphaned_slots`.
