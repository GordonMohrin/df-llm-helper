# BUG-764 brief says 'traps 3/3', status says 'traps 0 of 3 armed'
Status: fixed (offline, live-untested)
Severity: low
Found: 2026-11-11, Run 16a i1 Basementflew y525: the player brief read 'traps 3/3' while status read 'traps 0 of 3 armed'
Module: `dfpilot/brief.py` (`line_unready`), `dfpilot/wake.py` (`trap_note`)

## Actual
Both lines described the same three armed traps. 'traps n/m' is armed of listed (state `traps`); 'traps 0 of 3 armed' was the cheapest route's count (audit min_traps) followed by the armed count (BUG-516), which reads as 'none of three armed'. The audit's note 'H of A armed traps in the trap hall' had the same shape (hall first, armed second).

## Root cause
`line_unready` printed `traps {route} of {armed} armed`; `trap_note` printed `{hall} of {armed} armed traps in the trap hall`.

## Fix
`line_unready`: 'traps 0 on the cheapest route, 3 of 3 armed in all (a bypass skips the hall)' (armed and listed from state `traps` n/m). `trap_note`: '3 armed traps, 0 of them in the trap hall'.

## Open
The two numbers still come from two sources (the kernel's manifest tally and the audit); the words only name which is which.

## Tests
`tests/test_bug764_traps_wording.py`; `tests/test_bug514_517_f32.py` and `tests/bp/test_bp_traps.py` updated to the new words.

## Live check
status on a fort with a bypass finding and armed traps reads 'traps 0 on the cheapest route, N of M armed in all'.
