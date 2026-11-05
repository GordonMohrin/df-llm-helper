# BUG-472 Run 16a i1 (refuge hatch 'unreachable', bedrooms and workshops paused for months) and i4 (seal 'no builder' 800 d)
Status: fixed (offline, live-untested)
Severity: high
Found: 2026-11-05, round 29 notes (`runs/run-16a..16d/FR-BUGS.md`), main 59d6abb
Module: lua/dfllm/runner.lua:focus (seal_first.lead_days), dfpilot/fairplay.py:RUNNER_LIM, config/baseline.json

## Actual
`seal first: y374s0b0 with 1 piece open runs first; paused: bedrooms, workshops` for months; a GlassFurnace a mood waited for stood 34 days; the same DECISION 8 times. A seal that cannot be built (hatch 'unreachable', no builder) pauses everything the seal-first rule pauses.

## Root cause
The stuck clock (`seal_first.stuck_days`, 3) restarts on any change of its signature (stage:chunk:open pieces:progress) and waits while the mode freezes the seal; a seal that is retried or whose progress counter moves without closing a piece leads for ever.

## Fix
`seal_first.lead_days` (10, 1-400, `fairplay.RUNNER_LIM`, baseline.json, CONTRACTS): per seal `n0` / `ls` / `ld` in the focus record; a seal that led this long without one more piece closed (`n` below `n0`) is classified stuck for the pause rule (`f.stuck`, pauses nobody), SEAL_STUCK is raised if it was not yet (the stalled decision follows by its own cadence), kern.log `seal first: <id> led N days without closing a piece ...: the others run again; the seal stays stuck`; a closed piece makes it lead again. Repairs (closures) are not touched.

## Not done
The DECISION for cause 'unreachable' still offers cancel + place again (BUG-471 removes the usual reason, the phantom hatch).

## Tests
`tests/lua/test_bug469_473.lua` (stuck_days 60, lead_days 2: paused at 1.5 days, free after 3, one SEAL_STUCK, the door built later completes it; default 10).

## Live check
kern.log line above; the row of a bedrooms project says '' instead of 'paused: seal ...'.
