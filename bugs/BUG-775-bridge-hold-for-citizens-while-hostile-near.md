# BUG-775 a raise waits 500+ ticks for citizens beside the bridge while a hostile is 22 tiles away, then rises with them next to it
Status: fixed (offline, live-untested)
Severity: high
Found: 2026-11-11, Run 16a i1 Basementflew y544 aut d82 (kern 87b10464): GATE_FORCED B1 #29798 / #29805 / #29811 / #29849 'B1 raised with citizen next to it: hostile 22 tiles and closing, held 506-569 ticks (approach_near 30)'; the citizens 31427, 35900, 35914, 35994 stood at the bridge (41,101,129) and were killed there by the dragon and the goblins (DEATH #29845, #29856)
Module: `lua/dfllm/gate.lua` (`holders`, `approach_cfg`, `forced_event`, `M.APPROACH_NOW`), `lua/dfllm/siege.lua` (`citizen_held`), `dfpilot/fairplay.py`, `config/reflex.json`

## Actual
BUG-587 bounds the hold of a raise for citizens merely BESIDE the footprint (a unit on it always holds): a hostile within `approach_near` (30) tiles and CLOSING (4 tiles nearer than 150-900 ticks ago), or within `approach_close` (12), and only after the raise was held `approach_hold` (300) ticks. At y544 the hostile came to 22 tiles, the hold was 506-569 ticks old by the time the 'closing' test held, and the four citizens next to B1 had stood in the hostiles' path the whole time; B1 rose with them outside.

## Root cause
`gate.lua` `holders`: `held >= ah and (d <= ac or (d <= an and closing))`. Waiting for people beside the footprint is worth a few hundred ticks while the hostile is far; from 20 tiles on it is not (a hostile covers a tile in ~8 ticks (BUG-765's `RACE_FOE_TPT`), a citizen in ~24, the lever latency is 100-250 ticks and the bridge needs ~100 ticks to move: no citizen beside the footprint gets across and away in the ~160 ticks the hostile needs for 20 tiles), so the wait can only end with the citizen outside AND the bridge late.

## Fix
`gate.APPROACH_NOW` = 20, config `gate.approach_now` (0..80, 0 = off; `fairplay` validates it, `config/reflex.json`, CONTRACTS): a hostile within `approach_now` tiles of the footprint ends the hold at once, whatever the wait so far and whether it closes (a parked army 20 tiles out counts: the raise is the defence, the citizens beside it are the price). Only a unit ON the footprint (or on a path whose first step is onto it) still holds the raise, so nobody is crushed; the forced raise is the same as BUG-587's (sticky for `APPROACH_STICKY`). `GATE_FORCED` reads '... a hostile N tiles from it (approach_now 20), held T ticks'. `siege.citizen_held` no longer excuses a bridge that is still down with a hostile within `approach_now` (no 'held for our own people' reprieve before a BREACH).
Why 20 and not 30: BUG-492 (a parked army 25 tiles out, a walker 8 steps from B1 crushed when the hold was dropped) is the reason for the 'closing' test between 30 and 12; the numbers above leave 20 as the distance at which a citizen beside the bridge no longer escapes. 25 tiles parked: the hold stays (test).

## Open
The citizen locked out stays outside with the hostile (the alternative is a breach of the whole fort, y544: 52 -> 7); the recall (`reflex`) calls him in earlier, nothing here speeds it up. A hostile 20 tiles away by the straight line may be behind walls; the rule then raises a little early, which costs only a delay for the people beside the bridge.

## Tests
`tests/lua/test_bug774_776_lever_home.lua`: a citizen beside B1 and a hostile 18 tiles out (parked): B1 rises with the pull, GATE_FORCED names `approach_now`, the citizen is where he was (locked out, not crushed); `approach_now` 0 = the old rule holds it; 25 tiles parked: the hold stays until he leaves; a citizen ON the footprint holds it with the hostile 10 tiles out. SIEGE TRAFFIC: the y544 replay in BUG-774's test (citizens at B1, hostile 18 tiles out: B1 and O1 up before T+900, nobody crushed). The BUG-587 suite (`test_bug587_siege_hold.lua`) is unchanged and passes.

## Live check
GATE_FORCED '... (approach_now 20), held N ticks' with N small; B1 up within one lever latency of the hostile coming within 20 tiles.
