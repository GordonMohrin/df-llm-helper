# BUG-589 Building destroyers break the refuge access before the wall plug stands
Status: fixed (offline, live-untested)
Severity: high (two cave dragons toppled B2 (raised) and reached the stair foot 62,127,136; Tiefe+ was breached, 22+ dead)
Found: 2026-11-09, Run 16c i3 Sealcertain y422 summer (SIEGE_DEEP at +13 `2 building destroyers in sight (CAVE_DRAGON x2, 61 tiles from O1): the bridges are no barrier, nor the refuge hatch 62,127,137`; BRIDGE_DESTROYED B2 `last: up`, `tby ... Cave Dragon`; REFUGE_PLUG #10760 only in the BREACH, `8 walls round the stair foot ... the hatch on the stair can be broken`)
Module: `lua/dfllm/seal.lua` (`refuge_closure`, `plug_eval`, `choose`), `lua/dfllm/siege.lua` (`deep_step`), `dfpilot/schema.py` (REFUGE_PLUG)

## Actual
The deep defense knew about the destroyers at the alert (61 tiles out) and said the hatch is no barrier, but the second line (BUG-479, a wall round the stair foot) waited for a destroyer within 30 tiles of the stair head AND for every citizen to be inside, or a BREACH. The citizens streamed in for ~2000 ticks, the dragons came, B2 fell, the plug was queued in the BREACH with a dragon on the stair.

## Root cause
`seal.lua` `plug_eval`: `wait:destroyers far` until `near <= PLUG.near` or `late`, and `wait:citizens not inside` before that; no case "destroyers in sight and nobody outside". `refuge_closure` called a raised bridge 'hard' (BUG-337 review), contradicted by BRIDGE_DESTROYED B2 `last up`. `choose` offered no alternative for a refuge whose only closer a destroyer breaks.

## Fix
- `plug_eval`: building destroyers in sight (census `bd`) and every citizen already inside the refuge burrow: the foot is walled at once (REFUGE_PLUG `early` 1); one citizen outside still waits (`wait:destroyers far`). Bridge closers are plugged too (only a wall closer is skipped).
- `refuge_closure`: a raised bridge is 'soft' like a hatch or a door (state `alert.ref.sf`, SIEGE_DEEP `soft`).
- `choose`: destroyers within `PLUG.near` of the stair head, the way in soft, no plug yet: Kern+ / Innen+ that is separated, reachable, hostile-free and more than `ALT_MARGIN` (10) tiles farther from the destroyers than the stair head is the confinement (`building destroyers near the refuge hatch: <burrow> holds the citizens, away from their path`); with the plug queued the refuge is chosen again. The switch rule is unchanged (citizens already in a burrow stay unless a reason).
- Schema: REFUGE_PLUG `early:i`.

## Tests
`tests/lua/test_bug588_589_refuge_destroyers.lua` (2) far destroyers + everybody inside: queued early, one outside: waits, none in sight: waits; (3) destroyers on the stair column: Innen+ is the pick, the plug queued: the refuge again; (5) bridge closer is soft. `tests/lua/test_seal_refuge.lua` BUG-337 (c) adapted, `tests/test_bug587_589_f38.py`.

## Live check
REFUGE_PLUG `early 1` within one pass of the last citizen entering Tiefe+ while destroyers are in sight; no REFUGE_FAIL `hostile inside` at the stair foot in the siege; if the destroyers stand near the hatch before the walls are up, REFUGE_FAIL names the other burrow.
Open: the walls are built by the citizens inside, so a plug needs ~hundreds of ticks of quiet; a destroyer already on the foot ring blocks it (`wait:hostile inside`); whether a raised drawbridge is really broken (the event said `last up`) is inferred from one loss.
