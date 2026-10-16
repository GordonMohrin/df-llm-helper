# BUG-026 a caravan visit was lost to one ui_timeout: the retry waited longer than the caravan stayed, and nothing said why
Status: mitigated (retry timing + diagnostics + ledger, tests), cause of the first ui_timeout unknown
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
