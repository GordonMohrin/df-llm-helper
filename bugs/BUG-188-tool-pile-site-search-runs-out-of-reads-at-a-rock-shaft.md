# BUG-188 The tool pile finds no site: 300 tile reads for a 12-tile search, a rock-shaft dig job as centre, 28 days to the next try (BUG-128e)
Status: fixed (offline, live-untested)
Severity: medium (no dfllm-tools pile; the picks stay in the binned weapons pile)
Found: 2026-10-29, live test round 2, instance i4 (BUG-128e PARTIAL, NEW6), confirmed by the skeptic re-check
Module: `lua/dfllm/economy.lua` (`M.pile_site`, `M.pile_center`, new `M.pile_centres`, `M.pile_open`, `T.toolpile`)

## Actual
kern.log `tool pile: no site: the 300 tile reads are spent`. A full search of radius `pile_r` 12 needs up to (2R+w)*(2R+h) = 702 distinct reads,
so it gave up at about ring 7. The centre was the first open dig job, the cavern-check shaft in solid rock at 46,75,122 (with 800 reads: no floor
within 12). The members' area at 44,92,129 had a site within 300 reads. A failure then waited `pile_every` (28) days.

## Fix
- `pile_site`: budget `max(pile_reads, (2R+w)*(2R+h))`; the reason names the centre (`... within 12 tiles of job 46,75,122`).
- `M.pile_centres`: open jobs with plain floor in their 3x3 (at most 2, a shaft in raw rock has none), then the members, the stockpile the tools sit
  in (`take`), the first loose tool; at most `M.PILE_CENTRES` (4). `T.toolpile` tries them in order; the placement log says `searched from <by> x,y,z`.
- A `nosite` result is tried again after `M.PILE_RETRY_DAYS` (1) instead of `pile_every`; while it keeps failing it warns once per `pile_every` (`p.tpile.wt`) and logs the daily retries at debug (review: the reason names the centres, and a member centre moves daily).

## Tests
`tests/lua/test_economy_tools_b128.lua` BUG-188 (centre skips a no-floor job, site at ring 10 with pile_reads 300, reason names the centre);
`tests/lua/test_economy_tools_a3.lua` BUG-188 (retry the next day, `searched from`) and the BUG-053 "logged once" test now counts warn lines
(fail on b805745).

## Live check
i4: remove dfllm-tools (or wait for TOOL_BLOCKED with `pile nosite`); the next daily pass logs `tool pile: dfllm-tools 3x2 at ... (searched from
member 44,92,129)` or a `no site` reason naming each centre; a failed day is followed by another try the next day.
