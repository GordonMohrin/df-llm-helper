# BUG-144 The lockdown cause says 'dangerous' without the rule, 'restrained' reads a field DF 53.16 lacks, the benign line is cut from the status, the drill hint offers a refused command
Status: fixed in the fix-live-siege commit (offline, live-untested)
Severity: medium (wrong report)
Found: 2026-10-28, live test instance i3 (E:/DF-test3, region2-site90 Trussroads y717), workflow wf_190bd773-8de, confirmed by its verifier
Module: lua/dfllm/reflex.lua (`M.danger_why`), lua/dfllm/sense.lua (`benign_why`), dfpilot/brief.py, schema/contract

## Actual
- `cause inv 41873 TROGLODYTE ..., size 5767, dangerous`: the reason (LARGE_PREDATOR) was not shown.
- `u.flags2.restrained` does not exist in DF 53.16 (`Cannot read field unit_flags2.restrained`); pcall hid it.
- `not counted as hostile (id:why)` had rank 3 and the 9-line status cut it, while CHANGELOG and HANDOVER point to `dfllm status`.
- Brief: `drill never (auto: no_inner; run dfllm cmd drill) [1 refused: build fortcore stage 2/3 first]`, and `dfllm cmd drill` is refused.

## Fix
- `reflex.danger_why(e, c)` names the rule (`great danger`, `undead`, `building destroyer`, `large predator`, `flier/trap avoider`,
  `size N > M`, `size unknown`); state `alarm.by.hw` (str 24); brief `dangerous (large predator)`.
- sense reads `flags1.chained` only (a caged unit is in census.h.caged already, as before); k_mock drops the fake `flags2.restrained`.
- the benign line has rank 2 while a lockdown or a lone intruder's clock holds.
- with `dhold` no_outer/no_inner/no bridges or `dref` the hint is `build fortcore stage 2/3 first`, never `run dfllm cmd drill`.

## Not a bug (verifier)
The `dangerous` verdict for the troglodyte was right (LARGE_PREDATOR by design); the per-race raw cache only matters for edited raws.

## Tests
`tests/lua/test_bug143_145_reflex.lua` (by.hw, danger_why), `tests/test_live_siege_i3.py` (brief lines, the source rule for sense).
