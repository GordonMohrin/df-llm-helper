# BUG-732 `bp sites explore` finds no site for years: every ranked anchor is "held" by a finished probe
Status: fixed (offline, live-untested)
Severity: high
Found: 2026-11-11, Run 16a i1 Basementflew y520-y521 (`bp sites explore` and `bp.place tpl=explore`: "5 ranked, 5 projects hold them (explore finished)"; no ore, no metal, no hard stone reachable for 20 years)
Module: `dfpilot/cmd.py` (`FREE_RANK_TPLS`), `dfpilot/bp/sites.py` (`rank`, `_rank_depths`)

## Root cause
Reproduced offline on a copy of the i1 save (bp folder, manifest, newest snapshot, events): the explore ranking (`cmd.rank_sites` -> `sites.rank`) ranked only 5 sites at the template's depth 12, and the 5 were the anchors of five finished probes (their shaft column is still held, BUG-549), so `cmd.free_sites` dropped all of them as taken. `FREE_RANK_TPLS` (`dfpilot/cmd.py:481`) listed only `aqshaft` and `fortcore`: for those the placed projects are asked INSIDE the ranking, so a depth or arm that has no free site falls through to a smaller one. For `explore` the ranking never asked, so `_rank_depths` / `_rank_arms` (BUG-553 / BUG-528) stopped at the first depth that had ANY site, taken or not, and the free scan afterwards had nothing left. A second flaw hid behind it: the free test emitted the document with the template's default depth and arm, not the depth and arm the ranking was trying, so it would have judged the wrong shaft.

## Fix
`dfpilot/cmd.py:481`: `FREE_RANK_TPLS` gets `explore`. `dfpilot/bp/sites.py` `rank`: the candidate handed to `free` carries `depth` and `arm` of the shaft being ranked (`dict(c, depth=p["depth"], arm=p["arm"])` for the mine templates), which `cmd.site_params` reads. `EXPLORE_NO_SITE` also names the "lie on or beside placed projects" refusal, so `_rank_depths` goes on to the shallower depths when every site of one depth is taken. On the i1 copy: 0 free sites before, 1 free site after (a depth-2 probe 3 tiles from an old one; the fort has few anchors and the finished probes' columns stay held).

## Tests
`tests/bp/test_bug732_735_f47_explore.py`: the free test sees depth and arm (12/6 first); all sites of the default depth taken -> the 9-deep shaft is ranked; every depth taken -> the error names the placed projects and the depths tried; `explore` is a free-ranked template.

## Live check
`dfllm bp sites explore --fresh` in a fort whose explore sites are all "taken" by finished probes lists a shorter probe. Open: a fort with five anchors in all has few probes left (each finished probe keeps its column); that is geometry, not accounting. Python only, no kernel reload.
