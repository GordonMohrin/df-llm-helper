# BUG-703 A cleared plant eater in sight refuses the PEACE rescue of citizens cut off from food and drink
Status: fixed (offline, live-untested)
Severity: high
Found: 2026-11-11, Run 16b i2 Whirledrampart y419-y423 (STRANDED 'refused: an outer bridge is not up' 25 times, 'no raised inner or core bridge leads to drink / food')
Module: `lua/dfllm/siege.lua` (`M.calm`), `lua/dfllm/gate.lua` (`window_open`), `lua/dfllm/threat.lua` (`assess`)

## Root cause
BUG-235's rescue in quiet PEACE (outer bridges too, no sealed outside needed) needs `siege.calm`: PEACE, `a.vis == 0`, nobody inside, no lockdown gates. `vis` counts every visible hostile, the cleared mammoths included, so the rescue took the threat-mode rules (an outer bridge must be up, the outside sealed) and was refused: 25-31 citizens stayed on walk group 3353 without food and drink. `gate.window_open` (a PEACE window is never open with a hostile in sight) read the same `vis`.

## Fix
`threat.assess` carries `vpp` (census.h.vpp, BUG-702); `siege.M.calm` and `gate.window_open` use `vis - vpp`. Anything else in sight (an uncleared animal, an invader, a killer) still makes it not calm. With BUG-702 the lowering itself is not refused by the 30-tile guard any more, so a raised bridge that separates citizens from food or drink is lowered by the PEACE rescue (`gate.want 'down' 'rescue'`) and handed back to the mode default when they have eaten or drunk.

## Tests
`tests/lua/test_fix5_gate.lua`: the world of BUG-235 with a wild mammoth beside B1: uncleared, the rescue is refused; cleared (fake reflex `pv_plant`, `far_ids`, `pv_ids`) the rescue runs and O1 and B1 are lowered (fails on the old code). `tests/lua/test_bug702_704_cleared.lua`: `siege.calm` false with two uncleared mammoths, true with both cleared.

## Live check
Cleared mammoths in sight, PEACE, citizens on a cut-off group: STRANDED 'rescue' with `peace = 1`, not 'refused'. Open: only PEACE (BUG-235's rule) is covered; a threat mode with a cleared mammoth keeps its own rescue rules.
