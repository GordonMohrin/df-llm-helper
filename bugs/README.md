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
| [BUG-003](BUG-003-tombs-inspect-stale.md) | fixed in 7006350 (offline, live-untested) | medium | `inspect tombs` shows stale numbers (unburied, free, entombed) after burials succeeded | lua/dfllm/care.lua |
| [BUG-004](BUG-004-planned-buildings-wait-for-forbidden-items.md) | fixed in 9b9dcdc (offline, live-untested) | high | planned buildings wait for forbidden items for ever, JOBS_SUSPENDED repeats the same line | lua/dfllm/economy.lua:2999 |
| [BUG-005](BUG-005-depot-job-stays-suspended.md) | fixed in 9b9dcdc (offline, live-untested) | high | the trade depot construction job is resumed every day and stays suspended, DEPOT_MISSING says "being built" for ever | lua/dfllm/economy.lua |
| [BUG-006](BUG-006-reach-stair-false-positive.md) | fixed in 017411c | low | `reach` reports a down stair without counterpart although the shaft below is all stairs | lua/dfllm/seal.lua |
| [BUG-007](BUG-007-kernel-cost-over-budget.md) | fixed in 501b08d | medium | kernel cost 82-90 ms/s vs limit 25, `repeat` bucket unattributed, budget self-test always fails | kern / perf |
| [BUG-008](BUG-008-ghosts-event-repeats.md) | fixed in b01bec4, 7006350 (offline, live-untested) | low | GHOSTS and NO_DEPOT repeat every few game days and drown the stream | lua/dfllm/care.lua |
| [BUG-009](BUG-009-construction-jobs-resuspended.md) | fixed in 9b9dcdc, 7006350 (offline, live-untested) | high | construction jobs are suspended again within 5 s of every resume, new buildings are never built | lua/dfllm/economy.lua:2999 |
| [BUG-010](BUG-010-legacy-autolabor-enabled.md) | fixed in 1d9b6a9 (offline, live-untested) | high | `autolabor` runs in legacy mode after map load, the engine that crashed DF in Run 9 | lua/dfllm/baseline.lua:158 |
| [BUG-011](BUG-011-civ-alert-flips-on-then-off.md) | fixed in 4e2b43c (offline, live-untested) | high | the arrival lockdown switches the civil alert on, the siege module switches it off 12 ticks later | lua/dfllm/reflex.lua, siege.lua |
| [BUG-012](BUG-012-entrance-door-not-recognised.md) | fixed in 4e2b43c, 0faebcc (offline, live-untested) | high | the arrival lockdown forbids 0 doors ("0 entrances") although the fort has an entrance door | lua/dfllm/reflex.lua, seal.lua |
| [BUG-013](BUG-013-lever-pulls-blocked-by-civil-alert.md) | fixed in 055c92f (offline, live-untested) | high | the civil alert confines everybody to Kern+, lever pulls for the bridges are never done (1-3 of 4 bridges up) | lua/dfllm/reflex.lua, gate.lua, siege.lua, seal.lua |
| [BUG-014](BUG-014-autolabor-legacy-false-failure.md) | fixed in 413f614 (offline, live-untested) | low | AUTOLABOR_LEGACY says "mode monitor failed, still legacy" although the mode was switched | lua/dfllm/baseline.lua |
| [BUG-015](BUG-015-door-forbid-flag-reset-in-one-frame.md) | fixed (offline, live-untested; cause open) | high | the entrance door 74,70,117 cannot be kept forbidden (flag reset within one frame), the lockdown still reports it | lua/dfllm/act.lua, reflex.lua |
| [BUG-016](BUG-016-trade-blocked-by-open-unit-sheet.md) | fixed (Claude, 20:00) | medium | two caravans lost: trade waits for ever on `ui_busy` while a unit sheet stays open | lua/dfllm/trade.lua |
| [BUG-017](BUG-017-mood-risk-false-missing.md) | fixed (offline, live-untested) | low | MOOD_RISK reports missing materials although the mood dwarf already holds every item | lua/dfllm/care.lua |
| [BUG-018](BUG-018-refuge-audit-ignores-entrances.md) | fixed (offline, live-untested) | high | the refuge audit passes a burrow that contains the entrances and main halls (50 -> 1 in the first real siege) | lua/dfllm/seal.lua, siege.lua |
| [BUG-019](BUG-019-breach-refuge-refused-for-supplies.md) | fixed (offline, live-untested) | high | during a breach the only reachable emergency burrow is refused for missing supplies | lua/dfllm/seal.lua, siege.lua |
| [BUG-020](BUG-020-embark-rectangle-ignores-injected-mouse.md) | mitigated (fails early; cause open) | medium | `embark.py scan` cannot place the rectangle: it ignores the held/injected mouse | tools/embark |
| [BUG-021](BUG-021-cutoff-false-positive-group-renumber.md) | fixed (offline, live-untested) | low | CUTOFF fires while everybody reaches everything (group ids renumber during construction) | care / seal |
| [BUG-022](BUG-022-fortcore-stage2-build-lost-no-retry.md) | fixed (offline, live-untested) | high | fortcore stage 2 ends `build_lost` for good: B1 and the traps are never built | lua/dfllm/runner.lua |
| [BUG-023](BUG-023-woodcutters-do-not-fetch-the-axe.md) | mitigated in 47d98c4 (offline, live-untested): TOOL_BLOCKED, labor repair; pickup trigger on (Gordon's yes 2026-10-16) | high | woodcutters never fetch the axe from the bin: no FellTree job ever runs, no logs for a year (workaround: put the axe into their hand) | lua/dfllm/economy.lua |
| [BUG-024](BUG-024-weave-silk-thread-not-found.md) | mitigated in 47d98c4 (offline, live-untested): webs reported as uncollected | medium | weaving silk never starts: "Needs 1 unused collected silk thread" with 6500 reachable silk threads; 84 naked | economy |
| [BUG-025](BUG-025-trade-looks-at-the-wrong-depot.md) | fixed (live) | medium | with two built depots trade checks the manifest depot while the merchants unload at the other: caravan with goods ends `nothing_listed` | trade |
| [BUG-026](BUG-026-caravan-retry-too-late-and-silent-loss.md) | fixed (offline, live-untested) | medium | a caravan visit lost to ui_timeout: trade paced/demoted for its cost while its UI phases ran on real time; fix: kernel boost, trade clock (FPS cap 100), phase limits on its own clock, retry in time_remaining units | trade, kern, arbiter |
| [BUG-027](BUG-027-lockdown-bridge-crushes-citizens.md) | fixed: occupancy, alert order, pull timeout, BRIDGE_CRUSH (offline, live-untested) | critical | the lockdown raises bridges while citizens stand on the footprint: 7 deaths incl. a baby (17880 x=128, O1 x=101) | gate/siege |
| [BUG-028](BUG-028-breach-traps-people-without-water.md) | fixed (offline, live-untested): rescue, BREACH -> SIEGE, raise hold, SUPPLY_OUTSIDE; stop: FR-68 | critical | BREACH keeps inner bridges up for weeks, soldiers/civilians behind them die of thirst; `dfllm stop` leaves popups/fps | siege/gate/military/kern |
| [BUG-029](BUG-029-squad-stations-behind-raised-bridges.md) | fixed in 285e31d (offline, live-untested): inner station READY_IN, stray return, unseal; flasks open | high | squad stations between O1 and B2 (gallery, melee): soldiers cut off from drink while B1/B2 are up, recruits locked out after a restart | military/siege |
| [BUG-030](BUG-030-destroyed-bridges-stay-in-the-kernel.md) | fixed in 486b5ce (offline, live-untested): BRIDGE_DESTROYED, destroyed = an open way, deep defense SIEGE_DEEP | critical | trolls destroyed O1, B1, B2: the kernel kept pulling them (STRANDED 'B1 raised' 40+ times), no plan B, squads in the kill field; Run 10 fell | gate/siege/sense |
| [BUG-031](BUG-031-refuge-unusable-in-run-11.md) | fixed in 2634e11 (offline, live-untested): entrance gaps beside doors named and listed, breach days per episode, stocked refuge at SIEGE level, dry alert burrow relaxed, cistern state in HOSPITAL_DRY | critical | Run 11: `REFUGE_FAIL Kern+: open to 1 entrance ... Door` and "citizens flee" at every invasion, thirsty citizens in Tiefe+ only reported, HOSPITAL_DRY beside a cistern | lua/dfllm/seal.lua, siege.lua, water.lua |
| [BUG-032](BUG-032-squad-stationed-on-a-bridge.md) | fixed (offline, live-untested): stations clear of every bridge footprint + ring (moved to the inner side, else the next station), a squad holding a raise re-stationed at once, fortcore b2/melee moved, validator `station_bridge`; deep defense: O1's pull to a lever the confined civilians may take; melee squads refilled in a siege from healthy core civilians | high | Run 11 y432: `GATE_FAIL B2 not up after 908 ticks`, squad 104 at fortcore's stations.b2 (one tile behind B2) held the BREACH raise | lua/dfllm/military.lua, stations.lua, siege.lua, gate.lua; dfpilot/bp/fortcore.py, validate.py |

Not bugs but gaps: no coffin provisioning (FR-61), derive the perimeter without a manifest (FR-60), hospital water
(FR-47). Live test report with raw outputs: `docs/v2/STATUS.md` §0h.
