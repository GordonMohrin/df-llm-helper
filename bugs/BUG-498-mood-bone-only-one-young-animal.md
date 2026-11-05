# BUG-498 A strange mood needs bone: one young animal marked, twelve stay (three mood deaths)
Status: fixed (offline, live-untested)
Severity: high (a dwarf in a strange mood dies or goes insane without his bone)
Found: 2026-11-05, Run 16d i4 Trumpetrealms y383 (FR-BUGS "Strange mood braucht bone": Fey Tobul, 'bone x1 none in the fort', `butcher.mark` took one young cavy, the census showed 12 animals the kernel did not slaughter, the mood ran out, 3 mood deaths in the run)
Module: `lua/dfllm/economy.lua` (`M.slaughter_pick`, `T.slaughter`, `mood_animal_need`, verb `butcher.mark`), `dfpilot/schema.py` / `lua/dfllm/util/contract.lua` (ANIMAL_MARKED)

## Actual
`slaughter_pick` keeps one adult female and one adult male per race and returns the rest in id order; the lowest id is often a young animal (little or no bone). With every race reduced to its breeding pair there was nothing to mark at all: the mood waited for a bone that no rule allowed. The mood path knew bone and leather, not shell, and said nothing in an event.

## Fix
- `slaughter_pick` option `adult_first`: candidates are ordered adults first, then the race with most animals, then id (the breeding stock stays as long as a surplus exists). The mood path of `T.slaughter` and the verb `butcher.mark` use it.
- A mood that needs bone, shell or leather with none in stock and no surplus animal: the second pick keeps no pair (keep 0), an adult of the largest race, one at a time (every `mood_days`). Pets and war / hunting animals are never marked (census flags, `act.animal_slaughter`).
- New event ANIMAL_MARKED (B, economy; `need`, `animal`, `race`, `adult`, `last`): msg 'mood needs bone (none in the fort): adult CAVY 123 marked for slaughter (the last of its breeding pair: pets and war animals stay)'. CONTRACTS.md row, schema.py, contract.lua.

## Tests
`tests/lua/test_economy_food.lua` (a mood needs bone: the surplus adult first; only pairs left: one adult, never the pet or the war animal, ANIMAL_MARKED), `tests/lua/test_bug497_500_material.lua` (`slaughter_pick adult_first`).

## Live check
A fort with a Butchers' shop, tame animals only as breeding pairs and a mood that misses bone: kern.log 'mood needs bone: animal N marked for slaughter' and the event ANIMAL_MARKED within `mood_days`; the butcher makes the bones.
