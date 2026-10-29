# BUG-192 Observe mode never smooths around a damp tile lost() finds once the project already observes
Status: fixed (offline, live-untested)
Severity: medium (the rough aquifer walls beside that tile stay a source)
Found: 2026-10-29, FR-95 live test 1, instance i4 (kernel b805745)
Module: `lua/dfllm/runner.lua` (`Q.aq_lost`)

## Actual
`Q.aq_lost` called `M.AQ.observe(..., 'cancel')` only when the project did not observe yet. A second damp cancel in an
observing project was designated again with the damp marker but never added to `r.pts`; `A.tick` smooths only around `r.pts`.

## Fix
`Q.aq_lost` always calls `M.AQ.observe(..., 'cancel')`: the tile joins `r.pts` (deduplicated, at most obs_pts), AQ_OBSERVE
stays once per record.

## Tests
`tests/lua/test_bug191_194_aqshaft.lua` BUG-192 (the second damp tile is in `pts`, one AQ_OBSERVE, its walls get `s`), fails on 9da84d6.

## Live check
An observing project with a second damp cancel (no report): m.runner aq[<proj>].pts lists both tiles, and kern.log
`observe: N walls beside the damp tile x,y,z smoothed` follows for the second one once it is dug.
