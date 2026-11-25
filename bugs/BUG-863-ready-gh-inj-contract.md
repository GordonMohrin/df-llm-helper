# BUG-863 `ready.gh.inj` (BUG-858) was no contract key: the whole `ready` part of state.json was dropped while a member was unfit
Status: fixed (offline, live-untested)
Severity: medium
Found: while testing BUG-860 offline (contract check of the test kernel: `state.json invalid: $.ready.gh.inj: unknown key (dropped ready)`).
Module: `lua/dfllm/util/contract.lua` (state `ready.gh`), `dfpilot/schema.py`

## Root cause
BUG-858 put `inj` into `rt.gh` (the halt object served as `ready.gh`) but never into the state contract. A fort whose growth halt was `squad` with an unarmed AND unfit member dropped the complete `ready` section from state.json (the contract guard drops an invalid section): the ladder, `status` and the player read no readiness at all.

## Fix
`gh` gets the optional `inj` (NAT) in `contract.lua` and `schema.py` (appendix regenerated). BUG-860 keeps `inj` as the number of unfit members of the first squad.

## Tests
`tests/lua/test_bug860_squad_ready.lua` (the first test reads `W.state()` with `inj` set; before the fix the state frame raised the contract violation), `tests/test_neu1_wachstum.py::test_event_and_state_contracts`.

## Live-Erwartung
On a fort with the growth halt `squad` and an unfit member: `state ready` is present (`ready.gh.inj` 1) and the status line shows `growth 30 (squad, 1 injured)`. If `ready` was missing from state.json while a member was hurt, it is back (PROMISED).
