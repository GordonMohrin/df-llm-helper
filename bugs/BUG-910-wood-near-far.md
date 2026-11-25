# BUG-910 Wood counts as stock only near a Carpenter's workshop or wood pile (census split near / far)
Status: fixed (offline, live-untested)
Severity: high (wood orders and the autochop target read a count of logs no worker fetches)
Found: Run 17 i2 Whirledrampart (25.11.2026): the order `MakeBarrel x40 wood` (6936) built nothing in 1.5 game years; gamelog `cancels Make wooden barrel: Needs logs` and `Make charcoal: Needs logs`, while the census said wood 192 and `why items:logs --raw` 202 'free as DF sees it'. The free logs lay at the map edge (15,25,143), about 97 tiles west, 128 north and 6 levels above the Carpenter's (111-113,152-154,137). i1 Diedplank: the few fresh logs lay 50 tiles from the carpenters. Diagnosis `leitung/neu10/DIAGNOSE-HOLZ-2026-11-25.md` (the check: DF cannot use these logs; why is not proven).
Module: `lua/dfllm/economy.lua` (`M.wood_anchors`, `M.wood_near`, `classify` WOOD branch l.1310, `M.WOOD_NEAR_D`, `new_acc`, state block `stock.woodf`), `dfpilot/brief.py` (`_wood_text`), `dfpilot/schema.py`, `lua/dfllm/util/contract.lua`

## Cause
`economy.lua` `classify` (WOOD branch) counted every free log on the citizens' walk group as `wood`, wherever it lay. Walk group is no proof of a short trip: DF's job picker cancels with 'Needs logs' for items it will not use. Nothing compared the stock with the position of the shops.

## Fix
The census splits the free logs. `wood` = near: in a kernel stockpile (name `dfllm-...`), or within `wood.near_d` (default 40) of the nearest built Carpenter's workshop or of a stockpile that takes wood (any owner); distance `max(|dx|, |dy|) + 3 |dz|` to the building's box (the weighting economy already uses for the wall-site score in `economy.lua` near l.10610: `max(|dx|,|dy|) + 3*|dz|`; no pathfinding, no new reach helper). `wood_dist` = every other free log (counted apart, inside `woodt`, shown as `stock.woodf`). Without a Carpenter's workshop and without a wood pile there is no anchor: every free log is near (as before). Orders, floors, `wood_left` and the mood floor read `wood` (near only). `M.treeless`, the `nowood` clock and `dead_wood_barrel` (BUG-878) count `wood + wood_dist` (a far log is still a log: no order is dropped and no fort called treeless because of it). `M.wood_cancel` names far logs. Status line: ` wood N usable (F far, M loose unusable; K built in)`.

## Tests
`tests/lua/test_bug910_915_holz.lua` (near / far split with the i2 map-edge numbers, the 39 / 41 tile and 13 / 14 level edges, kernel pile, no anchor, any wood pile), `tests/test_bug910_915_holz.py` (status line); `test_bug855_wood.lua`, `test_neu4_cancel.lua` unchanged and green.

## Live-Erwartung
i2: state `stock.wood` falls to the logs near the shop (about 0 where all lie at the map edge) and `stock.woodf` shows about 190; the brief status line reads `wood 0 usable (190 far, ...)`; kern.log `economy: DF cancels ...` names '190 free logs lie farther than 40 tiles from every Carpenter workshop and wood pile'. i1: `woodf` shows the logs 50 tiles away. Not promised: that DF fetches logs 30-40 tiles away (the distance is the setting `economy.wood.near_d`, not a measurement of DF's own limit).
