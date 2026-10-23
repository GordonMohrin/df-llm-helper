# BUG-061 31 EngraveSlab orders fill the masons' slots with jobs that cancel at once: doors, coffins, tables, blocks and slabs wait ten game years
Status: fixed in b1ac67a and 322bd4b (offline, live-untested)
Severity: critical (Run 13: monthly missing doors, coffins and tables, five buildings "stalled", 15 old ghosts never calmed,
the fort fell with the economy jammed)
Found: 2026-10-23 from the game session's notes 45 and 56 (`bugs/RUN11-offene-bugs-und-FR.md`): Run 13 Wheelsblows y523,
Run 14 Trussroads y577; DF 53.16 with DFHack's autoslab
Module: `lua/dfllm/economy.lua` (T.slabs, M.slab_pass, M.slab_event, M.jam_scan, T.ocheck, M.order_reasons),
`lua/dfllm/orderlib.lua`, new `lua/dfllm/orderfix.lua`, `dfpilot/schema.py`, `dfpilot/brief.py`

## Actual
- Run 13 y523: autoslab and the library held 31 active `EngraveSlab` orders (cancel text "Needs unengraved slab"). The
  manager put their jobs into the Masons workshop (5 slots); each cancelled at once and pushed out every other mason job
  (door, coffin, table, block, slab). Effect over ten game years: doors, coffins and tables missing, 5+ buildings
  "stalled", ConstructSlab never got a turn, so 15 old ghosts were never calmed. By hand: all EngraveSlab orders removed
  from `manager_orders.all`, the masons were productive at once (note 45).
- Run 14 y577 (note 56): autoslab ran, but the 71 slabs in the fort belonged to old figures (hf 3800-4100); no blank
  slab existed for the 9 new ghosts (hf 6091-6411), so nothing was engraved; after `enable autoslab` and a ConstructSlab
  supply 49 EngraveSlab orders were active.

## Cause (base f17e2b3)
1. **Nothing in the kernel knew the job.** `EngraveSlab` and `ConstructSlab` did not occur in any kernel code except
   `lua/dfllm/orderlib.lua:73` (ConstructSlab at the masons); `baseline.lua:31` / `config/baseline.json:5` only enable
   `autoslab`. No rule limited the orders, counted slabs or ordered blank slabs.
2. **The plugin queues without stock.** DFHack `plugins/autoslab.cpp` (`checkslabs`, `CYCLE_TICKS` 1289): per ghost
   (`flags3.ghostly`) without a Memorial slab (`engraving_type == Memorial && topic == hf`) and without an EngraveSlab order
   for its hf it pushes one order (`createSlabJob`, `specdata.hist_figure_id`). It never checks blank slabs and never
   orders ConstructSlab (its header lists that as an unbuilt idea; its doc says "make sure you have spare slabs"). One
   order per ghost: 31 ghosts, 31 orders.
3. **The stuck analysis was blind to it.** `orderlib.lua:68` `O.WS` had no `EngraveSlab` entry; "an unknown job or
   material is never reported as stuck" (`orderlib.lua:10-11`), so `M.order_reasons` (`economy.lua:3861`) returned nil and
   `T.ocheck` (`economy.lua:5818`) reported nothing, for the 31 orders and for the doors behind them.
4. **The cancel pruner could not keep up.** `cancel` (`economy.lua:2200`) finds the order by name (`find_order_named`,
   `economy.lua:2148`: the first order whose name matches) and `needs_cancel` (`economy.lua:2174`) removes it after
   `orders.needs_drop` (10) "Needs ..." cancels within 7 days: 31 orders cost 310 cancels, one order at a time, while
   autoslab queues the removed hf's order again within 1289 ticks.
5. **The slab supply was nobody's.** A ghost with no blank slab got an order that could never run (note 56); the
   old-figure slabs do not count (`topic` is another hf). autoslab's doc points at `library/rockstock` for the blank
   slabs; the fort imported it by hand (post-mortem Run 13), but its ConstructSlab order sat behind the jam in the same
   five slots (note 45: "ConstructSlab never got a turn"), and the kernel did not order slabs itself.

## Fix (b1ac67a and 322bd4b)
- **`orderfix.lua`** (library): `OF.slabs` (items.other.SLAB: `engraving_type` Slab -1 = blank, Memorial 0 = engraved;
  a blank slab a running job holds is `busy` and keeps that job's order, forbidden, built and carried-off blanks are `held`,
  not free), `OF.engrave_split`, `OF.restock`, `OF.shops` (the job
  lists of the built workshops and furnaces, each job with its `order_id`), `OF.jam_text`, `OF.simple_spec`.
