# BUG-463 A group of 33-40 goblins stayed 'harmless (+39 more)' for 100+ days, no sortie offer
Status: fixed (offline, live-untested); BUG-452 was the fix, this verifies the INVASION path and tightens the group count
Severity: high
Found: 2026-11-05, Run 16a i1 Syrupobeyed y387 (FR-BUGS: Kernel nannte Goblins harmless)
Module: `lua/dfllm/reflex.lua` (`cause_scan`)

## Actual
The brief read `cause ... size 6355, harmless (+39 more)` and the lockdown (arrival:invasion) held 100-125 days at 30 t/s with no sortie offer.

## Root cause / verification
The log is the pre-BUG-452 code (round 28 fixed it: `hl` only for a lone picture, `overlimit_step` -> DECISION_NEEDED `lockdown_long`).
Checked against the `arrival:invasion` path (the INVASION announcement, 33 small goblins, also with 32 of them cleared as expired far): both
give `hl 0`, `hw 'group of 33'` and one `lockdown_long` with the `squad.sortie` command past `confine.max_days`. One hole was left: `n` counted
only hostiles outside the cleared (far) set, so one counted unit of harmless size among many cleared ones could still read as a lone
picture. `cause_scan` now counts the hostiles in sight (`census.h.vis`) as well, so a group never prints harmless.

## Tests
`tests/lua/test_m3_lone.lua` (+1: the INVASION lockdown with 33 goblins, with and without 32 cleared). It also passes on the BUG-452 code
(the cleared ones count again as soon as another hostile is in sight): it is the regression guard for the path.

## Live check
`dfllm status` cause `dangerous (group of N)` for an invasion, DECISION_NEEDED `lockdown_long` after `confine.max_days`. Open: a squad has to
be left to send (the decision says 'no squad can go' otherwise) and the 30 t/s clock (arbiter) is unchanged.
