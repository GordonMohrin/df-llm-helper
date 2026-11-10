# BUG-655 Hospital 'build_lost, missing b x4': nobody could tell what b is or what the beds wait for
Status: fixed (offline, live-untested): the input is named and a DECISION with the fix is raised; the live reason the bed tiles stay empty is not proven
Severity: high
Found: 2026-11-10, Run 16a i1 Basementflew y442-y466 (hospital projects c1a1c11cf, c1a1c154, c1a1c49e5, c1a1c528dc4b6d5801, c1a1c563bf7041c401: 'build_lost at build, missing b x4', 8 retries a project, cancelled by the kernel after 60 days), Run 16b i2 Valleyhame (hospital and bedrooms surface=1 'missing b x4', 300+ days)
Module: `lua/dfllm/runner.lua` (`piece_name`, `M.PIECE_WORD`, `Q.supply_why`, `blocked_event`, `Q.lost_cancel`), `lua/dfllm/economy.lua` (`M.piece_supply`)

## Actual
`PROJECT_BLOCKED ... missing b x4; retry n/8` for a hospital with `beds 4 bench 0` (chests and the table 'go through'), 283 logs in the fort, `Q.mat_why` silent (the planner's route for a bed said 'wood'), no 'Make bed' cancel in the gamelog, no ConstructBed order in commands.log after the player's one `order.add ConstructBed x4` (tick 179,499,024, c1a1c154). Nobody could tell what `b` was, what the beds waited for, or what to do.

## What `b x4` is
`b` is the quickfort build key of a BED in the room templates (`dfpilot/bp/rooms.py _surface_hospital`: beds in the bottom rows, `b.tile(i, H-1, 0, "b")`); `x4` is the number of those cells with no building on their tile (`runner.missing_pieces`). The key was printed as it stands in the document.

## Why it cannot be supplied (what the logs prove, and what they do not)
- The stage's `quickfort orders` made ONE manager order for 4 items (kern.log 'c1a1c528dc4b6d5801 build: 1 manager orders, 4 items'): the bed order. The planner's route said 'wood' (`economy.mat_for('bed')` = Carpenters + logs), so no material text appeared.
- The tiles stay EMPTY: no planned bed building exists there, so nothing waits for a bed item and the order for what a planned building waits for (`T.jmake`) never has a reason to make or move a ConstructBed order.
- Part of the cause in Basementflew is BUG-654: the fort's workshops of the second set (Carpenters 33,108,117 with the Kitchen) stood in the flooded z117; the manager gives a shop one job at a time, and the cut-off Carpenters held the ConstructChest ('unreachable ConstructChest x1' in `inspect workload`) in front of the bed order. The Carpenters at 107,92,129 / 103,70,129 / 119,80,129 of the manifest are not shown reachable or not by any log.
- NOT proven: why quickfort / buildingplan placed no bed building on the tiles while the chest and the table were placed (the logs carry no per-key 'unsuitable' count). Candidates: the bed refused on the block's tiles, the order stuck, the planned building removed again. The new text separates the supply side live.

## Fix
- `Q.supply_why` + `economy.piece_supply(kind, n)`: per missing piece kind (bed, chest, table, chair, cabinet, door, hatch, grate) what the supply lacks: `no_shop` (no Carpenters / Masons stands), `cut` (it stands, no citizen can walk to it: BUG-654), `no_logs` (a bed is wood only, logs < n), `no_order` (nothing makes them), `ordered` (an order stands, the shop has not made them), `item` (free ones stand). Text 'bed x4: ConstructBed x0 open, Carpenters stands, logs 283: nothing makes the missing 4' and the command that fixes it: `order.add ConstructBed`, `bp.place workshops only=Carpenters`, `trade.want add wood`.
- PROJECT_BLOCKED (build_lost, not a seal): the text goes into `d.mat` and the message when the planner has no material word of its own; the kernel's autocancel line carries it too.
- When the retries are spent: DECISION_NEEDED `piece_missing` (A, once per project and stage: the final blocked event is cadence-gated) with `cmds` (up to 3 command lines), for example 'c1a1c528dc4b6d5801 (hospital) lost its pieces 8 times: bed x4: ConstructBed x0 open, Carpenters stands, logs 283: nothing makes the missing 4' with `dfllm cmd order.add '{"job":"ConstructBed","amount":4}'`.
- `piece_name`: the build keys b / h / t / c / R are printed as bed / chest / table / chair / traction bench (`missing bed x4`); d, p, Cw, B1, trap keep their older names.

## Tests
`tests/lua/test_bug655_hospital_beds.lua` (3: `missing bed x4` plus the supply text in `d.mat`, DECISION `piece_missing` once with the order.add command at retry_max, nil when supplied), `tests/lua/test_bug654_656_cut_shops.lua` (the codes of `piece_supply`).

## Live check
The next hospital that loses its beds: PROJECT_BLOCKED 'missing bed x4 (bed x4: ...)' and, after the retries, the DECISION. If the text says 'ordered' or 'no_order' with the shop standing and the tiles stay empty, quickfort's refusal of the bed cells is the open cause (a dry-run count per key would show it).
