# BUG-220 status clips the UNREADY line's trap-hall note and its one next: hint
Status: fixed (offline, live-untested)
Severity: medium (status, the line a weak model reads first, gave no next command and hid why no seal comes)
Found: 2026-10-29, live round 4, Trussroads (port 5000); residual of BUG-211 and BUG-212
Module: `dfpilot/brief.py` (`line_unready`)

## Actual
`brief.line_unready(ctx, cmds=False)` was about 123 tokens and ended with `... audit route: bypass: wall 75,65,131 ramp (+more) -> 74,65,130
| no trap hall yet: ... | next: wall it: ...`. status_text ranks that line 2 and fit_ranked clips rank-2 lines from the end to 90 and then
60 tokens, so `dfpilot status` showed `... audit route: bypass: wall 75,65,131 ramp (+more) -~`: no 'no trap hall yet', no `next:`.

## Fix
With cmds=False (status) the decision parts (the 'no trap hall yet' note and `next: <first hint>`) come right after `SIEGE UNREADY (R0):
<blockers>`, before PERIMETER, ways in, traps and route; the clip now cuts the details. brief (cmds=True) keeps the old order.

## Tests
`tests/test_bug220_223_cli.py` (status under a long UNREADY line with and without a trap hall), fails on 5e9e719;
test_cli_status and test_perimeter_escalation read the new order.

## Live check
Trussroads with a bypass and no trap hall (or any R0 fort with many blockers): `python -m dfpilot status` line 3 reads `SIEGE UNREADY (R0):
<blockers> | no trap hall yet: ... | next: ...` (or `| next: wall it: ...` with a hall); `python -m dfpilot brief` lists all hints at the end.
