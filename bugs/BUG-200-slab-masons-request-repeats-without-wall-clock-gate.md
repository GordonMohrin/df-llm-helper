# BUG-200 The slab PROJECT_REQUEST workshops why=slabs types=[Masons] repeats every 21-26 game days (a few real minutes) without end
Status: fixed (offline, live-untested)
Severity: medium
Found: 2026-10-29, live test round 3 i4 (NEW-slabreq; skeptic confirmed)
Module: `lua/dfllm/economy.lua`, `lua/dfllm/runner.lua` (`M.slab_why`, `M.SLAB_REQ`; runner `M.req_types`)

## Actual
With ghosts and no Masons and follow off, #33934 .. #34060 came about every 24-30k ticks (3 real minutes at 146 t/s). `p.slab_wsreq` was a bare
tick, the gate only `request_days * DAY`: no wall clock, no backoff, no dedup against runner's mandatory request, which names Masons too.

## Fix
- `p.slab_wsreq` is `{t, w, k, n}` (an old plain tick reads as k 1). The k-th unanswered repeat waits `request_days * 2^(k-1)` game days AND
  `900 s * 2^(k-1)` wall seconds (k <= 4, `M.SLAB_REQ`). More ghosts than `n` wait the base period only and start k over. A standing
  Masons clears the record.
- No slab request while runner's mandatory workshops request (`S.rt.req.wsm`, its episode standing) names Masons (`sb.asked = 'mandatory'`);
  runner `M.req_types(K, key)` gives those types.

## Tests
`tests/lua/test_economy_b2.lua` (two BUG-200 tests; BUG-133 needs the 900 s now), `tests/lua/test_runner_manifest.lua` (req_types). Each fails on bd27973.

## Live check
i4 with follow off, ghosts and no Masons: `dfllm events --type PROJECT_REQUEST` why=slabs at most after 14 d + 15 min, then 28 d + 30 min,
56 d + 60 min; none while a mandatory request lists Masons; `inspect orders` slabs.asked `mandatory`.
