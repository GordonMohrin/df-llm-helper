# BUG-599 The training policy puts melee positions on wooden weapons the fort does not hold
Status: fixed (offline, live-untested)
Severity: high (squads A and B "weapon 0, wood 0" in PEACE beside 12-27 free melee weapons; fit 0 for years)
Found: 2026-11-09, Run 16a i1 Basementflew y441-y447 (`A 5 (fit 0, weapon 0, wood 0, armor 2), B 2 (fit 0, weapon 0, wood 0)`, kern.log `squad A: 5 positions changed to the training weapon of their class` every few days), Run 16b i2 Brotherarrow y413 (gear 0/12, weapon 0/4 beside 27 free weapons)
Module: `lua/dfllm/military.lua` (`M.train_pool`, `M.train_apply`, `ensure_weapons`)

## Actual
`inspect what=military` showed `weapon 0, wood 0` for the melee squads: no weapon in hand, not even a wooden one, while the fort held real melee weapons.

## Root cause
`ensure_weapons` (FR-89) gives every occupied melee position of a squad on the training policy (the default since FR-100) the wooden training weapon of its class in PEACE and DRILL, whatever the fort holds. The carpenters make those from wood (`economy.plan_training`: need + spare, a Carpenters workshop, wood); a soil fort without wood or without the workshop never gets one, so the positions stood with an empty hand for as long as PEACE lasted, and the real weapons lay free (every alert flipped the specs back to real weapons, hence the repeated `changed to the training weapon` lines).

## Fix
`M.train_pool(K, skip)` = the training weapons of the fort a position can still be given (free ones and the ones soldiers carry, none in a forbidden bin or on another walk group) minus the wooden specs of the other squads. `M.train_apply(K, s, only, pool)` gives a position a wooden spec only while the pool holds that weapon; a position that holds a wooden spec with nothing behind it is `unfilled` and `ensure_weapons` gives it a real weapon again (the guarded plan or individual choice, as in an alert); positions left on a real weapon for want of a wooden one are `nowood`; kern.log says `N positions keep a real weapon: the fort holds no free training weapon for them`. The player's `squad.uniform kind=training` is unchanged (no pool); economy still orders the wooden weapons (`training_need`), the positions switch to them as they appear.

## Tests
`tests/lua/test_bug598_599_kit_reach.lua` (no wooden weapon: three AXE-class positions keep real weapons, one wooden axe appears: one wooden spec; two wooden specs, one wooden axe: the second position gets a real weapon back; the pool minus the claims), `tests/lua/test_fr100_kit.lua` (its world now stocks 12 wooden weapons of each class)

## Live check
`inspect what=military` in PEACE: `weapon` equals `n` for the melee squads (`wood` only as many as wooden weapons exist, `training_free` the rest); kern.log names `keep a real weapon` while the carpenters have not made the wooden ones.

## Open
Squad `fit` counts a real weapon in hand, so in PEACE the squads on wooden weapons still read fit-low by definition (FR-100); the stand-down check (SIEGE / BREACH) already puts real weapons back. Whether the missing wooden weapons were the only cause of `weapon 0` in the three forts is inferred from `wood 0` beside the repeated `changed to the training weapon` lines.
