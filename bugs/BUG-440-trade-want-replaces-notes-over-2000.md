# BUG-440 trade.want replaces the wish list; propose writes notes over 2000 bytes
Status: fixed (offline, live-untested)
Severity: medium (wrong result)
Found: 2026-11-05, Run 16a i1 Syrupobeyed y372 and y376 (`runs/run-16a/FR-BUGS.md` "BUG plan propose schreibt notes > 2000 Bytes", "Fey-Stimmung ... trade.want bone ersetzte die Wunschliste")
Module: `lua/dfllm/trade.lua`, `lua/dfllm/care.lua`, `lua/dfllm/economy.lua`, `dfpilot/plan.py`, `dfpilot/schema.py`

## Actual
- `trade.want '{"want":["bone"]}'` replaced the list (bar:iron, anvil, cloth gone); the kernel's own suggested commands (mood deadline, no_water) did the same. `bone` is no trade token and was dropped silently.
- `plan propose` on a fort without sites wrote `notes` of 2110 bytes (nine BUG-370 lines) and its own check said `ERROR $.notes: longer than 2000 bytes`.

## Fix
- `trade.want` takes `add` (in front of the current list), `remove`, `sell_add`, `sell_remove` besides the replacing `want` / `sell`; the current list is the override's, else the plan's, else the default; at most 40, none
  doubled. The reply names `ignored` tokens (no item type). The kernel's suggested commands (`care.lua` mood deadline, `economy.lua` no_water) use `add`. schema `inbox.args.trade.want`, CONTRACTS.md, RULES.md, appendix.
- `plan.cap_notes` cuts the notes at the last note boundary under 1900 bytes with a closing "BUG-440: notes cut (N bytes written)", called in propose (CLI, auto, next-phase candidate) and the brief's check;
  `fit_placeable` writes more than 3 BUG-370 lines as one summary line (the CLI still lists each).

## Tests
`tests/lua/test_bug440_trade_add.lua` (3), `tests/test_bug437_440_f27.py` (schema, kernel suggestions, `cap_notes`, a capped draft passes `plan check`).

## Live check
`dfllm cmd trade.want '{"add":["stone"]}'` keeps the other tokens; `'{"add":["bone"]}'` answers `ignored (no item type): bone`.
