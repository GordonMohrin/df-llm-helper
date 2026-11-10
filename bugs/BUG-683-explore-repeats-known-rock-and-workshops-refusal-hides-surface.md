# BUG-683 `explore` starts again 1-4 tiles from 47+ earlier probes; the workshops refusal does not name `surface=1`; `bp sites workshops` does not take `only=`
Status: fixed (offline, live-untested)
Severity: medium (stone never found; a Kitchen not placed for lack of a hint)
Found: 2026-11-10, Run 16d i4 Trumpetrealms y452-y456 (110,128,136 '4 tiles from the nearest of 47 earlier probes', 110,126,136 '2 tiles ... of 48', y456 S1 96,118,136 / S2 96,121,136 with 51); Run 16a i1 Basementflew y470-y472 (`bp.place workshops only=Kitchen` '0 free sites', `site=S1 only=Kitchen surface=1` queued and done in minutes; `bp sites workshops` knew no `only`)
Module: `dfpilot/bp/sites.py` (`_explore`), `dfpilot/plan.py` (`fit_explore`), `dfpilot/cmd.py` (`no_site_hint`, `rank_sites`, `free_sites`, `_only_names`)

## Actual
- BUG-584 only added score per tile of distance (8 per tile up to 30); a fort with 2 candidate starts, both beside 50 probes, had nothing else to choose, and nothing said the rock round them was known (mudstone every time since y446).
- `no_site_hint` knew `surface=1` only when it was already asked; a fort with a (flooded, cut-off) fortcore got 'rooms open from the dug Z4 floor of the fortcore'. `bp sites workshops only=Kitchen` passed `only` unchanged to the ranking (which knows skip / add).

## Fix
- `_explore`: every earlier probe within `EXPLORE_NEAR` (8) tiles whose anchor lies less than `EXPLORE_NEAR_Z` (3) levels from the new one costs `EXPLORE_REPEAT` (150) score, up to 6, and the reason says 'REPEAT: N earlier probe(s) within 8 tiles on this layer saw its rock already'. A start beside none, or on another layer, ranks above it (unless it is many levels shallower: 10 per level). `fit_explore` adds a note to the draft when the best site is a REPEAT (another layer by `p.depth`, trade.want stone, a new core level).
- `no_site_hint` (any refusal of workshops without `surface`) adds: the shops also stand on open surface floor: `dfllm cmd bp.place tpl=workshops site=S1 only=<types> surface=1 --by llm`, and the `bp sites ... surface=1 --fresh` command; `_only_names` rebuilds the `only` list from the translated skip / add.
- `rank_sites` and `free_sites` translate `only=` (`translate_only`) so `bp sites workshops only=Kitchen` ranks the kitchen alone.

## Tests
`tests/bp/test_bp_explore.py::test_bug683_...` (REPEAT in the reason, the crowded start no longer first, another layer not counted), `tests/test_bug679_684_f44_proj.py` (the hint with skip/add and with only; free_sites translates only).

## Live check
`bp sites explore` in a fort with many probes: the top site's reason has no REPEAT, or the plan note BUG-683 says there is none left. A refused `bp.place workshops only=Kitchen` ends with the surface=1 command.

## Open
No fallback to `surface=1` by itself (the refusal names it); the probe count is the manifest's `explored` anchors, a probe on another part of the same layer is not told apart; 8 tiles / 3 levels / 150 are judgements; a fort whose only starts are beside the probes still gets them (with the note).
Related: BUG-584, BUG-356, BUG-639
