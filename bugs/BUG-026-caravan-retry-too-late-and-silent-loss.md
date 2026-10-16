# BUG-026 a caravan visit was lost to one ui_timeout: the retry waited longer than the caravan stayed, and nothing said why
Status: fixed (offline, live-untested): kernel boost, trade clock, phase limits on the module's own clock, retry units (2026-10-16)
Severity: medium (a whole caravan visit is lost; here the dwarven caravan that might have sold iron)
Found: 2026-10-16, Run 10 fort Erushthak Handlelock (region2-site97, y416 summer), Muboomon's caravan, Claude playing
Module: `lua/dfllm/trade.lua` `finish` (retry), `track_visits` (left)

## Actual
```
#4570 CARAVAN caravan from Muboomon Approaching
kern.log  trade: 0 sale items sent to the depot / no TradeAtDepot job 300 ticks after the caravan reached the depot: posted
#4579 CARAVAN trade with Muboomon retries: ui_timeout         (nothing about the phase)
inspect what=trade: Muboomon AtDepot time_left 962 -> 381 -> Leaving, 231 merchant goods, no second attempt, no ledger entry
```
`RETRY_WAIT` is 1200 ticks; the caravan had 962 left, so the retry never ran. The visit left no ledger entry and no failed event (`left` only), so `inspect what=trade` still showed Catten's ledger on top.
Context: kernel `trade promoted x1` shortly before, `selftest quick failed: budget (48 ms/s > 40, top trade 23 ms/s)`, an audit snapshot (58608 tiles) finished mid-visit, game ran at 270-390 ticks/s. The first UI phase exceeded 2 x PHASE_MS (12 s real time) once;
Catten's visit 20 days earlier ran the same code at the same speed and traded (ratio 1.68).

## Fix (this commit)
1. A retry waits `min(RETRY_WAIT, max(RETRY_MIN 100, time left - RETRY_KEEP 400))` ticks.
2. The `CARAVAN retry/failed` event carries `ph` (the phase that timed out), `ph_ms` (real ms in it) and `left` (ticks the caravan still stays), and says so in the message.
3. A caravan that reached the depot and leaves with no ledger entry gets one (`unmet ...:left_untraded`) so TRADE_LEDGER and `inspect what=trade` show the lost visit.
Tests: two new cases in `tests/lua/test_trade.lua`; both fail on the old code.

## Open
Why the first UI phase timed out is unknown. Suspects: kernel time share (trade paced to 3 ms/s while the kernel was over budget), a heavy audit snapshot in the same minutes, or a popup. Next visit: read `ph`/`ph_ms`; if it is a UI phase that starves, give trade a larger share while a caravan stands at the depot (and slow the clock with `tempo.lower`).

Related: BUG-016 (visit logic), BUG-025 (depot)

