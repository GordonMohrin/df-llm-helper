# BUG-126 The coffin provisioner (FR-61) ordered nothing for three game years: `coffins want 67, short 10, stock 4, order 0, proj cof272266509` with 62 bodies and 21 ghosts waiting
Status: fixed in the BUG-126 commit (offline, live-untested)
Severity: critical (loses citizens: unburied dead, ghosts, failed moods; the game session had to order by hand)
Found: 2026-10-27, Run 14 (y710-y711), game session note 103
Module: `lua/dfllm/care.lua` (`coffin_order`, `coffin_proj` new, `coffin_view`), `lua/dfllm/runner.lua` (`coffins_state`, `coffins_drop` new)

## Actual
`brief` said for three game years `coffins want 67 short 10 stock 4 order 0 proj cof272266509`; 509 tomb zones stood, but no free tomb and
no burial job (a tomb is a coffin BUILDING in a tomb zone, a coffin item in stock is no tomb); 62 bodies, 21 ghosts. The kernel ordered no
coffin and placed no new row of coffins; the session sent `order.add {"job":"ConstructCoffin","amount":6,"material_category":["wood"]}`
by hand (that worked; `stone` as `material_category` is refused: "Invalid material_category value for manager order: stone").

## Cause (proved from the code at f3f684b, reproduced offline with the k_mock before any change)
The provisioner (care.lua, phase `coffins`) can order nothing in exactly this state, and every branch that decides it is in the code:
1. `coffin_order`: `items = min(want - free - idle, planned + cs.new)`, `make = items - stock - order`. Only the PLANNED coffins (unbuilt coffin
   buildings that wait for an item) and the rows placed in this very run (`cs.new`) are counted. The `short` coffins (no building yet) are
   not. With a pending project and `cs == nil`: `items = planned`, and with `stock >= planned` (the live `stock 4`), `make = 0` for ever.
2. `phase_coffins_run`: the space search starts only with `q.pend == 0` (`runner.pending('tombs')`); `pc.proj` is cleared only when `pend == 0`.
   The brief's `proj cof272266509` therefore proves `pend > 0` for three years: the provisioner's own project never ended.
3. `runner.lua` `Q.parked`/`Q.terminal`: a project is parked (and stops counting for `pending`) only when it is blocked for good (`build_lost` with
   the retries spent, `breach:*`, `apply_fail`, `bp_missing`, `plug_refused`). A `tombs.build` stage that waits for coffin items (not built) is
   `running`/`stalled`, never terminal: it counts for ever, and the kernel "never cancels a project itself".
Not the cause (checked): the order counter (`manager_order_next_id` is read per order), `oretry` (set only after a refused order, one game day),
the act budget (`workorder` has no per-run budget), `C.ACT.workorder` (contains `care`), the order queue (stuck rock orders are counted as
`stuck`, not as `order`, so a full queue of unrunnable orders does not block a wood order), a cap (`coffin_batch` limits one round to 30).
The wood-only gate does not exist (stone and wood are both ordered); a missing census would also return silently (`not q.census`).
Reproduction (tests/lua/test_care_coffins.lua, scene `stale_scene`): 3 dead, the first wave places 13 planned coffins and orders them; the
order vanishes, 13 coffin items stand in stock, `coffin_reserve` 20. On f3f684b: `want 23, short 10, stock 13, order 0, pend 1, planned 13,
items 13, make 0`, no workorder act, no search (`probes` nil), one tombs project, for as long as the scene runs.

## Fix
- `coffin_order`: `items = min(want - free - idle, planned + short)` while a citizen body waits (`open > 0`): the short coffins' items are
  made ahead (batch 30, minus stock and the open orders that can run). With nobody waiting only the rows placed in that run are added (as
  before), so a fort without dead and without material is not asked about spare coffins. The reserve (`coffins_missing`, critical
  logs/boulders) still counts only the planned coffins.
- Material order: wood first (`material_category = {'wood'}`, logs beyond `coffin_wood_keep` 20, carpenter's workshop), then hard stone through
  `material = 'INORGANIC'` (the same field economy's door/slab orders use; `material_category` has no stone bit), masons' workshop. Neither:
  DECISION_NEEDED `coffin_material` (class A, cadence-limited: `ghost_every` / `wake_wall_s`), naming stone, logs and workshops.
- `coffin_proj` (new, once a run): the provisioner's own project is read through `runner.coffins_state`; unknown to the runner: forgotten;
  `stage:chunk:pct` unchanged for `coffin_stale` (config `care.coffin_stale`, 15 game days) of PEACE: dropped through `runner.coffins_drop`
  (cancel without an undo; the planned coffins stay and are ordered, `burial -c` zones them once built). Then pend is 0 again, the search
  places rows for the short coffins and the empty-zone repair (`1x1 zones without a coffin`, held back by any pending tombs project) runs.
- Vanished orders are re-issued by the recount of `manager_orders` every run (the order is not remembered); unrunnable ones are `stuck` and
  the same amount is ordered in the other material.

## Not decided offline
- Why the live project's coffins never got built (buildingplan did not take the 4 stock coffins?): the kernel cannot read buildingplan's
  state; the drop makes the deadlock end whatever the cause. Live: `inspect tombs` shows `(no progress N d)` before and `1 stale project(s)
  dropped` after; kern.log `coffins: project ... made no progress for N d`.
- Wood first on a hard-stone map spends logs beyond the keep of 20 on spare coffins (the old order was stone first); `coffin_wood_keep` is the knob.

## Tests (`tests/lua/test_care_coffins.lua`, each fails on f3f684b)
- short coffins are ordered while a project that cannot finish is pending (order 10 where f3f684b ordered 0).
- a project without progress for 15 days is dropped, a new one places the short coffins; a project that builds a coffin now and then is not.
- no space found: the short coffins are ordered, wood first then `INORGANIC`, never `material_category` stone.
- neither wood nor hard stone: DECISION_NEEDED `coffin_material` once a week.
- the FR-61 material tests follow the new counts (planned + short) and the wood-first order.
