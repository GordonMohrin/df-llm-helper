# BUG-119 `order.add EngraveSlab` failed for 7 of 8 ghosts with "manager_order has no such field ... Cannot write field job_material_ca": the note blamed the scan of the foreign orders, the text is the write of BUG-090
Status: already fixed by BUG-090 (J2 commit) in the base; hardened and pinned here (offline, live-untested)
Severity: medium (no memorial slab, the ghosts stayed; fixed before this package, the wrong cause would have sent a fix to the wrong place)
Found: 2026-10-25, Run 14 (region2-site90), game session note 75
Module: `lua/dfllm/act.lua` (`engrave_order`), `tests/lua/test_act_supply.lua`

## Actual
The game session ran `order.add {job:"EngraveSlab", hf:<id>, amount:1}` for eight ghosts (`corpse_far`). Seven answered
`ERR ... engrave_order: manager_order has no such field: ...act.lua:1497: Cannot write field job_material_ca...`, the eighth `already`.
The note read line 1497 as the scan over `world.manager_orders.all` (`o.specdata.hist_figure_id == hf` of a foreign order whose union
holds `job_material_category`) and asked for a `pcall` around the loop and a tag check.

## Cause (proved from the code at 32994bb)
- The message text is made in exactly one place: `act.lua:1511` `return false, 'manager_order has no such field: ' .. trim(err, 100)`, the
  answer of the **write block** (`act.lua:1503-1510`, a `pcall` around the field writes of the NEW order). The scan at `act.lua:1497`
  is a `pcall(function() return o.job_type == jt and o.amount_left > 0 and o.specdata.hist_figure_id == hf end)` per order: a read
  that raises is `ok == false` and counts as "not the same", it can never reach line 1511. `specdata` is read only after
  `o.job_type == jt` is true (and short-circuit), i.e. only for an EngraveSlab order.
- The error text "Cannot write field job_material_ca[tegory.stone: not found]" is DFHack's answer to `o.material_category.stone = true`,
  the line BUG-090 removed (`bugs/BUG-090-engrave-order-writes-a-field-the-game-does-not-have.md`). The line number 1497 of the
  game session's copy is the old write line: at 0cb9c33 (BUG-078, `git show 0cb9c33:lua/dfllm/act.lua`) line 1497 is
  `o.material_category.stone = true` and the scan is line 1490; BUG-090 (9388d5f) removed the write and the lines moved. The eighth ghost
  answered `already` because the scan found an order of an earlier session (no write).
- Conclusion: note 75 was solved by BUG-090 before it was written (the live kernel ran the code of BUG-078). The union-read hypothesis is
  not supported by the code: every read of a foreign order's `specdata` is inside a `pcall` (`act.lua:1497`, `economy.lua:2359`,
  `economy.lua:6872`).

## Fix
- Regression tests only for the proof above, plus one hardening: the whole walk over `mo.all` is one `pcall` too (a vector that faults
  midway used to raise out of the act; the verb then answered with the act wrapper's error, no order). A scan that faults finds nothing
  and the order is made: a second memorial order costs one slab, a missing one costs a ghost (the caller `slab_engrave` keeps its 7-day
  back-off per figure).
- No contract change.

## Not decided offline
- Whether the live DF 53.16-r3 takes the order (BUG-090 "Not decided offline"): read `kern.log` after the next `order.add` for a ghost;
  the manager's list must show "Engrave Memorial Slab".

## Tests (`tests/lua/test_act_supply.lua`)
- BUG-119: a foreign order whose `specdata.hist_figure_id` raises "Cannot write field job_material_category.stone" (read) and an
  EngraveSlab order whose figure cannot be read: the order for another figure is made, `already` for a figure that has one.
- BUG-119: a `mo.all` that faults at its second element: the act answers `true, id` (fails on 32994bb: the raise).
