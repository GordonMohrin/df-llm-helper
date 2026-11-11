# BUG-717 Farm plots needed the dug Z4 floor: no plot for 68 seeds, no brewing, food 0 each winter
Status: fixed (offline, live-untested)
Severity: high
Found: 2026-11-11, Run 16c i3 Doorwings y377-y380 (aqshaft stopped at the heavy aquifer, fortcore never dug: 'farms: room sites need manifest zones.Z4', 68 seeds fit no plot, no brewing) and Wallfree y387-y432 (`bp sites farms` 'no valid site' for years)
Module: `dfpilot/cmd.py` (`place`, `farm_alt`), `dfpilot/bp/sites.py` (`rank`)

## Root cause
`sites.rank` raised 'room sites need the fort manifest with zones.Z4' for a farms room without a fortcore (sites.py line 268), and a farms room with Z4 but no soil level or no free place raised 'only 0 free site(s)'. `cmd.place` fell back to a surface variant (BUG-639 `surface_alt`) only for the bedrooms / dining / tavern / office rooms and only with no core coming; farms were not among them although the BUG-407 surface farm (`_surface_farms`) already takes soil or mud anywhere on the citizens' walk group, underground floor included.

## Fix
- `cmd.farm_alt` / `cmd.place(any_soil=True)` (cmd.py line 2420; `cmd.send` sets it for a hand command that is not follow, in PEACE only: builders outside the fort are a PEACE matter, BUG-302; follow keeps its own PEACE ladder room -> fewer plots -> surface, BUG-340; plan checks are unchanged): a ranked `bp.place farms` that found no room site is placed again with `p.surface=1` (soil anywhere reachable, outside the fort's own tiles), also with a fortcore coming (food does not wait for the dig), with the fewer / smaller plot ladder (BUG-316, BUG-696); PLACE_NOTES says 'BUG-717 ... plots on soil elsewhere'. When both fail the BpError carries both reasons, the second one with `farm_ground_why` (soil and mud counted, blocks per cut condition).
- `sites.rank` for farms without Z4 now says 'a farm needs no Z4: `bp sites farms surface=1 --fresh` lists plots on any reachable soil ...'.

## Tests
`tests/test_bug715_718_f46b_food.py`: `farm_alt`, no Z4 -> placed with p.surface (any_soil), fortcore coming -> still placed, follow / ALERT / no flag keep the refusal, Z4 without soil level + speckled ground -> smaller plots (note names BUG-717 and BUG-696), no soil at all -> refusal names both, the ranking message.

## Live check
`dfllm cmd bp.place` farms (by hand, PEACE) in a fort with no `zones.Z4` returns a document with `params.surface 1` and the note. Open: the fallback is PEACE only (outside it the old refusal stands) and the farm may stand outside the roofed fort; water near a mud plot is checked only by the BUG-407 rule; nothing here digs, so no dig at water.
