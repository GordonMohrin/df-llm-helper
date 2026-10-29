# BUG-207 inspect what=unit does not find a unit by the nickname its sheet shows
Status: fixed (offline, live-untested)
Severity: low (the player sees the nickname on the sheet and cannot look the unit up by it)
Found: 2026-10-29, live test round 3 (BUG-173b re-check), kernel bd27973
Module: `lua/dfllm/curse.lua` (`unit_keys`, `find_unit`)

## Actual
Unit 42306 with the nickname `Blinky` (getReadableName "`Blinky' Imeshakrul \"Sprinkletin\", Peasant"): key
'Astesh Imeshakrul', 'Astesh' and '42306' found him; 'Blinky Imeshakrul' and 'Blinky' gave `ERR no such citizen`.
`unit_keys` stripped the nickname from the sheet name (key 1 became the bare last name 'imeshakrul', shared by his
relatives) and added the real first + last name; no key held the nickname.

## Fix
`unit_keys` adds `nickname + last name` and the nickname alone when `u.name.nickname` is set, and drops the sheet key when
it is only the last name (the sheet name began with the nickname). `find_unit` also matches the sheet name typed with its
quotes ("`Blinky' Imeshakrul"). The single-word rule then finds 'Blinky' too; the report index (`index`) learns the
nickname keys as well.

## Tests
`tests/lua/test_bug207_208_curse.lua` BUG-207 (three tests), fail on bd27973.

## Live check
A citizen with a nickname set: `python -m dfpilot cmd inspect '{"what":"unit","key":"<Nick>"}'` and key
`"<Nick> <Last>"` return `ok unit <id>`; key `"<Last>"` alone does not return him when a relative shares the last name.
