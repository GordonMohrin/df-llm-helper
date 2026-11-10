# BUG-662 A ring wall nobody builds is reported as a heavy aquifer (flow 0/7), recorded as a heavy level, and the next shaft stops one level lower
Status: fixed (offline, live-untested)
Severity: high (wrong decision: five shafts, 0 passes, `bp sites aqshaft` kept offering the same failure)
Found: 2026-11-10, Run 16c i3 Wallfree y400-y402: `ring of z142: the wall on 100,28,142 stands unbuilt for 2 d` then `heavy aquifer at z142 (flow 0/7): stopped for good, shaft plugged` (events.jsonl:5300), then the same at z143 (5522), z144 (5587), z145 (5753); Run 16a i1 z125 (2 shafts), Run 16b i2 z135
Module: `lua/dfllm/aqshaft.lua` (`ring_step` wall branch, `ring_stop`, `heavy`), `lua/dfllm/runner.lua` (`aqx`, `Q.ring_ok`, `Q.FINAL`), `dfpilot/bp/sites.py` (`breach_points`, `ring_wall_stops`), `dfpilot/cmd.py`

## Actual
`flow 0/7` is no water. The level was a RING level only because a heavy level lay within `heavy_span` (1) of it (z141, AQ_HEAVY at the start of the run). The ring wall (constructed on the open ramp, material boulders/blocks) was designated and not built within `ring_wait` (2 days): the fort had only claystone (soft) and "Needs non-economic hard stone boulders / no rock" held 121 orders. `heavy()` then said heavy aquifer, plugged the shaft, parked the project (`breach:heavy_aquifer`) and `X.hv(z)` recorded z142 as a heavy level. The next shaft's ring level z143 was now within `heavy_span` of a "heavy" level: the same wall, the same stop, one level lower. Four shafts in a row, four plugs.

## Root cause
`aqshaft.lua` wall branch (`ring_late`) and the 3-refusal branch (`ring_refused`) called `heavy(...)` with the flow of the ring tile, whatever it was; `heavy()` records the level (`X.hv`) and blocks `breach:heavy_aquifer`. 2 days is also shorter than a mason's start-up in a small fort.

## Fix
- Water decides "heavy": `flow >= heavy` in the open ring tile (or water on the level above: `ring_leak`, unchanged) is the heavy stop, checked every pass while the wall stands unbuilt.
- No water: after `ring_wait` (2 d) a visible stall (`aq_stall:ring_wall` or `no_boulders`, with the count of wall material or the wall tile), after the new `ring_stop` (30 d) a ring stop: event `AQ_RING_STOP` (class A, `why` ring_late | ring_refused, `days`, `cmd`), block `ring_wall` (final: parked after `park_days`), the shaft plugged as before (CAVERN_PLUG), and NO heavy level recorded (`m.runner hvl` untouched), so the next shaft's ring level is not pushed down.
- The stop is a manifest breach `ring_wall` (not a hazard: `breach_points` / `_breach_layers` / `_dry` ignore it). The first ring wall that stands (`ring_ok`) drops them all. (The first attempt refused every column of `bp sites aqshaft` for good after two of them, with no way out and for columns on other layers too: replaced in BUG-677 by a live wall-material gate in `cmd.py`; `sites.py` no longer reads the stops for ranking.)
- `runner.cavern_open` leaves cav records with `why` `ring_wall` out (like `heavy_aquifer`): the ring-stop plug is no open cavern shaft, so it neither keeps R0 `caverns` nor adds a threat way-in band, also while the plug is refused or failed.
- `cmd.aq_bottoms` counts `AQ_RING_STOP` like `AQ_HEAVY` (the shaft never dug below z).

## Tests
`tests/lua/test_bug662_ring_wall.lua` (4), `tests/lua/test_aqshaft.lua` (ring_wall cav record is no open cavern), `tests/lua/test_bug414_heavy_ring.lua` (ring_late adapted: stall, then ring stop, no hvl), `tests/test_bug661_664_f43_water.py` (breach points, ranking not locked, schema).

## Live check
Wallfree-like fort without hard stone: `PROJECT_BLOCKED aq_stall:no_boulders|ring_wall` after 2 d, `AQ_RING_STOP` after 30 d, `m.runner hvl` unchanged, `bp sites aqshaft` is gated by the live stone stock (BUG-677), not by the count of stops. Open: the real reason in Wallfree (hard stone the builders accept vs. the pre-check `wall_stock` counting any boulder) is not changed: `plug_missing` still counts boulders of any kind. While the wall stands unbuilt the open ring tile is watched every pass (flow and the level above), so the longer wait delays containment only of a leak those two reads do not see. The `ring_refused` branch (3 quickfort refusals) has no offline test (the mock never refuses a wall).
