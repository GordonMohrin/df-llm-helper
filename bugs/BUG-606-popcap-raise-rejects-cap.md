# BUG-606 `popcap.raise cap=..` is rejected as an unknown key after `popcap.lower`
Status: fixed (offline, live-untested)
Severity: low (the player had to use popcap.set or a bare raise)
Found: 2026-11-09, Run 16c i3 Wallfree y376 (`popcap.raise cap=25` after `popcap.lower 17`)
Module: `dfpilot/schema.py` (`popcap.raise`), `lua/dfllm/readiness.lua` (`M.verbs['popcap.raise']`)

## Actual
`popcap.raise` was `Obj()` (no keys): `cap` came back as an unknown key.

## Root cause
`dfpilot/schema.py:909` (`"popcap.raise": Obj()`, BUG-293); the verb at `lua/dfllm/readiness.lua:1127` ignored its args.

## Fix
`popcap.raise` takes an optional `cap` (1..250) and raises the player's ceiling TO it, never lowering: a held ceiling below cap moves up (same hold), a held one at or above cap stays (the reply says so), a cap at or above the level's own ceiling lifts the hold, no held ceiling stays none; a famine hold is lifted as before. Without `cap` nothing changes.

## Tests
`tests/lua/test_fix10_famine.lua` (BUG-606 test); `tests/test_fix10_famine.py` (schema accepts `cap`, rejects 0 and 251)

## Live check
`dfllm cmd popcap.lower '{"cap":17}'` then `popcap.raise '{"cap":25}'`: reply `player ceiling raised 17 -> 25`, `status` shows max-pop 25.
