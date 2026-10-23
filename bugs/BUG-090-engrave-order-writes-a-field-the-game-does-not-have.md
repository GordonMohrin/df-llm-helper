# BUG-090 The kernel's memorial order (BUG-078) is never made: act.engrave_order writes a bit the game's structure does not have
Status: fixed in the integration audit J2 commit (offline, live-untested)
Severity: high (wrong decision: the ghosts of Run 14 note 69 would still get no slab; every try ended in an ACT_FAIL and a 7-day back-off)
Found: integration audit J2 (2026-10-23), `act.engrave_order` read against the structures the game ships (df-structures, DFHack's
autoslab.cpp), not against the fakes of the tests
Module: `lua/dfllm/act.lua` (`engrave_order`), `tests/lua/test_act_supply.lua`

## Actual
BUG-078 (0cb9c33) gave the kernel its own memorial order: `economy.slab_engrave` calls `act.engrave_order(hf)` for a ghost that stood
`slabs.engrave_days` days without a memorial or an order, and the verb `order.add {job: EngraveSlab, hf}` calls the same act. The act
built the order with `o.material_category.stone = true`. `job_material_category` (df.d_basics.xml) has the bits plant, wood, cloth,
silk, leather, bone, shell, wood2, soap, tooth, horn, pearl, yarn, strand: no `stone`. DFHack raises on a write to a bitfield flag
that does not exist (`LuaTypes.cpp meta_bitfield_newindex`: `lookup_container_field(state, 2, "write")` -> "Cannot write field
job_material_category.stone: not found"), so the `pcall` of the act caught it, deleted the half-made order and answered
`manager_order has no such field`. Live, no EngraveSlab order of the kernel could ever exist: `slab_engrave` booked an ACT_FAIL per
ghost every 7 days (`p.slab_skip`), `order.add` failed the same way. The tests did not see it: the fake `manager_order` of
`test_act_supply.lua` gave `material_category` as a plain table that takes any key.

## Cause (proved from the sources, not from a live run)
- `act.lua` `engrave_order` (0cb9c33): `o.material_category.stone = true`, and `o.item_type = SLAB`, `o.mat_type, o.mat_index = -1, -1`
  "as the work orders screen creates it" -- nothing in the repo or in DFHack says so.
- DFHack's own `autoslab.cpp` `createSlabJob` sets exactly: `id`, `job_type = EngraveSlab`, `specdata.hist_figure_id`, `amount_left = 1`,
  `amount_total = 1`, `frequency = OneTime`, and pushes the order. df.job.xml gives `EngraveSlab` no `item` attribute (ConstructSlab has
  `item = SLAB`), so a memorial order names no item type.
- The `order.add` verb accepted any `hf >= 0`; `workorder.lua` refuses a figure that does not exist ("Missing historical figure for
  manager order").

## Fix
- `act.engrave_order` writes the plugin's fields only (id, job_type, amount_left/total, frequency, `status.validated/active = false`,
  `specdata.hist_figure_id`); item type and materials stay at the structure's defaults, as the plugin leaves them.
- A figure `df.historical_figure.find` does not know is refused (`no historical figure N`; skipped where the table is absent).
- Contract: CONTRACTS section 5 row `engrave_order` says what the order is; schema.py and contract.lua are unchanged (same act, same
  owner, same arguments).

## Test (fails on c038ce9)
`tests/lua/test_act_supply.lua` builds the order on a struct that lists exactly the fields of df-structures (manager_order,
job_material_category, job_spec_data, manager_order_status) and raises on any other read or write, as DFHack does: the order is made,
its job, amount, frequency and figure are right, `item_type` stays NONE, only the plugin's fields were written, one order per figure,
an unknown figure is refused, a struct without `specdata` leaves no order behind.

## Not decided offline
- Whether the game takes the order with the defaults for item type and material exactly as with the plugin's: the plugin runs
  with them in every fort that enables it, and the kernel's order is now field for field the same. Live check: `dfllm cmd order.add
  '{"job":"EngraveSlab","amount":1,"hf":<figure of a ghost>}'`, then the manager's list must show "Engrave Memorial Slab" and a mason with
  the ENGRAVER labor must take it (ORDER_STUCK `no worker ENGRAVER` names a fort without one; nothing in the kernel switches that labor on).
- The engraved slab still has to be BUILT (placed as a building) before the ghost rests; no kernel code does that (the memorial counts
  as served for the pass, so no second slab is ordered).

Related: BUG-078, BUG-061
