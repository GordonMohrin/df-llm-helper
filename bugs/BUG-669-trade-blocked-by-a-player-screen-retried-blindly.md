# BUG-669 A player screen over the trade: every retry a 6 s OPEN phase with the trade clock on, the ledger says 'time'
Status: fixed (offline, live-untested)
Severity: medium
Found: 2026-11-10, Run 16a i1 Basementflew (three caravans in a row, Catten, Muboomon, Catten; events.jsonl:18139 / 18235 / 18283): `trade with Catten blocked 3 times by the screen dwarfmode/ViewSheets/UNIT/Overview`, then `failed: time (OPEN, 1990 ticks left)`, ledger `leather:time gem:time pick:time ...`
Module: `lua/dfllm/trade.lua` (`finish`, `step_wait`, `screen_ask`, `time_out`, `CFG.BUSY_TICKS`)

## Actual
A unit sheet of the player stood over the map for the whole visit (27,474 ticks at the depot). The kernel (correctly) never closed it, but:
- every retry went through the OPEN phase and waited `PHASE_MS` (6 s of module clock) for the screen to go; 16 attempts in one visit, kern.log `trade: a player screen is open; trying again later` about every 1,700 ticks;
- the visit kept `f.ui`, so the trade clock (FPS cap 100) stood for the whole 234 s of the wait (`trade boost ended ... after 234 s`);
- the player was asked only after `BUSY_ASK` (3) of those attempts, and when the time ran out the visit ended 'time' (the ledger blamed nothing), not the screen.
Whether the retry would fire the moment the screen closed was left to the next `RETRY_WAIT` (1,200 ticks) slot.

## Root cause
`trade.lua` `finish(..., 'ui_busy')` turned the block into a normal retry (`v.retry = tick + wait`, a new flow `nf` with `ui` copied), so `step_wait` re-entered OPEN on a timer, not on the screen. There was no cheap watch of the focus.

## Fix
- `finish` with `ui_busy` stores `v.sb` (the tick the block began, persisted) and the flow is rebuilt without `ui` (no trade clock while waiting).
- `step_wait`: while `v.sb` is set nothing is tried, the focus is read (cheap, every 100 ticks): when `on_map` the screen is gone, `v.sb` / `v.retry` are cleared and the normal path (goods, OPEN) runs in the same step. The kernel still never touches the screen (BUG-287).
- `screen_ask`: DECISION_NEEDED `trade_screen` once per visit after `CFG.BUSY_TICKS` (1,200) ticks of a standing screen (was: 3 attempts); `n` is still the attempts, the text names the ticks. The 'blocked' event stays once per visit.
- `time_out`: a visit the screen blocked (`v.busy > 0`, nothing traded) ends `screen` (CARAVAN failed / TRADE_LEDGER `leather:screen`), not `time`.

## Tests
`tests/lua/test_bug669_670_trade_screen.lua` (1) one attempt, no clock, one question, no click while the screen stands, traded within 400 ticks of closing it; (2) 'screen' in the failed event and the ledger. `tests/lua/test_bug286_287_sheet.lua` (adapted: the question follows ticks, not tries).

## Live check
Leave a unit sheet open when a caravan arrives: kern.log shows ONE `a player screen is open`, the CARAVAN blocked event, DECISION_NEEDED trade_screen after ~1,200 ticks, no trade clock (`status` clock not at the trade cap); close the sheet: `trade: the screen over the trade of <civ> is gone after N ticks: trying again now` and the trade runs within seconds. If the caravan leaves first: ledger reason `screen`.
Open: the cause of the sheet (the human, or a leftover of the kernel's own screens in DF 53.16, BUG-286) is not proven from the logs; the kernel treats any screen it did not open in this attempt as the player's.
