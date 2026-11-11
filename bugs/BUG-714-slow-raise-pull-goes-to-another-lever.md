# BUG-714 B1 'not up at T+900' at an invasion's start: a deliberate hold for citizens, no gate change
Status: analysed, no code change (offline, live-untested); the first fix (a slow-pull lever switch) was withdrawn
Severity: high
Found: 2026-11-10/11, Run 16d i4 Trumpetrealms (old site r16d4-trumpetrealms-site97) invasion 37 and 38: 'breach: B1 not up at T+900' / GATE_FAIL B1 'not up at T+900'
Module: `lua/dfllm/gate.lua` (unchanged), `tests/lua/test_bug712_714_levers.lua`

## Root cause (real log, invasion 37)
kern.log / events.jsonl of r16d4: the siege started at tick 185895046 and B1 had been held up since the arrival lockdown. Its pull on lever 17780 was queued at about +28 and cancelled at 185895449 ('citizen 32269 3 tiles from it and walking toward it'). The later pull was 'taken 40 ticks after queueing', B1 moved at 185895897 and stood up at 185895997. BREACH fired at 185895946 (T+900). So the delay was the safety hold for citizens on or near the footprint (a pull is cancelled and re-queued while a citizen walks toward the bridge; the arrival lockdown, `INNER_MAX` 900 ticks, uses the whole window at an invasion's start), not a pull that nobody did. The 17780 pull was cancelled at +375, before a limit of about +436 for a pull queued at +28, so a slow-pull rule would not have changed this outcome. Invasion 38 (ticks 186184618..186186995) had a similar hold plus a 252-tick pull whose reason is unknown (no gate trace of `no_worker` / `outside` in it).

## Change
None in the code. A first version (a SIEGE / BREACH raise not done after half of the time left switches to another linked lever, `SLOW_PULL` / `SLOW_MIN`) was withdrawn: it was not supported by the real log and it broke three existing siege suites (test_bug621_622_siege_start 'B1 rose', test_gate_footprint X2 'up', test_siege: a slow O1 pull goes to the backup lever at 900-930, not at 450), i.e. a bridge that stayed down or came up late in a siege.

## Tests
`tests/lua/test_bug712_714_levers.lua`: siege traffic test of the unchanged pipeline (five soldiers and four citizens cross O1 / B1 / B2 while real sense / threat / siege / gate run): O1 and B1 raised once before T+900, soldiers through, nobody crushed, no GATE_FAIL / BREACH. The whole tests/lua directory passes (346 suites).

## Open
The 900-tick hold for citizens (`INNER_MAX`) at an invasion's start can use the whole BREACH window; to shorten it the hold has to be changed together with the recall and the three suites named above. The 252-tick pull of invasion 38 is not explained.
