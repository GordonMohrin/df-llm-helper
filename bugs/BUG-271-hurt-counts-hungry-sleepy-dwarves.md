# BUG-271 inspect workload 'hurt 14' counts dwarves without a wound
Status: fixed (offline, live-untested)
Severity: low (a wrong idle reason sent the player to the hospital)
Found: 2026-10-29, Run 15 Earthboat (FR-BUGS.md), fix6-econ-supply
Module: `lua/dfllm/economy.lua` (`M.idle_flags`)

## Actual
idle_why hurt 14; units 26374/26371/21852 had 0 wounds, blood 100 %, hunger 30000-39000 and were sleepy. `M.idle_flags` set hurt
from `health.flags.needs_healthcare` alone and checked it before rest.

## Fix
hurt = a wound, or needs_healthcare while blood is below its maximum; the flag alone is `f.care` (not a class), so a sleepy
dwarf is rest. The root cause of the stale flag is not verified live (plausible: DF keeps needs_healthcare until a diagnosis).

## Tests
`tests/lua/test_economy_idle.lua` BUG-271 (fails on 2b9c009); the FR-77 fixtures' `hurt` now carries a wound.

## Live check
Earthboat: `dfllm cmd inspect '{"what":"workload"}'` idle_why.hurt equals the dwarves with wounds or lost blood; read-only for one
of the former 'hurt' ids: body.wounds count, blood_count/blood_max, health.flags (which flag DF keeps set).
