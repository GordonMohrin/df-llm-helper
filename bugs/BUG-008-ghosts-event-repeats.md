# BUG-008 GHOSTS and NO_DEPOT repeat every few game days and drown the stream
Status: open
Severity: low (noise, but it hides new events; at timestream speed a game week is a few seconds)
Found: 2026-10-15, Run 9 save autosave 1, dfpilot main 3edc277
Module: `lua/dfllm/care.lua` (GHOSTS cadence), trade (NO_DEPOT / DEPOT_MISSING)

## Actual
`follow` woke for GHOSTS again and again with merge counts `x9`, `x14`, `x12`, `x11`, `x31` within 20 real minutes, each time the
same text ("N ghost(s), M citizen(s) unburied > 3 d: no_coffin 24, ..."); NO_DEPOT came with every caravan visit (four visits) and
with `DEPOT_MISSING (one is being built)` although nothing was being built (BUG-005). The documented cadence is "again when the set
grows, else weekly"; weekly is a few seconds at 400 ticks/s.

## Fix proposal
Weekly means wall clock at timestream speed: use `max(7 game days, 10 min wall clock)`; repeat only when the set grew or a cause
changed; one NO_DEPOT per caravan visit, not per frame batch.

Related: FR-38 (wall clock vs game clock), FR-26, BUG-005
