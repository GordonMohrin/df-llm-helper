# BUG-748 "set aside, no runner slot (the others go first)" beside free runner slots and 8 idle adults: the text blamed the slots for a project that did not move
Status: fixed (offline, live-untested)
Severity: low (misleading cause; the notes chased slot accounting)
Found: 2026-11-11, Run 16b i2 Whirledrampart y435-y440 (explore dig 1 %, bedrooms 37 %, dining 43 %, traps 70 %, workshops / tombs dig 0 % "set aside, no runner slot" beside "runner slots 4-6 (8 free idle adults)"; `bp.resume` helps ~30 d), Run 16a i1 Basementflew (explore / tombs dig 6 %)
Module: `lua/dfllm/runner.lua` (`Q.idle_scan`), `dfpilot/schema.py` (PROJECT_BLOCKED `free`)

## Root cause
`Q.idle_scan` sets a project aside after `idle_days` (30) without own progress (BUG-328) and worded it "set aside, no runner slot (the others go first)". It is the consequence of no progress (the DF job nobody takes, BUG-747; the dig nobody digs, BUG-749), not a slot shortage: `Q.slot_cap` had grown to 4-6 (kern.log "runner slots 6 (active 3 + 8 free idle adults of 31)"). A resumed project places its next pieces, which is the progress that lasts until the next 30 days: that is why `bp.resume` helped about 30 days.

## Fix
The text reads "set aside for want of progress, not of slots (N free idle adults)" with `waits:` (the cause) in front. PROJECT_BLOCKED gets `d.free` (economy `idle_free`, the free idle adults of the last daily scan; schema `free:i`). The set-aside rule itself is unchanged: the project stays out of the slots until it moves, and what it placed in DF stays.

## Tests
`tests/lua/test_bug328_329_projects.lua` (the new wording), `tests/lua/test_bug747_749_boost.lua` ("BUG-749 / BUG-748": the log line and `d.free`).

## Open
A set-aside project still comes back only by progress or `bp.resume`; with BUG-747 and BUG-749 the progress is expected to come from the raised jobs.
