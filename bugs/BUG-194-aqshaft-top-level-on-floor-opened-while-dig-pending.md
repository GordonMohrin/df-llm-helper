# BUG-194 aqshaft counts a top level on a floor as opened while its dig job is pending
Status: fixed (offline, live-untested)
Severity: low (the next level is designated before the top stair exists)
Found: 2026-10-29, FR-95 live test 1 review, instance i4 (kernel b805745)
Module: `lua/dfllm/aqshaft.lua` (`dig_step`)

## Actual
`dig_step` treated every centre tile that is no wall as dug. A top level on a floor (the `j` down stair designated, not dug
yet) was opened at once, judged dry and the level below designated.

## Fix
A centre tile counts as dug only with no wall and no pending dig job (`v.dig == ''`); the same rule serves BUG-191's read-only check.

## Tests
`tests/lua/test_bug191_194_aqshaft.lua` BUG-194, fails on 9da84d6.

## Live check
An aqshaft placed on a floor tile: `levels.<top>` has no `opened` and no `l1` designation until the down stair is dug.
