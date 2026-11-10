# BUG-632 The ring stall says "the ring has not moved" for years: it names the hidden tile, the missing quickfort call, the wall material found
Status: fixed (offline, live-untested)
Severity: high (the same i1 / i2 stalls: DECISION_NEEDED `project_released` repeated every 60 days for 1400 days with the cause `the ring has not moved`)
Found: 2026-11-10, Run 16 round 19 (round19_notes R1, Y3 "wall material unreachable (blocks/boulders in the flooded z117), wood not used as ring material", V2 "no stone at all: the shaft needs boulders, the workshops need Z4, Z4 needs the shaft; the DECISIONs do not name surface=1")
Module: `lua/dfllm/aqshaft.lua` (`stall`, `plug_missing`, `A.stall_text`, `A.ring_step`), `docs/v2/CONTRACTS.md` (PROJECT_BLOCKED)

## Actual
`stall(... 'ring_stuck')` printed only `the ring has not moved`; `aq_stall:no_boulders` said `no free boulders or blocks` without the count and without the logs the ring may use. The runner's `project_released` DECISION_NEEDED (cause = `A.where` + `A.stall_text`) therefore repeated the same words.

## Root cause
`aqshaft.lua stall()` carried no detail; the silent branches of `A.ring_step` (hidden tile, no quickfort call, ramp not open) wrote nothing; `plug_missing` returned only the cause key.

## Fix
- `stall(..., extra)` keeps `L.stall.extra`; the PROJECT_BLOCKED msg reads `shaft z125 waits (the ring has not moved) 3 d [the channel tile 51,50,126 is hidden]: <cmd>`, `A.stall_text` (the row, and the cause of the DECISION_NEEDED) `stall z125: the ring has not moved (the channel tile 51,50,126 is hidden)`. No new field, no new `why` (CONTRACTS prose only).
- `R.wait` (ring record) is set by the silent branches and cleared when a piece changes state; the `ring_stuck` stall also fires when another stall that is itself `ring_stuck` is up (the text follows the cause).
- `plug_missing` returns the detail `N of M walls: B blocks, R free boulders, L logs reachable`; `aq_stall:no_boulders` (ring start, shaft dig, open ring tile, soil seal) prints it. Wall material is blocks + free boulders + logs above the wood floor (`economy.wall_stock`, economy.lua:7603); a fort with logs only passes the check, buildingplan's `logs` switch is turned on by economy `T.jmake` when the wall waits for building material (economy.lua:7916, `bm_route` BM_ON). A fort with no stone and no logs (a bare surface fort) now reads `0 of 6 walls: 0 blocks, 0 free boulders, 0 logs reachable` plus the commands (`trade.want stone,block`, `plan propose`).
- The stall text of `no_boulders` says `boulders, blocks or logs`.

## Tests
`tests/lua/test_bug631_ring_hidden.lua` (counts in msg and row, logs alone start the ring, the hidden-tile text), `tests/lua/test_bug443_444_ring_stall.lua` (adapted text).

## Live check
`aq_stall:ring_stuck` / `aq_stall:no_boulders` PROJECT_BLOCKED msg with the bracket; `inspect`/brief row `stall zN: ... (...)`.
Open: stone that lies in the flooded z117 is not reachable and is not counted (the census counts what citizens reach): the detail shows the real count, so the fort sees "0 blocks" and asks the caravans (`need rock`); a drained room is not automatic. Whether DF accepts a log as wall material of `Cw` through buildingplan was not checked live (the wall waits `ring_wait` = 2 days, then the shaft is plugged as before).
