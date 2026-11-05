# BUG-428 embark hover scan does not propose LX/LY variants for an edge-only brook
Status: fixed (offline, live-untested)
Severity: low
Found: 2026-11-05, Run 16a i1 Manorsubtle (the brook was `EDGE ONLY` at 6,6 until the player moved the rectangle to 7,6)
Module: `tools/embark/embark.py` (`variant_lines`, `summarize`)

## Fix
For a hover row (not a sweep) whose brook tiles lie on the outer ring or beyond the hovered 4x4, `summarize` adds
`variant: LX,LY a,b puts N brook tile(s) in the core (now M): scan WX,WY,a,b --hover` for the LX,LY within 3 tiles (0-12) that puts the most of the seen brook
tiles into the core, ties by the smaller shift. The tiles beyond the hovered grid are unread, so it is a scan command, not a verdict.

## Tests
`tests/test_bug426_428_embark.py` (18,22: brook on the right column -> 7,6; core brook -> none; inside the world tile).
