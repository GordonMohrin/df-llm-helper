# BUG-704 REFUGE_FAIL and WATER_PREDATOR repeat for plant eaters that never attacked
Status: fixed (offline, live-untested)
Severity: medium
Found: 2026-11-11, Run 16b i2 Whirledrampart y419-y423 (REFUGE_FAIL 543, WATER_PREDATOR 110 / 123 / 103 for 29104 / 29105 / 29106, class A, the follow wake budget of 6 per hour spent on them so real DECISIONs were swallowed)
Module: `lua/dfllm/seal.lua` (`hostile_in`), `lua/dfllm/sense.lua` (`water_beast`, `M.WATER`)

## Root cause
(a) `seal.hostile_in` counted every census list entry on a burrow tile, so a cleared mammoth inside Kern+ or the refuge made 'Tiefe+: hostile inside at 128,119,136' and REFUGE_FAIL (class A) again and again. (b) `sense.water_beast` announces a big wild unit in water every `WATER.rearm` (7,200) ticks and holds the fishers home; a mammoth at the brook stands outside Kern+ and far from every citizen, so it never reaches the hostile list and reflex never clears it (BUG-672 only sees listed units): it was announced for ever. PREDATOR itself already skips cleared ids (`reflex.inside_scan`).

## Fix
`hostile_in` skips `pp = 1` entries (BUG-702) and sense no longer counts a cleared plant eater into `rin`. `water_beast` follows a unit that is no LARGE_PREDATOR, no CARNIVORE and no killer (`st.wh[id]`: first and last tick seen); once it stood at the water `WATER.herb` (3,600 ticks, 3 game days) without a kill, or reflex cleared it, it is wildlife: not in `census.w`, no WATER_PREDATOR, no fisher hold. A gap of `WATER.herb_gap` (2,400) ticks restarts the time; a killer mark brings it back at once. A carnivore keeps the old rearm. No event means no clock clamp and no wake for it.

## Tests
`tests/lua/test_bug702_704_cleared.lua`: a mammoth at the water is announced once over 4 x 7,200 ticks (old: 5), `census.w` empties and the hold ends, a killer mark brings it back, a carnivore of the same size is announced every window; the cleared ones inside Kern+ are not counted into `rin`.

## Live check
No more WATER_PREDATOR / REFUGE_FAIL repeats for the herd in the Whirledrampart fort. Open: REFUGE_FAIL for a cleared plant eater in the refuge relies on the clearing (3 quiet days or `lockdown.release`); 3 days at the water is a judgement; raws that fail to read count as plant eater (as BUG-532 does).
