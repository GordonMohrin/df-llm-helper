# BUG-427 embark rank over ~90 world tiles took ~25 min and printed nothing after the 590 s timeout
Status: fixed (offline, live-untested)
Severity: medium
Found: 2026-11-05, Run 16a i1 Manorsubtle (`em.sh rank`, `runs/run-16a/FR-BUGS.md`)
Module: `tools/embark/embark.py` (`main` rank, `wait`, `last_sweep`), `tools/embark/steps.lua` (`hover_tile`, `sweep_dead`)

## Actual
`rank` waited up to `max(1800, 2 * tiles * (5 + 1.5 * sample))` s and printed the summary only at the end; the caller's 590 s timeout killed it with no
output (the sweep went on in DF; `rank --last` worked once it had finished). Each world tile costs a goto, `Embark` and 4 hovers with two panel reads.

## Fix
`rank` prints one flushed line per finished world tile (`[k/n] wx,wy verdict score fail=...`), waits at most `--budget` s (default 540, below 590; 0 =
whole sweep), then prints the partial pre-rank with `PARTIAL: k of n ... still runs in DF` (also on Ctrl-C). `rank --last` reads a still running sweep from
`status.json` too. `rank --resume` skips the world tiles any earlier sweep read and ranks old and new rows together. Lua: the first sampled tile of a world
tile that already shows ice, ocean/lake, heavy aquifer, evil or high savagery (`S.sweep_dead`) skips the other hovers of that tile.

## Tests
`tests/test_bug426_428_embark.py` (running status, resume, budget/partial), `tests/lua/test_embark_fix24.lua` (`sweep_dead`).

## Live check
`rank --box ...` on ~90 tiles: lines appear per tile, at ~540 s the partial rank and `PARTIAL`; `rank --box ... --resume` continues; hovers of a heavy-aquifer
tile read once (step message `world tile rejected by its first tile`). The saving per tile is a guess until timed.
