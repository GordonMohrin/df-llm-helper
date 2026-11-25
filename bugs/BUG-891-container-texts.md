# BUG-891 Ladder and brew stall texts said empty barrels, the fort had none usable
Status: fixed (offline, live-untested)
Severity: low
Found: Run 17 i1 / i2: ladder 'no empty barrel or pot' only at 0 empty; 'drink low (... N empty barrels)', 'brewing stalled ... N empty barrels' with N = the census total (27-42) while 0 were usable.
Module: `lua/dfllm/economy.lua` (brew stall msg, `brew_cause`, ladder `put('barrels', ...)`, DECISION `q`, `stock.contw`), `dfpilot/brief.py`, `dfpilot/schema.py`, `lua/dfllm/util/contract.lua`

## Root cause
The texts read `barrels_empty` while the verdicts read `cont_free`: two numbers for one fact.

## Fix
All texts use `M.cont_text` / `M.cont_words` (BUG-887); the ladder names 'no usable empty barrel or pot: N usable of M empty (reasons)' when empties exist but none is usable; state `stock.contw` (str <= 90) and the status line carry the reasons; contract, schema, CONTRACTS.md updated.

## Tests
`tests/lua/test_bug887_891_fass.lua` (stall verdict text), `tests/test_bug887_891_fass.py` (status), `tests/test_neu4_cancel.py` unchanged and green.

## Live-Erwartung
The player sees the same usable-of-empty number in status, ladder, drink decision and stall line. NOT promised: a change in drink days by itself.
