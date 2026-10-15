# BUG-018 the refuge audit passes a burrow that contains the fort's entrances and main halls
Status: open
Severity: high (the civil alert confined 50 citizens in the area the invaders entered; 50 -> 1)
Found: 2026-10-15 20:00, test fort y376, dfpilot main 95fe16d + local trade fix, first real siege (17 goblins, 2 cave dragons, 5 jabberers)
Module: `lua/dfllm/seal.lua` (refuge audit, `inspect what=refuge`), `lua/dfllm/siege.lua` (burrow choice)

## Actual
`inspect what=refuge`: `Kern+ ok:1 (tiles 6960, drink 1031, food 912, beds 55)`, choice SIEGE/ALERT `Kern+`. The same status line said `R0 fail: audit_old, audit_fail, bypass, refuge_sep, civ_sep, no_inner, no_outer`
for the whole session (`refuge_sep`: the refuge is not separated from the entrances). `Kern+` covers z108-112 of the main halls; the three open entrances (shaft head 55,62,117, north ramp room 61,55,117, east stair 75,70,117)
lead into it. 1360 ticks after the arrival: `BREACH: hostile inside Kern+`; the alert kept all citizens inside.

## Expected
The audit rates a refuge `ok` only if no entrance route reaches it without a door/wall/gate (`refuge_sep`), otherwise `REFUGE_FAIL` names the entrances inside, and the siege module does **not** confine civilians to it
(alert off and flee, or the nearest separated dead end).

## Fix proposal
Take `refuge_sep` and the `entrances` BFS into the burrow `ok` flag; with no passing burrow choose the best dead end (BUG-019) instead of the whole fort.

Related: BUG-019, FR-65, FR-67, `docs/v2/POSTMORTEM-run9-test-siege-2026-10-15.md`
