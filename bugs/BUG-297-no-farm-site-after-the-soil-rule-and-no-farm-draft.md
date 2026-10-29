# BUG-297 no farm site after the soil rule, no farm in the plan draft
Status: fixed (offline, live-untested)
Severity: high
Found: 2026-10-29, Run 15c (Inkintense, FR-BUGS Runde 2)
Module: `dfpilot/bp/rooms.py` (farms p.surface), `dfpilot/bp/sites.py` (_surface_farms), `lua/dfllm/snapshot.lua` (CFG.soil_max), `dfpilot/schema.py` (snapshot marks.soil), `dfpilot/plan.py` (farm_facts, food_draft, propose)

## Actual
Run 15c Inkintense y376: `bp sites farms --fresh` 0 ranked, AUTO_FAIL `farms: site S1: only 0 free`, PROJECT_REQUEST #1405 `farms x4: 35 of 150 farm tiles for 50 citizens`, one plot, 414 seeds, food 1-9 d; plan propose: `BUG-243: no water or food build left to draft`. Root causes: (1) sites.py _rooms (BUG-257) needs soil marks under half the plot tiles, but snapshot marks soil only on revealed floors, so an undug room site never qualifies and no other site kind existed; (2) snapshot.lua add_mark capped soil at marks_max 500, all spent on the fort's own soil floors on z130-z132, so the ~5,900 revealed surface floors on z133 carried none; (3) plan.py emergency_drafts drafted farms only when `("farms", None)` was never applied, and below 30 food days only.

## Fix
farms `p.surface = 1`: the plots on soil floor that stands already (no dig, no door, no burrow paint). sites: farms p.surface ranks blocks whose every plot tile is a revealed soil-marked floor inside a Z4 box (the walled fort, best) or within SURFACE_NEAR 12 tiles of the fort entrance (manifest `edge`) on its level, never on the attack path, the military's tiles, a bridge, a manifest room, workshop, depot, pit, station, stair or within 2 tiles of the entrance. snapshot: soil marks have their own cap (CFG.soil_max 8000; schema snapshot marks.soil hi 8000). plan: fort fact `farms` ({open, site}: a farms project neither done nor parked; `room`, `surface`, `none`) below FOOD_DRAFT_D 60 food days; food_draft drafts farms@S1 (p.surface=1 when only a surface site is free) when no farms project is under way, also after an earlier one, first among the food builds; the notes say why (or that no site exists). Safety: food_draft drafts a surface farm only while state mode is PEACE (review; the note says so otherwise), plans are applied by follow in PEACE; mud by irrigation is out of scope.

## Tests
`tests/test_fix10_famine.py` (template, sites, soil marks schema, food_draft, propose). Fail on 05dc764.

## Live check
`dfllm cmd snapshot` then `python -m dfpilot bp sites farms --fresh` and `bp sites farms --p surface=1` (or `dfllm plan propose` below 60 food days: `BUG-297: food N d (< 60): farms@S1 p.surface=1 ... drafted`); after apply the plots stand on the surface by the entrance and Planters get seeds. Uncertain: which crops grow there (surface crops need surface seeds; the 414 seeds may be underground crops).
