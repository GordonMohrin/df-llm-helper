# BUG-488 NO TRADE PILE without a finished fortcore: caravans report nothing_listed for years, stone and iron are never bought
Status: fixed (offline, live-untested)
Severity: high (key lever for stone and metal in a soil fort: every caravan of four years left empty-handed)
Found: 2026-11-05, Run 16a i1 Basementflew y387-y390 (FR-BUGS "Karawane nothing_listed 4 Jahre in Folge"); `inspect what=trade`: goods [], goods_items 0, ledger "unmet stone/gem/mechanism/block/bar:iron: nothing_listed", kern.log "trade: 0 sale items sent to the depot" at every caravan
Module: `dfpilot/bp/rooms.py` (new template `tradepost`), `dfpilot/bp/sites.py`, `dfpilot/plan.py` (`trade_pile_planned`, `propose`), `lua/dfllm/runner.lua` (`kind_of`)

## Actual
The stockpile `dfllm-trade` (autotrade, the pile `baseline.trade_piles` registers with `logistics add trade`) existed only in two templates: `bp/fortcore.py:165` (stage 1, stage `s1.place`, i.e. after the core is dug and built) and `bp/surfacecore.py:60`. A fort whose core never finished (Basementflew: stage 1 parked on a heavy aquifer) or never existed (a depot placed alone, BUG-368) had a depot and no pile: `baseline` says "no trade pile yet", logistics sends nothing to the depot, `trade.want` buys nothing (nothing of ours to pay with), the broker's list is empty -> `nothing_listed`. The `bring` call (`act.lua` TR.bring) marks only loose items (`on_ground`) and sent 0 every time (kern.log).
The same pattern in the other forts' kern.log: r16b2-glendagger (3 x nothing_listed, "0 sale items" at the caravans), r16c3-castletongs (1), r16d3-orbblock (1), region2-site90 of i4 (20, 34 caravans at 0 items). Forts with a finished core and a pile sell goblets and crafts at every caravan (r15d, r16d2, r16d4).

## Root cause
No template could build the pile apart from the core: `rooms.SURFACE` had the `depot` (BUG-368) only, `plan.propose` drafted the depot (BUG-368 block) and nothing for the pile; `fort_facts` had no fact for it.

## Fix
- New surface template `tradepost` (`bp/rooms.py:tradepost`): one 4x2 `g` stockpile named `dfllm-trade`, `autotrade=true`, stage `place`, nothing dug, no door, no burrow. `sites.rank` offers 4x2 open surface floor on the citizens' walk group, nearest to the manifest `depot` (like the surface rooms); `kind_of` (lua) and `build_kind` (python) call it `depot` (no seal pauses it, the rebuild policy runs it).
- `plan.trade_pile_planned` (new fort fact `trade_pile`): True for a `tradepost`, a surface core, or a fortcore stage 1 placed and not stopped on a breach (`core`).
- `plan.propose`: a depot standing, planned or drafted now and `trade_pile` False -> `tradepost@S1` after the depot, unless the draft itself carries a fortcore stage 1 (or the surface core) that builds it; note "BUG-488". Baseline picks the pile up by name at its next monthly recheck (`logistics add trade`), crafts and goods are hauled there, and `trade.want` buys then have goods to pay with.
Not changed: `act.trade bring` (loose items only), gate.lua, the bridges.

## Tests
`tests/test_bug488_490_f30.py` (template shape and schema, sites beside the manifest depot, drafted with a depot and without a pile, not drafted with a pile or without the fact, `trade_pile_planned`), `tests/bp/test_bp_emit.py` (template count 32), golden `tests/bp/golden/tradepost.*`.

## Live check
`dfllm plan propose` in a fort with a depot and no `dfllm-trade` pile drafts `tradepost@S1`; after `plan apply` the stockpile exists, the next monthly baseline logs the trade-pile task ok, and the next caravan's ledger shows `sold` items. Open: a fort with no goods in stock still sells nothing (the pile only routes what exists); `bring` does not take items inside bins.
