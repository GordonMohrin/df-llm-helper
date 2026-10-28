# BUG-105 Bodies on tiles nobody can path to (tree crowns) count as corpses_old for ever: the Z7 goal can never reach 0
Status: fixed in the M1 commit (offline, live-untested): such a body is `corpse_unreachable`, counted apart (`care.corpses_unreach`,
status/brief `+N unreachable`), out of `corpses_old` and out of the GHOSTS wake
Severity: low-medium (a permanent class-A wake and a goal that cannot be met; the stress source `SawDeadBody` ran 1,100-1,400 a week)
Found: 2026-10-25, Run 14 (region2-site90), game session note 81 (five citizens dead since y503-532, lying at x119-123 y64-72 z133 on
`branches` / `branch (SW)` / `branch (S)` tiles, year 675; ghosts 0, `corpses 5` for years)
Module: `lua/dfllm/care.lua` (`far_bodies`, `body_causes`, `finish`, `ghost_alarm`, `M.state`, `M.inspect`)

## Actual
`dfpilot brief` said `corpses 5` for 140 years although no ghost existed. The bodies were open (not in a building, no forbid or dump
flag), no coffin, zone or hauler could reach them, and nothing told the player that this was a different case from "waiting for a
coffin".

## Cause (proven from the code at 32994bb)
1. `corpse_seen` (care.lua:725-750) puts every open citizen body into `r.open` (care.lua:744); `finish` (care.lua:3534) counts every
   one older than `corpse_old` into `old` and `old_ids` (care.lua:3542-3545), and publishes `corpses_old = old` (care.lua:3633),
   which is the Z7 number; `ghost_alarm` (care.lua:3226) announces `old_ids` (GHOSTS, class A, again for news or after the cadence).
2. BUG-062 already knew a body can be out of reach: `far_bodies` (care.lua:1039-1062) asks `snapshot.reach` (`canWalkBetween`)
   against the first three citizens and marks it `corpse_far` (care.lua:1073). But `corpse_far` only changed the **cause** and the
   tomb arithmetic (`need = open - r.far_n ...`, care.lua:3591): the body still counted into `old`/`old_ids`. So a body that no
   coffin, tomb or wall helps stayed in the number the burial work is judged by.
3. A tree crown is that case twice over: `snapshot.SHAPE` (snapshot.lua:69) draws `BRANCH` and `TRUNK_BRANCH` as floor `'.'` and `TWIG`
   as open air, so the kernel's own tile reader shows a walkable tile where no dwarf can stand or path to (no stair, no ramp, the trunk
   is a wall). Whether DF gives such a tile walk group 0 or a group of its own is not decided offline; both end in `canWalkBetween`
   false, i.e. in the `far` set, and both are now `corpse_unreachable`.

## Fix
- `far_bodies` returns, besides the far set, the subset `unr`: far bodies whose own tile has **no walk group** (`snapshot.groups`
  answers 0) or is a **tree crown** (`snapshot.tile` shape `BRANCH`, `TRUNK_BRANCH`, `TWIG`, or a tree tile `T`). A body in a walk group
  of its own on a floor stays `corpse_far` (a stair or a dug way connects it) and counts in `corpses_old` as before. Without the
  walk-group hooks nothing is unreachable (no guess).
- `body_causes`: `corpse_unreachable` (inspect tombs `unburied[].why`, GHOSTS `causes`, hint "slab for corpse_unreachable").
- `finish`: such bodies are `unreach`, not `old`; `care.corpses_unreach` (state, only when > 0), GHOSTS `unreach`, `inspect tombs`
  `unreach_n` and a `(N unreachable: tree crowns, no walk group)` clause in its message. A ghost whose body lies there still wakes
  GHOSTS (a slab lays it to rest).
- brief/status care line: `corpses 0 (+5 unreachable)`.
- No tombs, coffins or zones are provisioned for them (they were already in the far set).

## Not decided offline
- The walk group of a branch tile in 53.16 (0 or its own): read-only `dfhack.maps.getWalkableGroup` and `getTileType` of the five
  positions of note 81. Either way the classification holds; the `shape` and `groups` reads decide which of the two tests fired.
- Whether a memorial slab (EngraveSlab, BUG-078/090) really lays such a ghost to rest; felling the tree (a designation) would also
  bring the bodies down. Not added: no player did that in the notes.

## Tests
`tests/lua/test_care_m1.lua` (4 tests: five bodies in crowns, no walk group vs another walk group vs the fort, a ghost on a crown, no
hooks no guess). All fail on 32994bb.

Related: BUG-062, BUG-078, BUG-090, FR-74
