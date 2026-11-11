# BUG-694 An unequipped squad stands down OFF DUTY, so it never fetches the kit DF assigned to it
Status: fixed (offline, live-untested)
Severity: high
Found: 2026-11-11, Run 16d i4 Trumpetrealms y458-y461 (FR-BUGS 'defense_short ... 26 freie Metall-Koerperruestungen', 'Squad B 4 Soldaten assigned ... ueber Stunden', '7-8 Soldaten bei SIEGE_END stood down unequipped'); Run 16a i1 Basementflew (worn 13-75 %)
Module: `lua/dfllm/military.lua` (`apply_squad`, `M.equip_pos`)

## Actual
kern.log (r16d4, 186200495-186258095): 'BREACH: squad C stands down: 0 of 1 soldiers hold a real weapon and wear body armor (< 30 %) ... (missing: weapon 1, body armor 1; free: 2 melee weapons, 6 body armors; the pieces lie free but are not worn ...)', and every 160 s 'N gear pieces DF kept assigned to a squad position that does not wear them given back (0 for a vacant position or none, 17-30 unfetched for 2400 ticks by the soldier of an occupied one)': the round-44 BUG-688 / 689 paths (vacant specs, wearable census) ran, the pieces were assigned and free, the soldiers never took them.

## Root cause
`apply_squad` (BUG-510): a squad under UNFIT_PCT fit in a SIEGE / BREACH had its order cleared and went `which = 'off'` (routine off, `{kind = 'clear'}`). An off-duty squad is civilians in DF: its soldiers do not fetch their uniform (the BUG-598 comment of `release_kit` says so), so 'unequipped -> stand down -> off duty -> never equipped' is a closed loop that only a PEACE refit could break; in a long BREACH / SIEGE (56 days at 30 t/s) it never did. BUG-688 / 689 (specs for occupied positions, the wearable census) could not help: the soldiers were not looking.

## Fix
`apply_squad`: the stand-down keeps no station against the enemy, but instead of clearing the order it gives an equip hold: `{kind = 'station', pos = refuge anchor}` (`M.equip_pos`: manifest refuge anchor, on the squad's walk group), routine unchanged (active), order signature `equip:x,y,z`; kern.log 'squad A is not equipped: equip hold at ... (an off-duty squad does not fetch its kit)'. `rt.station` / the KPI's station accounting still see it as standing down (`rt.sd`). Without a refuge anchor the old behaviour stays. Equipped (>= 30 % fit) -> the posture station as before.

## Tests
`tests/lua/test_bug692_inside_killer.lua` (equip hold, then posture station when equipped); `test_bug510_unfit.lua` and `test_intake.lua` adapted (stood down = equip hold at the refuge anchor).

## Live check
After the reload in a SIEGE / BREACH: the unequipped squads' order is `station` at the refuge anchor (the squads screen shows them stationed there), the 'unfetched for 2400 ticks by the soldier of an occupied one' count falls, worn % rises while free pieces exist. Open: not proven that DF fetches kit for a stationed squad at the refuge (the assumption is that an active squad does, an off-duty one does not); the anchor may be a tile far from the stock; no siege traffic test beyond the BUG-692 traffic test (bridge, gate and seal untouched, the stand-down itself is unchanged).
