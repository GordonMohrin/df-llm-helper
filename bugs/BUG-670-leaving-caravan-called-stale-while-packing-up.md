# BUG-670 A caravan that is still packing up is called stale after 7,200 ticks
Status: fixed (offline, live-untested)
Severity: medium
Found: 2026-11-10, Run 16a i1 Basementflew (events.jsonl:18151, 18258, 18297, six caravans): `caravan Catten still listed Leaving after 6 days (time left 0): 2 merchants on the map (units 31619,31620 at 64,100,129 65,100,129) ...` + DECISION_NEEDED `caravan_stale` ("A lone stray merchant: kill it"); each of them `left` on its own 8,300-18,000 ticks later. Run 16c i3 Wallfree: the brief showed `CARAVAN on map` for years (checked below).
Module: `lua/dfllm/trade.lua` (`CFG.LEAVE_STALE`, `track_visits`, `stale_visit`), `dfpilot/brief.py`

## Actual
i1: the Round 41 stale rule (BUG-642) fired for every caravan: `LEAVE_STALE` 7,200 ticks after the first look at `Leaving`. A caravan with ~660 goods to pack up needs about 25,000 ticks to leave (stale event + 7,200 = Leaving start; the `left` event came 25,100 ticks after Leaving began at most, over six visits). Each visit therefore made a false 'cannot leave' class A question and ran `fix/stuck-merchants` for nothing.
i3 Wallfree, the claim "Round 41 ends Leaving caravans" checked on the log: the note `CARAVAN on map ... seit Jahren` was written at y393; the Round 41 kernel was loaded in y399 (events.jsonl: `stale` n 5246 at tick 161089769, 6 days after the first look); from then `state.trade.caravan` is 0 (state.a.json `trade:{caravan:0,done:1,ratio:165}`), the CARAVAN `left` came at tick 162099269 when DF dropped the entry, and the brief no longer says 'CARAVAN on map'. No defect is left on that path; what was missing is that the brief said nothing at all about a stale caravan.

## Root cause
`CFG.LEAVE_STALE = 7200` was chosen from the Wallfree case (stale for years) without a measurement of a normal leave.

## Fix
- `LEAVE_STALE` 43,200 ticks (36 days; the longest real leave seen is 25,100, Wallfree's was years). Constant only; `stale_visit`, `fix/stuck-merchants` and DECISION caravan_stale are unchanged. A Leaving caravan inside the window is a live caravan (O1 window in quiet PEACE, gate / supervisor flag) exactly as before BUG-642.
- `brief.py` `def_parts`: with `trade.stale` and no live caravan the defense line says `caravan stale (N listed Leaving over 36 d, not counted): dfllm cmd inspect what=trade`.

## Tests
`tests/lua/test_bug669_670_trade_screen.lua` (3) no stale and no question at 26,000 ticks of Leaving, the entry goes away normally; (4) siege traffic: a Leaving caravan inside the longer window gets its O1 window in PEACE and no bridge is lowered for it once a SIEGE runs. `tests/lua/test_bug642_644_trade.lua` (loop length relative to the constant). `tests/test_bug669_671_f43_trade.py` (brief line).

## Live check
A caravan that has just begun to leave: no `stale` event for 36 days, `state.trade.caravan` 1 meanwhile. A fort with a real stale entry gets the event, the question and `caravan stale (...)` in the brief after 36 days.
Open: 36 days is derived from six leaves of one fort; a fort with a much bigger caravan load could still be called stale a few days early (the only cost is the question and one `fix/stuck-merchants`).
