# BUG-678 The stranded-drink distance anchor flaps when two walk groups take turns as the worst one
Status: fixed (offline, live-untested)
Severity: low (noise)
Found: 2026-11-10, Run 16c i3 Wallfree, walk group 2258 (round 19 candidate C7): STRANDED / DECISION `thirst` every few days at a stable thirst ~26,000 with distances 7..82 tiles. BUG-661 fixed the citizen choice and the per-group announcement set; its anchor memory `mem.str_anc` held ONE group: with a second group over the thirst mark the anchor was replaced at every turn, and the group that came back started at its far citizen again.
Module: `lua/dfllm/siege.lua` (`M.anchor`, the episode end in `step`)

## Fix
`mem.str_anc` is a table per group (`str_anc[tostring(g)] = {d, pos}`): the nearest seen for each group while its episode lasts, only getting nearer; cleared per group when that group has drink. The old one-group record (`{g, d, pos}`) is replaced on the first read.

## Tests
`tests/lua/test_stranded.lua` (two groups alternate: each keeps its own nearest point, the point follows when it gets nearer).

## Live check
Wallfree-like fort with two cut-off groups: one distance per group in the STRANDED fix for the whole episode. Open: the anchor is runtime memory (a reload may announce once more).
