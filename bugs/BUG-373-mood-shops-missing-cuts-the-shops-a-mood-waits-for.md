# BUG-373 the R0 blocker 'mood shops missing' cuts Loom and Clothiers off (the last of twelve) and waits 7 days for them
Status: fixed (offline, live-untested)
Severity: medium
Found: 2026-11-04, Run 16d (i4 Plankscale: Loom/Clothier missing while three moods needed cloth), main 2fcd6e0
Module: `lua/dfllm/readiness.lua` (mood_ws_blocker), `lua/dfllm/runner.lua` (mood_wanted), `docs/v2/CONTRACTS.md`

## Actual
`mood_ws_blocker` lists economy.mood_shops' `missing` in the order of `MOOD_SHOPS` (Carpenters, Masons, Craftsdwarfs, Jewelers,
..., Clothiers, Leatherworks, Tanners, Loom, ...), takes the first three for the line and the ready `bp.place only=` command,
and counts a type only after `mood_ws_days` (7). A fort missing eight shops named Carpenters, Masons, Craftsdwarfs, and never
the Loom or the Clothiers its moods asked for.

## Root cause
readiness.lua (mood_ws_blocker, the loop over `ms.missing`): no knowledge of what the open moods want; fixed list order and
the age gate for every type.

## Fix
`runner.mood_wanted()` (new, CONTRACTS row) = the union of the types care's chain asked for (`Q.MOODWS`), sorted. The blocker
puts those first, counts them at once (no 7 days), and the head says '(N a mood waits for)'; the `only=` command starts with
them. No change of state or event fields (the `mws` text is longer by the suffix, still <= 200 bytes).

## Tests
`tests/lua/test_bug371_373_moods.lua` (readiness); fails on 2fcd6e0.
