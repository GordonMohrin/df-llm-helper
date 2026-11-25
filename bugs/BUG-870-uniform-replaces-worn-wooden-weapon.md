# BUG-870 squad.uniform kept a worn wooden weapon for good
Status: fixed (offline, live-untested)
Severity: medium
Found: Run 17 i3 Orangering: a soldier carries a wooden training spear while a real weapon is assigned, same position for ~6.8 game years (kern.log 'pos 0 hand wood:SPEAR_TRAINING spec any (assigned) (not fit)'); `squad.uniform` answered 'kept N worn specs'.
Module: `lua/dfllm/military.lua` (verb `squad.uniform`)

## Root cause
`filled_cats` counted a worn wooden weapon as a filled weapon slot, so `squad.uniform` kept it ('never takes off what a soldier wears') even when a real melee weapon was free or assigned.

## Fix
In `squad.uniform` (melee kinds, not xbow, not the weapon guard) a position whose soldier holds a wooden weapon counts as having no weapon when a free real melee weapon exists or one is assigned and usable (`M.assigned_real`): its weapon spec is replaced; the answer says `N soldiers hold a wooden weapon: the weapon spec is replaced by a real one`.

## Tests
`tests/lua/test_bug864_870_ruest.lua` (BUG-870).

## Live-Erwartung
i3: after `squad.uniform kind=melee squad A` the weapon spec of the position with the wooden spear is a real subtype (commands.log `act.squad_uniform ... weapon`). NOT promised: that the soldier then swaps the weapon in hand (DF needs the squad on duty; with BUG-864 the elite is on duty in winter too; the fake world models the spec state, not the pickup).