- **Slab pass** (`M.slab_pass`, daily as T.slabs after `scan`, and at the first "unengraved slab" cancel report per
  `slabs.trigger_ticks` 600, `M.slab_event`): at most `min(slabs.max_orders 3, free blank slabs)` EngraveSlab orders stand
  (the oldest); the rest are removed (`slabs.drop_per_day` 60), kern.log `EngraveSlab: 31 orders, 0 unengraved slabs (0
  in jobs, 0 held), 6 ghosts: orders 1,2,...,12 +19 removed, 0 kept (at most 3)`, ORDER_STUCK (B, util/cadence: once per episode,
  `why` `slab: no unengraved slab`, n = orders removed, dropped 1). ConstructSlab first: with ghosts (care state) or
  engrave orders the stock plus the open ConstructSlab orders are brought to `min(slabs.restock_cap 5, max(ghosts,
  orders))` (`dfllm:slab`, INORGANIC, needs a Masons shop and free stone; else `st.slab.why` for `inspect orders`).
- **The stuck analysis says so.** `OL.input('EngraveSlab')` is `slab_blank`, `O.WS` has `EngraveSlab`/`SpinThread`.
  T.ocheck's first slice runs `M.jam_scan`: for each workshop type the jobs whose order cannot run
  (`M.order_reasons`); at least `slabs.jam_min` 3 of them and half of the jobs make a jam, and every order of that
  type with no reason of its own gets `masons' slots full of cancelling jobs (EngraveSlab x5: no unengraved slab)`
  (ORDER_STUCK, `inspect orders`). State `orders.jam` (str <= 80, CONTRACTS §9.3), status `orders N stuck M JAM ...`.
  `inspect orders` also carries `slabs`, `shops` (per workshop key: shops, jobs, working, blocked) and `jam`.
- Config (`lint --config`): `economy.slabs` (`false` switches the pass off).

## Not decided offline (the read-only live data that decides it)
- **Does autoslab outrun the trim?** autoslab.cpp queues again every 1289 ticks for each ghost without an order and
  without a memorial slab, so every removal is repeated. The event path cuts the orders back at the first cancel report
  (minutes, not a day), but whether the masons still lose slots between the queueing and the cut needs the live log:
  `kern.log` lines `EngraveSlab: N orders ...` per game day, `inspect orders` `shops` (workshop:Masons `jobs`/`blocked`)
  and `slabs` (`blank`, `engrave`, `removed`, `ordered`). If the churn is large the next step is `disable autoslab`
  while `blank == 0` (an allowlist entry and a fair-play check; not built).
- **The exact cancel text.** The session quotes "Needs unengraved slab"; the job caption is "Engrave Memorial Slab"
  (`df.job_type.EngraveSlab`). The event path matches `unengraved slab` in the reason only. Live: one CANCEL_JOB REPORT
  (`events.log`, type REPORT) of such a cancel.
- **Whether `engraving_type == Slab (-1)` is the blank state in 53.16.** autoslab.cpp reads the same fields; `OF.slabs`
  treats an unreadable value as blank. Live check: `SLAB` items with `engraving_type`, `topic` (one Lua read).
- **Free slabs behind walls.** `blank` counts no reachability; a blank slab on a cut-off walk group still cancels. The
  stuck analysis names it as a jam when it happens.

## Tests
`tests/lua/test_economy_b2.lua` (31 orders removed and logged, ConstructSlab first; the oldest min(3, slabs) stay,
forbidden slabs are no stock; the cancel event cuts back at once and once per window; ghosts without orders restock
(note 56), none when stocked, no Masons / no stone named; `drop_per_day`, `slabs = false`; the jam reason in ORDER_STUCK,
state and inspect; the jam rule; orderlib/orderfix units), `tests/test_b2_orders.py` (state `orders.jam`, status line),
`tests/lua/test_economy_b2_wait.lua`. Each new test fails on f17e2b3.

Related: BUG-060 (the doors behind the jam), BUG-042 (door order cap), BUG-062 (tomb zones; the ghosts' other cause),
FR-73, `docs/v2/POSTMORTEM-run13-wheelsblows-y525.md` (lesson: look at the workshop job list first).
