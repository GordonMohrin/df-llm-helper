# BUG-288 the water sources scan never finishes while the game runs
Status: fixed (offline, live-untested)
Severity: high (Run 15 Inkintense: no hospital water for 4 years; `inspect water_sources` said 'scan queued for the next water run'
twice a season apart, locs total 0)
Found: 2026-10-29, Run 15 round 2 (Inkintense FR-BUGS, Drillchamber 'age 44070')
Module: `lua/dfllm/water.lua` (M.step, new_scan, scan_read, scan_step, finish, M.inspect, M.state)

## Actual
`M.step` (05dc764 water.lua:2190/2205) gave the scan a slice only in a step without a run in hand, and began a new run whenever
1200 ticks had passed since the last one. The water module is paced (2 ms/s, kern.log 'water waited 30 s for a slice'), so its
slices came 30 s apart; at game speed every slice found 1200 ticks gone, started a run and the scan never moved (it finished only
while the game stood). The scan read 1500 tiles a slice (18 slices for the 61x61x7 box, 05dc764 water.lua:760), and a fort without a
hospital zone scanned only on an `inspect` (water.lua:2033: the gate needs a hospital or a pending one).

## Fix
Every step with a scan in hand gives it one slice first. A scan reads at most `ws_read_max` (90,000) tiles in at most `ws_slices`
(18) read slices (>= ws_tiles a slice) and its bodies in at most `ws_body_slices` (4) slices. A fort without accepted water scans
weekly by itself. `inspect water_sources` says when the last scan finished (m.water `ws_last`, kept over reloads: tick, slices,
tiles read) and how far the running one is (stage, slice, at most); state `water.wst`. Nobody to scan around is said (err), not
'queued' for good.

## Tests
`tests/lua/test_bug288_291_water_scan.lua` (slices 1500 ticks apart; a fort without a hospital). Fail on 05dc764.

## Live check
kern.log `water sources: ... (N slices, M tiles read, K boxes)` within minutes of a water run; `dfllm cmd inspect
'{"what":"water_sources"}'` shows `scan last finished at tick T` and `slices` <= 24; status' state water.wst moves weekly.
