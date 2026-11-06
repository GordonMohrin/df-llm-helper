# BUG-538 `seal at=last` places a hatch on a stair that is walled in on its level, again and again; the stalled seal keeps a decision for 300+ days
Status: fixed (offline, live-untested)
Severity: medium (the same dead project three times, 300 days of seal_stalled / PROJECT_BLOCKED stale)
Found: 2026-11-06, Run 16d i4 Trumpetrealms y391 / y392 / y399 (`runs/run-16d/FR-BUGS.md` "seal at=last setzt wiederholt Hatch auf Treppe 94,94,140, die 'walled in on its level' ist"; events: c1a1ae1e7e1158ae01 and c1a1aeccc9ca4aa901 "Hatch 94,94,140: job ... no builder has taken it: walled in on its level", PROJECT_BLOCKED stale "set aside 301 d", read only)
Module: `dfpilot/cmd.py` (`seal_openings`, `stair_piece`), `lua/dfllm/runner.lua` (`Q.boxed_cancel`, `Q.all_boxed`)

## Actual
status named `1 way in without door or bridge: 94,94,140 stair_updown`; `seal at=last` planned a hatch on it; the hatch sat 'not suspended, no builder has taken it: walled in on its level (no tile beside it to build from)'; after 30 days seal_stalled; the player cancelled it; the next `seal at=last` placed it again.

## Root cause
BUG-313 moved only the *refuge* hatch up its stair (`cmd.refuge_stair`, `seal.refuge_stair`). `seal_openings` handed every other opening on a stair (`piece_kind` stair_*) straight to the template, so a hatch went on a tile with no walkable neighbour on its level, where no builder can stand (`runner.lua` `Q.cls_of` 'boxed', BUG-313). The kernel only reported it (`seal_escalate`), and its own suggestion was `bp.place seal at=last` again.

## Fix
`cmd.stair_piece(snap, x, y, z)`: a stair tile walled in on all 8 neighbours moves up the same stair to the first level with a floor beside it (note `walled in on its level ... hatch moved to x,y,z+n`), a door/hatch higher up on it closes it (left out), every level above walled in or the stair ending is left out with "no builder can reach a hatch there" (a CLOSED_NOTES phrase: nothing to close); an unknown tile (hidden, off the snapshot) is taken as before; an explicitly named `at` tile is never changed. `Q.boxed_cancel`: a seal whose every unbuilt piece is 'boxed' (economy.build_state) for `seal_boxed_days` (30) after its clock stopped, in PEACE, not the refuge's seal, is cancelled by the kernel (`cancel`, no undo: only unbuilt pieces go) with PROJECT_BLOCKED why `boxed_cancel` and a kern.log line naming the pieces.

## Tests
`tests/test_bug535_538_f33.py` (4), `tests/lua/test_bug536_538_runner.lua` (2).

## Live check
`seal at=last` on that stair: `hatch moved to 94,94,<z+n>` or "nothing to close (... no builder can reach a hatch there)"; a boxed seal left over from before is cancelled by the kernel after 30 days with PROJECT_BLOCKED `boxed_cancel`.
Open: status and the entrance check still count the shaft as a way in (`ready.ents`); the kernel does not stop reporting it. A stair walled in on its level can still be a real route from the level above or below (an unknown level above is taken as buildable). gate.lua untouched.
