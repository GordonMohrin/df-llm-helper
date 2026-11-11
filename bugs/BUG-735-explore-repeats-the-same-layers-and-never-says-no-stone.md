# BUG-735 Explore probes of a soil fort end at the same level every time and nothing says "no stone within N levels"
Status: fixed (offline, live-untested)
Severity: medium
Found: 2026-11-11, Run 16d i4 Pagedsculpture y384-y388 (PROJECT_DONE y385s0b0 .. y388s0b0 explore depth 20-24, rocks CLAYSTONE z137-z134, CHERT z133-z129, MUDSTONE z128-z122, ROCK_SALT z121-z115, SILTSTONE z114-z113: the same layers each time; the player: plan propose drafts only explore@S1)
Module: `dfpilot/cmd.py` (`explore_summary`, `explore_low`, `is_soil_rock`, `_with_explored`), `dfpilot/bp/sites.py` (`_explore_deeper`, `_rank_depths`), `dfpilot/cli.py`

## Root cause
`sites._rank_depths` tried the template's own depth (12) first and only went SHALLOWER; probes from the same core floors therefore ended at the same level and saw the same layers, and the ranking (BUG-584 "far from earlier probes", BUG-683 "repeat") only moved the start sideways. The PROJECT_DONE `rocks` (BUG-625) were read only to explain a failed ranking, so a fort that had looked 30 levels down and found only clay was never told "no stone within N levels".

## Fix
`cmd.explore_low`: the lowest level any finished probe saw while none saw a flux stone; `_with_explored` puts it into the manifest (`explored_low`). `sites._explore_deeper` / `_rank_depths`: with no p.depth given and `explored_low` below the template's depth, the probe is ranked first at `top_z - (explored_low - EXPLORE_DEEPER)` levels (6 under the earlier probes, at most the template's maximum 40; the avoid / cavern / heavy-aquifer rules of the ranking apply as for every depth); no site that deep: the old ladder. `cmd.explore_summary`: the span looked at, the first stone layer from the top, or "NO STONE within N levels: every layer ... is soil" (clay, silt, sand, loam, peat in `is_soil_rock`; CLAYSTONE / SILTSTONE are stone). `bp sites explore` prints it and the explore refusal (`explore_rock_note`) carries it.

## Tests
`tests/bp/test_bug732_735_f47_explore.py`: soil vs stone names, the summary with a first stone layer and with soil only ("NO STONE within 18 levels"), `explored_low` (unset when flux was seen), the deepened ranking (depth 14, a given depth stays, no deepening within 3 levels, never over 40), the manifest key.

## Live check
`dfllm bp sites explore --fresh` after the probes of a soil fort lists a deeper probe ("shaft deepened to N levels") and the line "probes (BUG-735): ...". Open: the deepened shaft is only ranked; the dig rules (aqshaft protection, 3 tiles from open water, caverns, heavy aquifer breach levels) are the template's and the ranking's own and nothing here digs; the plan's own explore draft (`plan propose`) still uses its own depth. Python only, no kernel reload.
