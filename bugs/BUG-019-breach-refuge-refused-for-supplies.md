# BUG-019 during a breach the only reachable emergency burrow is refused for missing supplies
Status: open
Severity: high
Found: 2026-10-15 20:03, test fort y376, siege in progress, dfpilot main 95fe16d
Module: `lua/dfllm/seal.lua` (refuge audit), `lua/dfllm/siege.lua` (BREACH choice `Tiefe+`)

## Actual
`inspect what=refuge`: `choice BREACH: burrow Kern+ want Tiefe+` and `Tiefe+ ... missing` the whole session. When the burrow was painted by hand (shaft 30,66,z80-108, 29 stair tiles, a dead end below the halls),
the kernel answered `REFUGE_FAIL alert burrow Tiefe+ refused (Tiefe+: drink 0<8, food 0<8, beds 0<2): confining to Kern+` (#12589, #12595), i.e. it put the citizens back into the burrow with the enemy.

## Expected
In `BREACH` the audit may not require beds/food/drink: the refuge's job is to survive days, not to live. `Tiefe+` should be created by the kernel (deepest dead end behind a stair) before a siege, not only wanted.

## Fix proposal
Two audit levels: `SIEGE` (supplies, as now) and `BREACH` (separated + reachable only); create `Tiefe+` from `inspect what=reach` data at boot and keep it in the alert list as a fallback.

Related: BUG-018, FR-67, `docs/v2/POSTMORTEM-run9-test-siege-2026-10-15.md`
