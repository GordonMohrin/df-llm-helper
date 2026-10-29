# BUG-260 No butcher verb: breeding pairs had to be marked for slaughter by hand in a famine
Status: fixed (offline, live-untested)
Severity: medium (G4: famine with 4 tame animals the famine slaughter keeps as breeding pairs)
Found: 2026-10-29, Run 15 Inkintense (y373: 4 animals without slaughter flag; the game session marked turkey 26285 and duck 26450 by hand), fix6-food-drink
Module: `lua/dfllm/economy.lua` (verb `butcher.mark`), `lua/dfllm/act.lua` (`animal_slaughter`), `dfpilot/schema.py`, `lua/dfllm/util/contract.lua`

## Actual
T.slaughter keeps one adult female and one adult male per race; with two races of one pair each nothing was marked, and the
player had no verb (only the animal sheet by hand).

## Fix
New verb `butcher.mark {n?, race?, keep_pairs?}` (economy): the animal sheet's slaughter toggle (act.animal_slaughter) for n
(1-20, default 1) tame animals of census.a; pets, war and hunting animals never (act refuses war/hunting animals too); one
adult pair per race stays unless `keep_pairs:false` (the player's word); race = the creature id (TURKEY) or the race number;
the reply names the ids and says when no Butcher's shop stands. food_low/famine name `butcher.mark` as an option.

## Tests
`tests/lua/test_economy_food_run15.lua` `BUG-260: ...` (fails on 2b9c009).

## Live check
`dfllm cmd butcher.mark '{"n":1,"race":"TURKEY","keep_pairs":false}'` in a famine: the reply names the id, the animal sheet shows
it marked, a butcher takes the job at the Butcher's shop; `dfllm cmd butcher.mark '{}'` with only pairs is refused with the reason.
