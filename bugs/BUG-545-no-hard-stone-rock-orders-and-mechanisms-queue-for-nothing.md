# BUG-545 No non-economic hard stone: rock orders, mechanisms and stone traps queue for nothing and nobody is told
Status: fixed (offline, live-untested); open: the game-side cause is inferred
Severity: high (the refuge levers, traps and rock furniture never get made; years of silent loops)
Found: 2026-11-06, Run 16d i4 Trumpetrealms y404 (`runs/run-16d/FR-BUGS.md` line 387; `E:/DF-test4/dfllm-runtime/r16d4-trumpetrealms-site97/kern.1.log` 21 lines like "order 721 ConstructCoffin x2: "Needs non-economic hard stone boulders", 25 free stone for 54 in rock orders: re-entered in wood"), Run 16a i1 Basementflew (BUG-544)
Module: `lua/dfllm/economy.lua` (`stone_free`, `cancel`, `M.hard_cancel`, `M.hard_report`, `M.rock_dig`), `dfpilot/wake.py`

## Actual
Mudstone fort, `inspect census` boulders 101, rock 16-30, rock_bad 14: the census says 20-25 free stone, DF's masons, mechanics and stone-trap loaders cancel every job with "Needs non-economic hard stone boulders" from several dwarves, for years. economy queued ConstructMechanisms and rock orders on `free > 0`, the refuge levers' link jobs waited on mechanisms nobody could make, `trade.want` stone / mechanism was not asked (only for `free == 0`), and nothing reached the player as a decision.

## Root cause
`stone_free` is a census estimate (free boulders minus ore, flux, economic and soft stone, minus the mood floor); DF's own rule (a boulder that is non-economic and ITEMS_HARD, reachable, unclaimed) is not fully readable, so `free > 0` while DF refuses. `economy.cancel` used the "Needs ..." text only to re-enter or drop single orders (`no_rock`, `needs_cancel`); the repeated proof was never turned into a stone state, a report or a caravan request. `M.supply_wants` and `plan_mech` act on `free == 0` only.

## Fix
DF's own cancel is the proof: `M.hard_cancel` (from `cancel`, text "non-economic" / "hard stone") counts them; `M.HARD.n` (3) within `window_days` (7) make `M.hard_denied` true: `stone_free` is 0 for `hold_days` (14) after the last cancel, until the census shows more than `new` (5) boulders beyond the count at that cancel. So no rock order is queued for it, `plan_mech` answers 'no stone', `supply_wants` asks the caravans for mechanisms and stone. `M.hard_report` raises DECISION_NEEDED `no_hard_stone` (A, cadence 28 days or a changed cause): `cause` `denied` (the census counts usable boulders, DF refuses) or `none` (boulders and none usable: economic, soft, ore / flux, out of reach), the counts, "wood serves doors, chests, beds" and `cmds` `trade.want {"add":["stone","mechanism"]}`, `plan propose` (a dig to hard stone), `inspect workload`. `M.rock_dig` reports the census-only case (>= 10 boulders, none usable, stone wanted). Wake line `no_hard_stone_hint`.

## Tests
`tests/lua/test_bug544_547_stone_manager.lua` (denied after 3 cancels, once, lifted by new boulders and by hold_days; census-only `none`), `tests/test_bug544_547_f35.py` (wake line).

## Live check
After three "Needs non-economic hard stone" cancels kern.log and the events carry the `no_hard_stone` question; `inspect workload` stone free 0; no further rock orders; the trade ledger asks for stone and mechanism.
Open: which stone DF really refuses is inferred from its cancels; a mood or a claimed item can also cancel with that text (the hold ends after 14 days or with new stone).
