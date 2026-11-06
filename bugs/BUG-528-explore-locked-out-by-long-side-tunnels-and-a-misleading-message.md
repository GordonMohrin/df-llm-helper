# BUG-528 A soil fort is locked out of `explore` for years: the side tunnels meet the core, the message blames a cavern breach
Status: fixed (offline, live-untested)
Severity: high (no ore, no hard stone, soldiers 38 % worn, no drill, P5 waited for years)
Found: 2026-11-06, Run 16d i4 Trumpetrealms y375-y399 (`runs/run-16d/FR-BUGS.md` "FR Explore/Stein: Fort in Erde komplett von Explore ausgesperrt (y399)"; manifest `caverns` [[92,116,124],[79,99,126],[78,127,127]], core Z4 at z136/z139, refuge z133; `r16d4-trumpetrealms-site97/manifest.json` and the sites snapshot read only)
Module: `dfpilot/bp/sites.py` (`rank`, `_rank_arms`, `_explore`, `_explore_none`), `dfpilot/cmd.py` (`site_params`, `depth_hint`), `dfpilot/plan.py` (`fit_explore`, `explore_room`)

## Actual
After the three explore digs stopped at the cavern (z124/z126/z127) and were cancelled, `bp sites explore depth=4|8` said "every anchor lies within 6 tiles of a dig that already stopped (cavern 78,127,127 y375s1b0)", depth 12 "reaches an avoided level z124,126,127". `plan propose` drafted no explore for 25 years ("Plan leer"). The player concluded the breach record blocks every site.

## Root cause
Rebuilt offline on the live snapshot and manifest: the breach is not the cause. The anchors on the core levels z136 and z139 (1,108 usable ones) all fail `_check`/`explore_rects` (`sites.py` `_explore`, the `_check` call): the template's default `arm` 6 (W, E, S side tunnels every 3 levels, `mine.PARAMS`) runs into the core's own open rooms at z133..z139 ("bad" tiles on every anchor, level 0 / -3 / -4). Only a handful of anchors (the ones within 6 tiles of the breach) failed the redo rule, and `_explore` raised its message from that one counter (`redo`) because no other counter existed, so the message was false ("every anchor"). With `arm=0` the same snapshot gives 14 anchors for depth 3..8 (12 free at depth 8, shaft to z128, one level above the cavern at z127), `arm=3` gives 5, `arm=1` 12.

## Fix
- `sites.rank` for `explore` without `p.arm` goes through `_rank_arms`: the template's own arm first, then the longest of `EXPLORE_ARMS` (4, 3, 2, 1, 0) that has a site; every such site carries `arm` and says so (`side tunnels cut to N tiles`). `p.arm` given is never changed. When every arm is empty the error is that of the bare shaft, with `(arm 6, 4, 3, 2, 1, 0 tried)`.
- `cmd.site_params` applies `site["arm"]` to the document (place, free_sites, depth_hint, plan `explore_room`); `plan.fit_explore` writes `p.arm` into the drafted build next to `p.depth`, and goes on to the next depth also for "no site" / "no safe explore site" errors (before: only for "avoided level", any other error aborted the fit and left the explore in).
- `_explore` counts what removed the anchors (refuge level, avoided level, near a stopped dig, the core's rooms in the way) and `_explore_none` says it ("explore: no site at depth 8 arm 6; some anchors lie within 6 tiles of a dig that already stopped (...); no safe explore site there; no free rock for it beside the core: p.arm=0..3 ... [N anchor tile(s): ...]"). The old wordings that callers match stay ("avoided level (z..", "no safe explore site"). An empty result without any hit used to return `[]` ("0 ranked"); it raises with the counts now.
- Never near water or the cavern: the avoid levels, the redo radius (6 tiles around a recorded breach / failed explore anchor), the revealed-water and mark checks and the `EXPLORE_RING` of 3 tiles are unchanged.
- The stone-0 / soil path (`soil_dig`, `quarry_fallback`) uses `fit_explore`, so it gets the same sites; when no depth or arm has one the plan note names `bp sites explore --fresh` and `trade.want stone, block`.

## Tests
`tests/test_bug528_531_f33.py` (arm fallback order and the arm on the site, explicit arm untouched, all arms empty, the counted message and its old wordings, `site_params`, `fit_explore` writes `p.arm` and tries the next depth). Reproduced on the live snapshot: before depth 4/6 `[]`, depth 8 "every anchor lies within 6 tiles", after depth 4: 2 sites (shaft to z132), depth 6: 2 (z130), depth 8: 1 (z128, arm 3), depth 12: "avoided level (z124,126,127 ...) (arm 6, 4, 3, 2, 1, 0 tried)".

## Live check
`dfllm bp sites explore depth=8 --fresh` on a fort whose core fills its Z4 levels: a site with `side tunnels cut to N tiles`; `dfllm plan propose` drafts `explore@S1 p.depth,p.arm`; `bp.place explore` emits a document with that arm.
Open: a bare shaft (arm 0) finds less ore than one with tunnels; the arm 6 template remains the first choice. A cancelled project's breach record stays in the manifest (it is a fact about the rock); only the 6-tile radius around it is closed to a new anchor.
