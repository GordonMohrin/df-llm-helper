# BUG-078 autoslab queued no engrave orders for two ghosts that waited for years; the kernel ordered none either
Status: fixed in HASH078 (offline, live-untested): the kernel orders the memorial slab itself for a ghost that stood
`economy.slabs.engrave_days` (3) days without an order or a memorial; unserveable ghosts are reported once
Severity: high (wrong decision: ghosts of the dead kept haunting; the cause of the plugin's silence is not decided offline)
Found: 2026-10-23, Run 14 Trussroads y582 (note 69), kernel of 9bcb14f
Module: `lua/dfllm/economy.lua` (`M.slab_pass`, new `M.slab_engrave`), `lua/dfllm/act.lua` (new `engrave_order`),
`lua/dfllm/orderfix.lua`, `dfpilot/schema.py` (`order.add`)

## Actual
`autoslab` enabled, 79 slabs with `slab_flag == 0` standing, two ghosts for years (33972: no coffin + undiscovered; 34732: no
body), `manager_orders` held 0 engraving orders.

## Causes, proved or not
1. **Is B2's trim the loop? Not for the observation, but it is real for the 79.** The trim keeps `min(slabs.max_orders,
   blank + busy)` EngraveSlab orders (base `economy.lua:6804`, `orderfix.lua:138`). `OF.slabs` counts a blank slab as free only
   when no flag of `OF.SLAB_SKIP` is set (base `orderfix.lua:35-62`); a slab that stands as a building has `flags.in_building`, so
   it is `held`, never `blank`. 79 built blank slabs give `blank = 0`: every EngraveSlab order the plugin queues is removed
   at the next pass ("no unengraved slab"), and the ConstructSlab restock (`OF.restock`) orders more blank slabs. That is
   right as far as a job is concerned (a slab that is part of a building is not an item a job takes; this is DF's rule,
   not proved from the repo), but the note counted the BUILDINGS and called them free. `tests/lua/test_economy_b2.lua` ("the
   79 blank slabs standing as buildings") proves the census (`blank 0, held 79, built 79`) and the removal. The new
   `slab.built` counter in `inspect orders` makes the difference visible.
   The note's observation (0 orders at one moment, years of silence) cannot come from B2: the live kernel was older than
   B2 (merged 2026-10-23, the same day). Trim at the daily pass and at the first cancel only removes orders that exist; it
   never explains an order the plugin did not queue.
2. **Why the plugin queued nothing: not provable offline.** The plugin's source is not in the repo. What BUG-061 recorded of
   `autoslab.cpp` (`checkslabs`, per ghost without a memorial and without an order for its figure; it does not check blank
   slabs) fits "queues per ghost"; the note's hypotheses (it handles `no_body` differently, or only new ghosts) cannot be
   decided without the plugin.
3. **Can ghosts of the `no_body` kind be served at all?** An EngraveSlab order names a figure (`specdata.hist_figure_id`);
   nothing in it needs a corpse. A ghost WITH a historical figure can be served by a memorial whether or not a body exists;
   one with `hist_figure_id < 0` (no figure) cannot be served by the plugin or by us.
4. **The kernel did nothing about ghosts either.** `ghost_alarm` (base `care.lua:2943`) only say "slab for no_body";
   economy ordered ConstructSlab but never the engraving (`economy.lua` slab pass, base).

## Fix
- `M.slab_engrave` (economy.lua, called by `M.slab_pass` after the trim): ghost list from `census.g` (sense; not trusted
  older than two days), first-seen day per ghost persisted (`p.slab_ghost`). A ghost older than `slabs.engrave_days` (3; 0 =
  off) whose figure has no memorial (`OF.slabs().topics`) and no EngraveSlab order (`specdata.hist_figure_id` of the
  orders that survive the trim) gets one order through the new `act.engrave_order(hf)`: job `EngraveSlab` (the name in the
  manager's list; `EngraveStoneSlab` does not exist), item SLAB, stone, one slab, specdata = the figure, created as the
  work orders screen / autoslab creates it; a `manager_order` without the field is deleted again. Bounded by
  `min(slabs.max_orders - standing, free blank slabs - ...)`, so the trim of the next pass keeps them (no loop) and the
  restock of ConstructSlab (counting them) serves the rest.
- Log (info, once per order): `EngraveSlab order N for ghost unit U (hf H, D days without a memorial or an order): the
  autoslab plugin queued none (B blank slabs, S orders standing, G ghosts)`. Ghosts without a figure: one warn line each,
  never retried (`p.slab_skip`), `slab.unserved` in `inspect orders`; a failed act is retried after 7 days.
- `order.add` knows the job: `{job: "EngraveSlab", amount: 1, hf: <figure>}` (schema.py, economy.lua verb, CONTRACTS §9);
  `hf` with any other job is refused. Config `economy.slabs.engrave_days` (baseline.json, fairplay limits 0..112).
- Contract: act `engrave_order` (schema.py ACT, contract.lua, CONTRACTS §5).
- Fair play: a manager order is the work orders screen's action; no item, unit or position is touched.

## Not decided offline
Why the plugin queued nothing. Read-only live data that decides it: (1) `dfhack-run plug autoslab` (state), (2) `orders` list
right after `autoslab` ran (its console prints `Queued slab for ...` lines if its debug category is on:
`debugfilter set Debug autoslab log`), (3) `dfllm cmd inspect '{"what":"orders"}'` -> `slabs` (`blank`, `held`, `built`,
`ghosts`, `engraved`, `unserved`), (4) kern.log `EngraveSlab:` lines (B2's trim) and the new `EngraveSlab order` lines.
Also open: the field path `manager_order.specdata.hist_figure_id` and whether `manager_order:new()` fills the other fields
like the UI (a wrong path is caught: no order is left behind and ACT_FAIL names it). Placing the engraved slab as a building
(so that the ghost rests) stays with the builders; this fix only orders the engraving.

## Tests
`tests/lua/test_economy_b2.lua` (BUG-078: the order per old ghost, none for a served ghost / memorial / no blank slab, the
bounds, no figure reported once, stale census, back-off, the 79 built slabs, order.add), `tests/lua/test_act_supply.lua`
(`engrave_order`), `tests/test_fr_econ.py` (schema). Each fails on 9bcb14f.

Related: BUG-061, FR-10; note 69
