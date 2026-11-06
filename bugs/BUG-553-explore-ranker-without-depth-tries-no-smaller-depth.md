# BUG-553 `bp sites explore` (and `bp.place explore S1`) without p.depth never tries a smaller depth: `depth 12 reaches avoided level`
Status: fixed (offline, live-untested)
Severity: medium (no ore search for years though a shorter shaft fits)
Found: 2026-11-06, Run 16d i4 Trumpetrealms y399-y405 (`runs/run-16d/FR-BUGS.md` "Nach Reload: bp sites explore ohne depth weiter 'depth 12 reaches avoided level', aber mit depth=6 jetzt 3 Sites"; `E:/DF-test4/dfllm-runtime/r16d4-trumpetrealms-site97/` read only)
Module: `dfpilot/bp/sites.py` (`rank`, `_rank_depths`, `EXPLORE_DEPTHS`, `RANK_V`), `dfpilot/cmd.py` (`site_params`)

## Actual
`bp sites explore` -> `explore: every anchor's shaft of depth 12 reaches an avoided level (z..)`; `bp sites explore depth=6` -> 3 sites; `bp.place explore S1` refused. `plan propose` tried smaller depths itself (`fit_explore`, BUG-528) but the ranker did not, so `bp sites`, `bp.place` and every other caller of `rank` without p.depth saw nothing.

## Root cause
`sites.rank` ranked one depth (the template's default 12); BUG-528 added the arm fallback (`_rank_arms`) but no depth fallback; `cmd.depth_hint` only printed the shallower depth as advice.

## Fix
`sites._rank_depths` (rank, explore without p.depth): the template's depth first (arm fallback as before, a site there is returned untouched); when it fails with an explore reason (`avoided level`, `no safe explore site`, `explore: no site at depth`) the depths of `EXPLORE_DEPTHS` (9, 6, 4, 2) are tried in turn (a given p.arm is kept); the first that has a site is returned, every site carries `depth` and a note ("shaft cut to depth N ... BUG-553"). `cmd.site_params` applies the site's `depth` to the document like `arm` (BUG-528), so `bp.place explore S1` places it. p.depth given is never changed. Nothing at any depth: the template's error with `(depth 12, 9, 6, 4, 2 tried)`. `RANK_V` 10 (cached rankings are ranked again).

## Tests
`tests/bp/test_bp_explore.py` `test_bug553_...` (fallback to depth 4 under an avoided z20, the template depth untouched, p.depth given keeps the error, nothing fits lists the depths, p.arm kept), three older assertions made explicit with `depth 12`; `tests/test_bug549_553_f35.py` `test_site_params_carries_the_depth_of_an_explore_site`.

## Live check
`bp sites explore` (no depth) on a fort where depth 12 reaches a cavern level: sites with `depth` and the BUG-553 note; `bp.place explore S1` places a document with `p.depth`.
Open: the fallback ranks up to four more depths (times the arms) when depth 12 fails, so a `--fresh` ranking of a fort with no site at all takes that much longer.
