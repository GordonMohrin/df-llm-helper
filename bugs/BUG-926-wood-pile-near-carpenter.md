# BUG-926 an unnamed embark pile 130 tiles from the logs counts as "a wood pile exists": no dfllm-wood is ever placed
Status: fixed (offline, live-untested)
Severity: medium (571 / 1,170 logs lie far from the Carpenters; the haulers do not bring them; barrels and charcoal starve beside "usable" logs)
Found: Run 17 i3 region1-site97 (26.11.): embark pile #17792 (unnamed, 5x3 = 15 tiles, Z139, `settings.flags=[wood]`, no links) beside the first Carpenter, ~570 free logs ~130 tiles away; `T.woodpile` returned at once, never logged. i2: 1,170 far logs, 6 Carpenters. Diagnosis `leitung/neu10/DIAGNOSE-holzlager.md` (1), (2), (5).
Module: `lua/dfllm/economy.lua` (`T.woodpile`, `M.rect_gap`, `M.logs_in_rect`, `M.wood_piles`, `M.pile_site` opts `indoor` / `dry`), `dfpilot/session.py` (QUIET_DECISIONS), `config/baseline.json`

## Cause (PROVEN, diagnosis (2))
`T.woodpile` returned when `#M.wood_anchors(near_d).piles > 0`: any stockpile of any owner that takes wood, whatever its distance from a Carpenter or its fill. `wood_anchors` applies no name, distance or fill test. The DECISION_NEEDED `wood_pile` was in QUIET_DECISIONS and only emitted after that early return.

## Fix
- A pile counts for a shop only when it lies within `wood.near_d` (40) of THAT built Carpenter's workshop (`M.rect_gap`, the weighting of `wood_rect_dist`, box to box) and has room: free logs lying on its tiles fewer than its tiles (`M.logs_in_rect`; diagnosis (5)). A shop with no such pile gets its own `dfllm-wood` pile with the existing `act.wood_pile` primitive on `M.pile_site` with the new options `indoor` (snapshot.plot_under not false: no open sky) and `dry` (no water, magma or ice on the tile); plain floor only (`c == '.'`: no ramp), the citizens' walk group, off the attack path, nothing dug. Size `wood.pile_w` x `wood.pile_h` (default 5 x 5, 1..5), at most `wood.pile_max` (3) kernel piles, PEACE only (was PEACE / RECOVERY); `wood.pile = false` still switches it off.
- Event `WOOD_PILE` `ph placed` (`pos`, `w`, `h`, `shop`, `near0`, `far0`, `need`, `piles`) and `ph result` `wood.pile_measure` (7) game days later (`near0` -> `near1`, `far0` -> `far1`, `on` = logs on the pile's tiles).
- No site: ONE DECISION_NEEDED `wood_pile` per season (84 game days); `wood_pile` is removed from QUIET_DECISIONS (it is no longer silenced); the search after a failed try is repeated daily as before.

## Not done / unproven
- That DF's haulers carry 130-tile-distant ground logs to a new pile is NOT proven (diagnosis (4), ASSUMED); the follow-up event measures it (`near1` vs `near0`, `far1` vs `far0`). A pile that stays empty after 7 days means the haulers do not come: then the logs are a trade or chop problem, not a pile one.
- The fill test counts every free log on the pile's tiles (1 per tile); the real capacity per tile of a log stockpile was not measured.
- A near but full pile is not enlarged; a further kernel pile is placed beside the shop (up to `pile_max`).

## Verifier round (NEU19)
- `M.covered_boxes()` reads `buildings.other.STOCKPILE`, `ACTIVITY_ZONE` and `ANY_ZONE`; `T.woodpile` passes `q.ok` to `M.pile_site` so no tile of an existing stockpile or zone is chosen (bounding boxes: conservative).
- A site quickfort refused (`state 'refused'`) is stored in `p.wpile.bad` (at most 8 boxes) and excluded on the next attempt; with nothing else free the list is dropped and the search starts again.
- The indoor check fails closed: `snapshot.plot_under` unreadable (call fails) or `false` rejects the tile (`nil` = roofed, not subterranean: accepted).

## Tests
`tests/lua/test_bug926_wood_pile.lua` (9: + no overlap with an existing stockpile / zone, a site quickfort refused is not tried again (the next attempt takes another, `p.wpile.bad`), an unreadable roof fails closed); `tests/lua/test_bug910_915_holz.lua` (two expectations moved: 5x5, wording), `tests/test_bug910_915_holz.py` (the decision is not quiet any more).

## Live-Erwartung
i3: within a game day of the next PEACE look kern.log `wood pile: dfllm-wood 5x5 at x,y,z beside the Carpenter's workshop at 79,55,139 (no stockpile near it takes wood with room; near logs 88 of 82 wanted, 508 far)`, event WOOD_PILE `placed`; 7 game days later `result` with usable near logs 88 -> N. i2: one pile per Carpenter lacking one, up to 3. Without floor beside the shop: one DECISION_NEEDED per season, not hidden in the briefing.
