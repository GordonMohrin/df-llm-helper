# BUG-184 The runner's 'reclaimed fort without ...' request repeats about every minute when nobody acts on it
Status: fixed (offline, live-untested)
Severity: medium (23 warn lines and 38 PROJECT_REQUEST events; wake noise once follow runs)
Found: 2026-10-29, live test round 2 instance i4 (NEW9-runner-workshops-request-spam; skeptic confirmed)
Module: `lua/dfllm/runner.lua` (`M.req_due`, the reclaim scan, `M.CFG.req_wall_s`, `M.CFG.req_backoff`)

## Actual
The cooldown was `req_cool = 7 * DAY` = 8400 ticks only, about 60 s wall at 145 ticks/s. With follow off, nobody placed the project, and the
warn and the B event came every 9-10k ticks.

## Fix
- `M.req_due(K, key, ids)`: a changed set of types waits `req_cool`; the k-th repeat of the same set waits `req_cool * 2^(k-1)` game ticks AND
  `req_wall_s * 2^(k-1)` wall seconds (900 s; k at most `req_backoff` 4, so 56 days / 2 h). A new episode (nothing missing) starts unbacked.
  `S.rt.req.wsm` is now `{t, w, k, ids}` (an old plain tick reads as k 1).

## Tests
`tests/lua/test_runner_manifest.lua`: the second request needs 7 days and 900 s, the third 14 days and 1800 s (fails on b805745).

## Live check
In i4 (follow off, Masons/Still/Kitchen missing): kern.log `reclaimed fort without ...` at most once per 15 real minutes at first, then 30, 60, 120 min; `dfllm events --type PROJECT_REQUEST` the same.
