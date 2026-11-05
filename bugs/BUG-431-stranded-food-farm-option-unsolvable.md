# BUG-431 DECISION stranded_food offers `bp sites farms surface=1` that finds nothing
Status: fixed (offline, live-untested)
Severity: high (3 citizens starved on a cut-off walk group with no option on offer)
Found: 2026-11-05, Run 16d i4 Mazelanterns y399 (`runs/run-16d/FR-BUGS.md`, "stranded_food-Entscheid unloesbar"), main 9e756ea
Module: `lua/dfllm/siege.lua` (`dry_decision`, `food_spots`)

## Actual
DECISION_NEEDED `stranded_food` (3 citizens on walk group 3394 at 164,179,138, hunger 69,000) recommended `dfllm bp sites farms surface=1 --near 164,179,138 --within 20 --fresh`; the
answer after 60 s: "farms: no valid site on the snapshot". STRANDED repeated for the next group; the player had no option.

## Root cause
`siege.lua dry_decision` always appended the surface-farm command. A surface farm needs a revealed soil floor on the stranded group itself (`sites._surface_farms`); 100+ tiles out
on stone or in a cavern there is none, and surface farms are off by default since BUG-413. The kernel never looked where they stand.

## Fix
`food_spots` reads the revealed tiles on THEIR walk group within `M.FOOD_R` (10) tiles, nearest first (`snapshot.tile`: a soil floor with nothing on it; a tile beside water >= 4/7):
- soil found: `bp sites farms surface=1 --near <that soil tile> --within 12 --fresh`;
- water found: `cmd zone.place '{"type":"fishing","bbox":[around the shore tile]}'` (fish is food);
- always: `inspect what=reach`, `inspect what=items`;
- neither: only the two reads, and the question says "no soil floor and no water on their side within 10 tiles ... Open a way to the fort" (a template that digs a free path does not exist yet).
A tile reader that fails leaves the old question text and offers no guess.

## Tests
`tests/lua/test_stranded.lua`: BUG-417 (bare dry field: no farm / zone offered, the question says why), BUG-431 soil on the group, water beside it, soil behind a wall not offered
(`seal_world` draws `s` soil and `~` water now).

## Live check
A stranded group with a soil floor or shore within 10 tiles: the decision lists exactly that command and it finds a site; without: the reads only.
