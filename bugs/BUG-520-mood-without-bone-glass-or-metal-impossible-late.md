# BUG-520 Strange moods die for bone, glass and metal bars the fort cannot make, and the kernel says so only at the deadline
Status: fixed (offline, live-untested)
Severity: high (a mood death each; five failed moods in one fort)
Found: 2026-11-06, Run 16d i4 Trumpetrealms y383 (Fey mood `bone x1`, `butcher.mark` found nothing to slaughter), Run 16a y375/y376 (`runs/run-16a/FR-BUGS.md` "BUG Mood braucht Knochen, kein Weg", "FR MOOD glass in Soil-Fort ohne Stein", "BUG Geheimnis-Mood braucht Metallbarren ohne Erz/Handelsmetall"; read only). Earlier: BUG-456 (trade.want bone), BUG-498 (adult first)
Module: `lua/dfllm/economy.lua` (`M.mood_hint`, `M.route`), `lua/dfllm/care.lua` (`route_note`, `M.mood_deadline`), `lua/dfllm/reserve.lua` (`R.BUY`)

## Actual
A mood for bone has three ways: slaughter (BUG-498 marks the last adult, pets and war animals never), hunt, trade. With no tame animal other than pets / war animals and no hunter, the first is empty and `butcher.mark` says `no animal to mark`; the mood's route said `hunt` and the caravans were never asked, because a bone need had no trade token (`R.BUY` knew cloth, thread, leather, gems, bars, stone, wood). Glass and metal were the same story: a soil fort without stone cannot build the glass furnace; no ore, nothing marked for melting and no smelter means no bars. The kernel said so at the deadline (MOOD_CRITICAL `none in the fort`), too late to act.

## Root cause
`reserve.lua R.BUY` had no `bone`; `economy.lua route_of` answered `true, 'hunt'` for bone and shell whatever the fort held; nothing judged whether a class could be made at all.

## Fix
- `R.BUY.bone = 'bone'` (trade.lua has the kind since BUG-456): a bone need goes to the caravans' want list with the other mood tokens.
- `economy.mood_hint(K, cls)` returns text and `impossible`: bone / shell / leather with no slaughterable animal (`slaughter_pick`, pets and war / hunting animals never) and no hunter who can shoot (bow / crossbow and bolts) -> `no animal can be slaughtered (N tame: pets, war and hunting animals stay); no hunter can shoot`, impossible; glass with no furnace and no stone (`stone_zero`) -> impossible, the way `trade.want glass` or a quarry first; bars with no ore, nothing marked for melting and no smelter -> `trade.want bar:iron`, an explore dig, or mark metal items for melting (`economy.route bars` names the melt route too).
- care `route_note` (MOOD_RISK `route`, the mood's start) leads with `IMPOSSIBLE <class>: ...`; `mood_deadline` (DECISION_NEEDED) puts the impossible class first in `q` and lists it in `d.imp`; the ready `trade.want add` command stays.

## Tests
`tests/lua/test_bug520_mood_impossible.lua` (5: pets / war animals only, hunting, surplus adult, bars / glass, the bone token, mood_deadline `imp`).

## Live check
A bone / glass / bars mood in a fort without the means: MOOD_RISK `route` begins `IMPOSSIBLE bone: no animal can be slaughtered (...)`; the next caravan want list holds `bone`.
Open: nothing melts items by itself (the kernel marks no metal for melting); `mood_hint` does not look at items the player could build a furnace from; a caravan that carries no bone, glass or metal (Run 16a: the only civilization carries none) still cannot help.
