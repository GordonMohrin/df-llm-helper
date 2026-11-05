# BUG-459 The famine decision offered commands that cannot work
Status: fixed (offline, live-untested)
Severity: high (the player had nothing to send while food fell 7 -> 4 -> 1 day)
Found: 2026-11-05, Run 16d i4 Orbblock y377 autumn d10 (`runs/run-16d/FR-BUGS.md` "Hungersnot ohne Handlungsoption")
Module: `lua/dfllm/economy.lua` (`food_more`), `dfpilot/wake.py` (`workable_food_cmds`, `food_hint`, `next_hint`, `wake_line`)

## Actual
DECISION_NEEDED `famine` cmds: `bp.place farms surface=1` -> 0 ranked even with --fresh (`bp sites farms`: farm rooms open from dug Z4 floor, the core stood); `butcher.mark` -> `no animal to mark (7 tame ... stay)`; fishing on frozen water (676 frozen); cooking `no cook ingredient (156 inedible PEAR:LEAF)`. 18 of 21 adults idle.

## Root causes
1. `economy.lua M.food_more` offered `butcher.mark` whenever any tame animal stood (`census.a.n > 0`); the verb keeps pets, war animals, marked ones and one breeding pair per race, so it often marks nothing.
2. `M.food_block` offered the `farms` command whenever the tiles were short (`fs.need > fs.tiles`) without a site: the kernel cannot rank sites, and the CLI side never re-checked.
3. The decision carried no option that always works: a fort with no butcher, no farm site and frozen water had none (the caravans' food and seeds were the kernel's own `auto`, never a command).

## Fix
- `food_more`: `butcher.mark` only while `slaughter_pick` would mark an animal; `trade.want add food, seeds` is always offered (first): the caravans bring what the list names.
- `wake.workable_food_cmds` (used by `food_hint`, so by the wake line's `next:`): the farm command is dropped when the newest sites snapshot has no farm site (`plan.farm_site(urgent=True)`, the surface plots included, BUG-460) and the hint says `[not offered: bp.place farms: no farm site ...]`; a decision left with no `trade.want` gets it. `next_hint` / `wake_line` take the save dir.
- Frozen water and inedible cooking stay blockers in the text (no command pretends to fix them).

## Tests
`tests/test_bug458_461_f28d.py` (dropped farm command, the trade fallback, a site that stands, unknown, the command passes the schema), `tests/lua/test_economy_*.lua` (the option lists).

## Live check
A famine in a fort with no farm site and no markable animal: the wake line's `next:` names `trade.want` and says why the farm command is not offered; `dfllm events --cls A` lists `trade.want` first in `d.cmds`.
