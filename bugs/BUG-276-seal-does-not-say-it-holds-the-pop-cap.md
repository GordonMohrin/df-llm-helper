# BUG-276 an opening walled after an unsuitable door held max-pop at 35 for days; the seal never said so
Status: mitigated (offline, live-untested): named, no priority raise
Severity: low (migrants stopped, G12; the cause was visible only in readiness)
Found: 2026-10-29, Run 15 Guildcleans (y375 autumn d58-d62), fix6-runner-seal
Module: `lua/dfllm/runner.lua` (`Q.perim_hold`, `stuck_event`, `note_pause`); `dfpilot/schema.py` SEAL_STUCK `hold`

## Actual
New opening 109,94,130 without a door: `door unsuitable (no wall or fortification beside it): wall instead`, project
c1a1876babf41a8601; status PERIMETER OPEN 5 days and `pop 35 cap 35 gate 35` (readiness perimeter.hold_pop, intended).

## Fix
While readiness' ceiling is held by the open perimeter (`readiness.ceiling` why open_perimeter), the seal-first kern.log line
and SEAL_STUCK (`d.hold`, msg) name it: `pop cap 35 held by the open perimeter (5 d: 1 way in)`. Not built: a raised job priority
for the piece (no UI-equal priority for a construction job is proven offline); the seal already runs first (first slot, dig
priority 1, its work orders on top).

## Tests
`tests/lua/test_runner_seal_fix6.lua` `BUG-276 ...` (fails on 2b9c009).

## Live check
Guildcleans-like open perimeter in a fort of 30+: kern.log `seal first: ... runs first (pop cap N held by the open perimeter (D d: ...))`; SEAL_STUCK d.hold.