## Review (Claude, 2026-10-16) of 6e34f8a
- **Unit error.** `caravan.time_remaining` counts 10-tick units (DFHack `caravan.lua`: `days * 120`; trade.lua's own `START_MIN` comment).
  "962 left" was 9,620 ticks, so `RETRY_WAIT` (1,200 ticks) fitted eight times; the diagnosis "the retry waited longer than the caravan stayed"
  does not hold. The formula `min(1200, max(100, tr - 400))` mixed units: it cut the wait to 562 ticks here and to `RETRY_MIN` (100 ticks)
  below 500 units, and `left` / "N ticks left" in the event were units. The inspect reads (962 -> 381, 581 units = 5,810 ticks, ~15-21 s at
  270-390 ticks/s) fit the 10-tick unit; ~2 s between two LLM `inspect` calls would be needed with 1-tick units.
- **What really lost the visit.** After the retry the visit was in WAIT, and `step_wait`'s first check ends a visit whose caravan is
  `Leaving` as `failed: leaving` (with a ledger entry). The visit ended with `left` only, so trade did not run a single step between the retry
  and the caravan's departure (at least the ~30 s real time the 962 units took). That is starvation, not the wait: trade was paced at its
  3 ms/s share (scaled down to half in the PEACE pool) after expensive calls (`selftest ... top trade 23 ms/s`: a one-off call like
  `act.trade bring`, `logistics now` or the session's `inspect what=trade`, each charged to trade, leaves a debt that takes minutes to drain
  at 1.5-3 ms/s), and the UI phase before it timed out on real-time `PHASE_MS` while the module ran only every few seconds (demoted x4, paced).
- Time left unknown (no caravan record): the wait stays `RETRY_WAIT` and the next WAIT step ends the visit `gone`; `time_remaining <= 0` means
  Leaving. Both fine. A retry was also scheduled when the screen could no longer open (`time_remaining < OPEN_MIN` after the wait), so the visit
  failed later as `time` and the ledger lost the real reason.
- **Ledger.** No duplicate for one visit: traded/failed set `ledgered`, `ui_busy` never writes one, `left_untraded` only with `ledgered == 0`.
  Edge: a visit persisted before 6e34f8a has no `ledgered` key; if it had already failed, its departure writes a second entry once (accepted).
  Bug: the `left_untraded` entry was built from `rt.f`, the flow of whatever visit trade was working on; when a second caravan left while
  another visit was current, its unmet list showed the other caravan's goods (`anvil:none`).
- **Schema.** The new `CARAVAN` fields (`why`, `focus`, `ph`, `ph_ms`, `left`) were not declared in `dfpilot/schema.py` (only accepted as
  untyped extras). `read_caravans()` ran twice in `finish`.

## Fix (Claude, 2026-10-16)
- **Kernel boost** (`util/sched.lua` `S.BOOST`, `kern.lua`, `k_mock.lua`; CONTRACTS §3.3.9, §4): `K.boost(why, busy)` / `K.unboost()` /
  `K.busy()`. A boosted module (only `trade` is allowed) is not demoted (its cadence ignores the factor, slow calls do not count), is paced at
  20 ms/s outside the PEACE pool (its cost counts as unpaced, so the other modules' pool shrinks), and its debt is cut to one second of share
  when the boost begins and ends; 30 s TTL, renewed every step; a back-off ends it. `busy` asks heavy background work to wait:
  snapshot exports (`snapshot: export <id> waits while trade is busy`) and seal's non-urgent jobs. `inspect what=modules` shows `boost`.
- **trade holds the boost** from the start of a visit in PEACE (WAIT with the caravan approaching, at most `STUCK_APPROACH` ticks, or at the
  depot; a pending retry included) and is busy in every UI phase; it lets go at LEAVE/IDLE and outside PEACE.
- **Trade clock** (`arbiter.lua`, `trade.clock()`, CONTRACTS §7, §9.18): from the first UI phase of a visit until the visit ends (traded,
  failed, left; a pending retry included) the arbiter caps the FPS at `clock.trade_cap` (config/reflex.json, default 100; timestream above
  it goes off), never above the captured original; logged `trade clock on: FPS cap 100 (trade)` / `trade clock off`, state `clock.why = trade`.
- **Phase limits on the module's own clock** (`rt.clk`: real ms between two trade runs, at most `RUN_MS` = 250 per run): `PHASE_MS` (ui_busy,
  ui_timeout), `TALK_MS` and `REPLY_MS` no longer fire because trade itself waited. `CARAVAN retry/failed` carry `ph`, `ph_ms` (real ms),
  `ph_act` (own clock), `ph_runs` and `left` (ticks); declared in `dfpilot/schema.py`, CONTRACTS §12.
- **Retry units**: `TR_TICKS = 10`; the wait is `min(RETRY_WAIT, max(RETRY_MIN, (time_remaining - OPEN_MIN) * 10 - RETRY_KEEP))`; with less
  room than `RETRY_MIN` there is no retry (the visit fails with its own reason). `left` is in ticks; `inspect what=trade` adds `left_ticks`.
- **Ledger**: `ledger()` takes the visit's own flow; a departing caravan never gets another visit's goods.
- Tests (all fail on the old code): `tests/lua/test_trade.lua` `BUG-026 review: time_remaining counts 10-tick units ...`, `a starved trade
  module (40 ms a run) still trades ...`, `the boost holds while the visit is on ...`, `a retry after a UI phase keeps the boost ...`;
  `test_trade_ledger.lua` `BUG-026 review: a caravan that leaves untraded gets its own ledger ...`; `test_kern_load.lua` `BUG-026 boost: ...`
  (two cases, the real kernel); `test_kern_arbiter.lua` `BUG-026 trade clock ...`; `test_snapshot.lua` and `test_seal.lua` `BUG-026: ... busy
  boost ...`. The old retry test (`tr = 700` read as ticks) was replaced.

## Live check (next caravan)
- kern.log: `trade boosted: caravan approaching, <civ>`, `trade boost ended (unboost; ...) after N s, M ms charged`; arbiter
  `trade clock on: FPS cap 100 (trade)` when the trade screen opens and `trade clock off` after the visit; `snapshot: export ... waits while
  trade is busy` if an audit export overlaps.
- `dfllm cmd inspect '{"what":"modules"}'`: trade `boost` set and `factor` 1 while the caravan is on the map; `state.json` `clock.cap 100`,
  `clock.why trade` while the trade screen is open.
- A `CARAVAN retry/failed`: `ph_ms` much larger than `ph_act` = trade waited (should no longer time out); `ph_act` >= 12000 with many
  `ph_runs` = a real UI hang (report the phase). `left` is in ticks.
- Units: two `inspect what=trade` reads with their ticks: the drop in `time_left` x 10 should match the ticks passed.
