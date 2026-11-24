# BUG-827 growth ladder's first step unreachable: the kernel's own squad setup gave the first melee squad 2 seats, the gate needs 3
Status: fixed (offline, live-untested)
Severity: high
Found: 2026-11-24, Run 17 i3 Orangering y375 (pop 29/30), i4 Girderroots (pop 22), i1 Diedplank (pop 15): `pop.hold "growth 30 (squad)"`, `ready.gh.need "first squad: 0 of 2 members hold a real weapon (need 3+, all armed)"`, `mil.cap {melee 2, sets 2, want 3}`, kern.log "melee filled to 2 of 3: 2 gear sets"
Module: `lua/dfllm/military.lua` (`M.targets`, `M.gear_fill`, new `M.armed_floor`)

## Actual
The ladder step 'squad' (readiness.growth_ladder) needs `growth.armed_min` (3) members in the first melee squad, all with a real weapon. At pop 30 `M.targets` makes 15 % = 5 soldiers, 2 for the crossbows, and split the other 3 evenly: squad A 2, B 1 (reproduced by a test with the live numbers: `{A=2, B=1, C=2}`). `M.gear_fill` then capped the melee squads at `max(sets, GEAR_FLOOR 2)`. So the gate could never be met by what the kernel builds, whatever weapons lay in stock: a deadlock (pop held at 30 until 3 armed in squad A, squad A sized from the population the cap holds). i2 (pop 42, 8 soldiers, A 3) was the only fort where the size was reachable.

## Fix
`M.armed_floor(K, adults)`: `growth.armed_min` when the growth ladder is on and the fort has at least 2/3 of `growth.base` adults (20 at base 30), else 0. `M.targets`: the soldier total is at least armed_min + 2 crossbows (never more than the adults), and the first melee squad takes `max(even share, armed_floor)` seats before the second one. `M.gear_fill`: the first melee squad keeps armed_floor seats beyond the gear floor. The condition itself is NOT relaxed: a seat arms nobody (fail closed); the squad still needs `armed_min` real weapons in hand (or backed by the census). Growth off, or a fort below 2/3 of the base cap: unchanged split.

## Open
A fort without a real melee weapon (i3: census g_weapon 0, "weapon 0/3 no bars"; i4 "weapon 1/2 no fuel"; i1 "weapon 0/2 no bars") still holds at 30 until the economy forges 3 weapons: that is a metal/fuel supply question (economy), not the squad setup. Why a member holds no weapon: BUG-830 (i3 confirmed, i2 not proven; logged per soldier since).

## Tests
`tests/lua/test_bug827_first_squad_seats.lua` (reproduces `{A=2,B=1,C=2}` before the fix; growth off and a pop-12 fort unchanged).

## Live-Erwartung
Partial: this fix only removes the seat ceiling ("of 2"). It does NOT arm anybody and does not promise that the cap lifts: why a member holds no weapon is BUG-830.
1. On i3/i4/i1 after a kernel reload and once the fort has 20+ adults: `mil.kit.sq` (state) and the `ready.gh.need` text read "first squad: x of 3+" (not "of 2" / "of 1") within one game day of the next target pass; `inspect military` shows `A 3`.
2. kern.log no longer prints "melee filled to 2 of 3" while body armor is 2: the fill for squad A is at least 3.
3. As long as a member has no weapon the halt stays "squad" (fail closed, as designed); what lacks is named per soldier in kern.log (BUG-830).
4. i3 evidence (state.a.json 18:26): `gh.need "2 of 2 members hold a real weapon (need 3+)"`, `mil.cap {melee 2, sets 2, want 3}`, kit weapon 5, free weapon 19: both seated members armed, the third seat is what is missing, and kern.log shows "melee filled to 2 of 3: 2 gear sets (body armor 2, melee weapons 15-23)" from the pre-fix kernel. After the reload `fill` for A is 3, so `fill()` recruits one healthy citizen (`act.squad_add`; the same call succeeded on i3 at 151244769/151359969). That the third member is ARMED is not proven (reserved/out-of-reach gear: BUG-830 item 4).
