# Bugs

Bugs of dfpilot found by playing (Gordon's rule 15.10.2026: bugs go here, one file per bug; wishes and missing features
stay in `docs/feature-requests/README.md`). A bug is something that exists but gives a wrong result or misleading
output. File name: `BUG-NNN-short-slug.md`. Add one line to the table below and keep `Status` current.

Template for a new file:

```
# BUG-NNN title
Status: open | fixed in <commit> | not reproducible
Severity: critical (loses citizens or crashes DF) | high (wrong decision) | medium (wrong report) | low (noise)
Found: date, save, version (git hash), how
Module: file:line
Expected / Actual:
Evidence: raw output, commands, tick
Cause (known or suspected):
Fix proposal:
Related: FR-xx, BUG-xx
```

| ID | Status | Severity | Title | Module |
|----|--------|----------|-------|--------|
| [BUG-001](BUG-001-seal-ignores-stored-items.md) | fixed in 017411c | high | `seal` ignores drink, food and seeds stored in barrels, so every burrow audit fails | lua/dfllm/seal.lua:54 |
| [BUG-002](BUG-002-perimeter-empty-without-manifest.md) | fixed in 017411c | high | `perimeter` has no pieces on a fort without a manifest, PERIMETER_BROKEN cannot fire | lua/dfllm/seal.lua |
| [BUG-003](BUG-003-tombs-inspect-stale.md) | open | medium | `inspect tombs` shows stale numbers (unburied, free, entombed) after burials succeeded | lua/dfllm/care.lua |
| [BUG-004](BUG-004-planned-buildings-wait-for-forbidden-items.md) | open | high | planned buildings wait for forbidden items for ever, JOBS_SUSPENDED repeats the same line | lua/dfllm/economy.lua:2999 |
| [BUG-005](BUG-005-depot-job-stays-suspended.md) | open | high | the trade depot construction job is resumed every day and stays suspended, DEPOT_MISSING says "being built" for ever | lua/dfllm/economy.lua |
| [BUG-006](BUG-006-reach-stair-false-positive.md) | fixed in 017411c | low | `reach` reports a down stair without counterpart although the shaft below is all stairs | lua/dfllm/seal.lua |
| [BUG-007](BUG-007-kernel-cost-over-budget.md) | open | medium | kernel cost 82-90 ms/s vs limit 25, `repeat` bucket unattributed, budget self-test always fails | kern / perf |
| [BUG-008](BUG-008-ghosts-event-repeats.md) | open | low | GHOSTS and NO_DEPOT repeat every few game days and drown the stream | lua/dfllm/care.lua |
| [BUG-009](BUG-009-construction-jobs-resuspended.md) | open | high | construction jobs are suspended again within 5 s of every resume, new buildings are never built | lua/dfllm/economy.lua:2999 |
| [BUG-010](BUG-010-legacy-autolabor-enabled.md) | open | high | `autolabor` runs in legacy mode after map load, the engine that crashed DF in Run 9 | lua/dfllm/baseline.lua:158 |

Not bugs but gaps: no coffin provisioning (FR-61), derive the perimeter without a manifest (FR-60), hospital water
(FR-47). Live test report with raw outputs: `docs/v2/STATUS.md` §0h.
