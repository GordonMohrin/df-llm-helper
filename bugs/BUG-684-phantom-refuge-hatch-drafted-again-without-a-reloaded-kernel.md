# BUG-684 `plan propose` / the minimal plan draft `seal at=refuge` for a hatch nobody dug although the kernel stuck on it again and again
Status: fixed (offline, live-untested)
Severity: medium (SEAL_STUCK / seal_stalled every month, a plan check ERROR that makes P2+ unappliable)
Found: 2026-11-10, Run 16c i3 Wallfree y414-y421 (hatch 67,44,139: SEAL_STUCK 'nothing stands at 67,44,139' / DECISION seal_stalled '(not placed)' 32-96 d, events.jsonl:9400-9599; FR-BUGS 'Phantom-Seal weiter in plan propose')
Module: `dfpilot/cmd.py` (`phantom_tiles`, `_stuck_hatch_events`, `refuge_stair`), `dfpilot/plan.py` (`refuge_projects`, the plan check)

## Actual
Round 43 (BUG-657) lets the kernel cancel the seal and write PROJECT_BLOCKED d.phantom; `cmd.phantom_tiles` reads those events. That kernel was not reloaded: no phantom event, so `refuge_stair` kept the manifest head. The sites snapshot (bbox z143-153) does not reach z139 either, so the map could not say the tile is solid or never revealed (`_snap_char` None = 'unknown, as given'). The follow's MINIMAL plan and `plan propose` drafted `seal at=refuge` again.

## Root cause
`cmd.py` `phantom_tiles` knew one source (the kernel's phantom event); `refuge_stair` trusts a tile the snapshot does not cover.

## Fix
`phantom_tiles` also counts the kernel's older words: a tile named 'hatch x,y,z' by SEAL_STUCK `why 'not placed'` (wait 'nothing stands at') or by a DECISION_NEEDED `seal_stalled` '(not placed)', in at least `PHANTOM_STUCK_EVENTS` (3) events spread over `PHANTOM_STUCK_DAYS` (10) game days, within the 20-year window. `refuge_stair` still reads a revealed tile first: a stair dug later brings the demand back. Plan check, propose and the follow's minimal plan all read `refuge_stair`.

## Tests
`tests/test_bug679_684_f44_proj.py` (two events in days: no; three over 30 days and the seal_stalled decision: the tile is a phantom, `refuge_stair` says `nostair`, head None; another cause 'no material' is none).

## Live check
Wallfree-like fort: `plan propose` has no `seal at=refuge`, `plan check` has no refuge-hatch ERROR, the status says 'refuge: the stair head ... was never dug'.

## Open
A real hatch that is 'not placed' three times over 10 days on a tile the map does not show is also treated so until the tile is revealed as a stair (the entrance check drafts a seal for a real opening by itself).
Related: BUG-638, BUG-657
