# BUG-417 STRANDED "no rescue" offers bridges only: no decision for food, none when a bridge way is refused
Status: fixed (offline, live-untested); open: the kernel has no recall order or path designation of its own
Severity: high (citizens starved 100+ tiles out of the fort)
Found: 2026-11-05, Run 16d y389 (events #5461/#5472), Run 16c y377 (#1818); main b4087f4
Module: `lua/dfllm/siege.lua` (dry_decision, rescue_step), `dfpilot/wake.py`

## Actual
Two citizens 100+ tiles from the fort at the only water zone, hunger 72,249 of 75,000: STRANDED "no rescue (no raised bridge leads to food)".
BUG-391 raised a decision only for drink without a bridge; food got nothing, and a refused bridge rescue (outside not sealed, hostile)
with citizens near death got nothing either.

## Fix
- `dry_decision` serves food too: DECISION_NEEDED `stranded_food` (class A, urgent in wake) with who/where/hunger and commands
  (`inspect what=reach`, `inspect what=items`, `bp sites farms surface=1 --near <pos> --within 20 --fresh`); drink keeps `stranded_drink`
  (+ `need`). Again only for news (cadence: more citizens or another need).
- It is raised when no bridge way exists, and also when a way exists but the rescue is refused while thirst >= 50,000 or hunger >= 75,000
  (the fight marks, death in about two days).
- Not done: an automatic recall / path designation (needs a live test of a safe order); the decision names the options.

## Tests
`tests/lua/test_stranded.lua` (BUG-417 food decision once; BUG-391 drink unchanged).

## Live check
A citizen group outside with hunger over 50,000 and no raised bridge: `events --cls A` shows DECISION_NEEDED `stranded_food` with the commands,
once per set; wake treats it as urgent.
