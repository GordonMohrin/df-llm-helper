# BUG-651 The refuge plug is built at the alarm and never finished before the destroyers arrive
Status: fixed (offline, live-untested)
Severity: high
Found: 2026-11-10, Run 16d i4 Trumpetrealms y438: 2 cave dragons broke the refuge hatch at the stair foot 84,111,133 and entered Tiefe+, Pop 77 -> 12
Module: `lua/dfllm/seal.lua` (`M.PP.*`, `plug_eval`, `M.plug_state`), `lua/dfllm/util/contract.lua` (`act.item_flag` owner `seal`)

## Actual
The refuge plug (BUG-479, round 39: a constructed wall on every open tile round the stair foot, because a hatch is broken by building destroyers) was ordered only after the dragons were on the stair.

## Root cause
Measured in the same fort (events.jsonl): the 8-wall plug took 14,230 ticks (ordered 175720029, PROJECT_DONE 175734259, lines 18095 / 18232) and 14,266 ticks (176509858 -> 176524124, lines 19026 / 19117). The dragons walked 82 tiles in ~2,300 ticks (SIEGE_DEEP 176862488, line 19350; a citizen struck down on the stair column ~176864730). A plug that starts at the alarm needs six times the time the destroyers need: `seal.lua` `plug_eval` (the whole design, BUG-479 / 589 / 595) orders eight walls at the alarm, so it can never be finished in time, whatever it waits for.

## Fix
PRE-PLUG. In PEACE (`M.PP.step`, every `PLUG.pre_every` 1,200 ticks, no episode, no hostile in sight, a closer on the stair head) `M.PP.plan` picks a gap tile on the walking route (an orthogonal neighbour of the foot with another standable tile behind it, nearest to the refuge anchor) and `M.PP.queue` queues the other open tiles as one runner repair (`Cw`, `noreach`): the stair stays usable. `M.PP.reserve` forbids the nearest reachable free block/boulder (`act.item_flag`, `seal` is now an owner) for the last wall; it is released when that wall is ordered. State `st.pp` {t, id, gap, tiles, done, mat}, persisted; `plug_state` lists the ring (the lockout scan leaves it alone) and the gap. With the ring standing, `plug_eval` sees exactly one open foot tile (the gap): the siege plug is ONE wall, ordered at the first look at building destroyers (SIEGE_DEEP / bd in sight / announced / BREACH). A walker outside holds it only while the destroyers' ETA (`near x PLUG.eta_tile`, 28 ticks a tile = 2,300 / 82) is larger than the wall's build time + `PLUG.margin` (600). One wall = `PLUG.wall_ticks` 1,800 by default (14,230 / 8 = 1,780 per wall, an upper bound for the marginal wall); the fort learns its own (`st.wt`, `M.PP.learn`): per wall from the ring's project time, `one` from the last wall's, slow average, 300..30,000. A fort without a pre-plug (foot with a ramp, no gap with a way on, pre off) keeps the round-39 behaviour unchanged. REFUGE_PLUG carries `pre`, `eta`, `wt`. The new event PLUG_NOTE (class C) names the pre-plug's states (`pre_queued`, `pre_done`, `pre_lost`, `pre_cannot`, `pre_wait`).

## Tests
`tests/lua/test_bug651_653_preplug.lua` (1), (2), (3); the round-39 tests (`test_bug479_refuge_plug`, `test_bug588_589_refuge_destroyers`, `test_bug595_597_refuge_siege`) run with `M.PLUG.pre = false` on purpose (they are the fallback).

## Live check
Basementflew / Trumpetrealms in PEACE: PLUG_NOTE `pre_queued` with `gap`, the seven walls built (`pre_done` `ticks`), a block forbidden near the gap, `alert.ref.pp` 2; then a destroyer siege: REFUGE_PLUG `pre` 1 `n` 1 within a few hundred ticks of the first sighting, PROJECT_DONE of the last wall well before the destroyers reach the stair head (the fort's own `wt` after the first siege). Open: the item is the NEAREST free block, not moved next to the gap (no kernel hauling); buildingplan may still pick the forbidden block if somebody unforbids it; the gap choice is geometric (a long detour beyond the chosen gap is possible).
