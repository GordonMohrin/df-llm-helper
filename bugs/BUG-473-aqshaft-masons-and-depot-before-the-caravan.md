# BUG-473 Run 16a i1 Basementflew y372-374: the aqshaft level waited 4 days for a mason (player placed Masons by hand); NO_DEPOT only after the caravan stood outside
Status: fixed (offline, live-untested)
Severity: medium
Found: 2026-11-05, round 29 notes (`runs/run-16a..16d/FR-BUGS.md`), main 59d6abb
Module: lua/dfllm/aqshaft.lua:ask_masons, dfpilot/wake.py (why=masonry), dfpilot/plan.py:propose (depot)

## Actual
z127 'soil walls': PROJECT_BLOCKED aq_stall:no_mason after 4 days with a hint only; the player ran `bp.place workshops surface=1 only=Masons`. The trade depot came with the caravan's NO_DEPOT: `no known depot site (no fortcore depot)`.

## Fix
- `aqshaft.lua ask_masons`: the moment a level has soil walls and `mat_for` says no mason's workshop stands (and again at the stall, at most every `mason_every` 14 days) it emits PROJECT_REQUEST `workshops` `why=masonry` `types=[Masons]`; follow places exactly the Masons at prio 1 (`wake`: `masonry` joins mandatory / slabs / busy ...; `_place_workshops` skips a shop that stands or is queued).
- `plan.propose`: the surface depot (BUG-368) is also drafted when the draft's fortcore stage 1 waits for the aquifer shaft (an aqshaft drafted or placed): that core builds its bailey depot seasons late, past the first caravan.

## Tests
`tests/lua/test_bug412_aqshaft_order.lua` (one request, none repeated), `tests/test_bug469_473_f29.py` (depot with an aqshaft, note).

## Live check
events `PROJECT_REQUEST workshops why=masonry` at the first soil level; `depot@S1` in the first `plan propose` of an aquifer embark.
