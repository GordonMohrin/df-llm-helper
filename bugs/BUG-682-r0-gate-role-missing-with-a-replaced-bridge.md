# BUG-682 R0 no_outer with O1 'replaced': propose drafts no stage 3 and says nothing; the status sends the player to a stage 3 that cannot help
Status: fixed (offline, live-untested)
Severity: medium (the drill off for ever without a word why)
Found: 2026-11-10, Run 16d i4 Trumpetrealms y451-y453 (FR-BUGS 'plan propose draftet kein fortcore stage 2/3 trotz R0 no_outer' and 'O1 replaced => no_outer permanent'; state bridges {O1 replaced, B1 up, B2 destroyed}, ready.fail [no_outer, bridge:B2, levers:B2])
Module: `dfpilot/plan.py` (`stage3_due`, `r0_roles`, `replaced_gate_note`), `dfpilot/brief.py` (drill hint)

## Actual
O1 was destroyed three times; the kernel put wall + door in its place (BUG-048 'replaced'). `plan.BRIDGE_STANDING` counts 'replaced' as standing (right for open_perimeter), so `stage3_due` found nothing missing and propose drafted only explore while readiness listed `no_outer` (a replaced bridge clears no gate role). By hand `fortcore stage 3 @same` passed `plan check`, was 100 % and changed nothing: the keeper does not rebuild a replaced gate. The brief said 'build fortcore stage 2/3 first'.

## Root cause
`plan.py` `stage3_due` (the 'replaced' = standing test); `brief.py` drill hint.

## Fix
- `stage3_due` is also due while `ready.fail` lists no_outer / no_inner and no stage 3 is applied, under way or drafted (`r0_roles`): the stage that makes the gate is drafted (with stage 3 built, `fort.o1` stays the stop).
- With stage 3 built and the bridge of the missing role 'replaced', the draft's notes say it (`replaced_gate_note`): 'R0 no_outer stays: O1 was replaced by wall + door after repeated losses ..., no stage is drafted for it; no automatic drill runs until a gate stands again'. The brief's drill line names the replaced bridges instead of 'build fortcore stage 2/3 first'.

## Tests
`tests/test_bug679_684_f44_proj.py` (stage 3 due with a replaced O1 and no_outer, not without the R0 fail, not with stage 3 built; the note).

## Live check
A fort with R0 `no_outer` and `bridges.O1 replaced`: the brief's drill line says 'O1 replaced by wall + door ...', `plan propose` notes BUG-682. A fort with no stage 3 and `no_outer` gets `fortcore@same stage 3` in the draft.

## Open
R0 still counts a replaced bridge as a missing role (the doctrine wants a gate there): taking the wall + door away and placing the bridge again is the player's call; no kernel change (no bridge, gate, refuge, lockdown or seal behaviour changed: no siege traffic test). Why the draft of y451 lacked stage 3 is inferred from the state (O1 replaced counted as standing, B2 destroyed); the plan inputs of that day were not readable offline.
Related: BUG-048, BUG-110, BUG-141
