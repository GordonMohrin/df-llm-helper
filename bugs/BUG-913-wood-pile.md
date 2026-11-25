# BUG-913 No wood stockpile: the kernel places `dfllm-wood` beside the Carpenter's workshop
Status: fixed (offline, live-untested)
Severity: medium
Found: Run 17 i1 Diedplank y423: `registering piles by tag` lists no wood pile, the fresh logs of the restarted felling lay 50 tiles from the carpenters; DF's haulers carry a loose log only to a stockpile that takes wood.
Module: `lua/dfllm/economy.lua` (`T.woodpile`, `M.WOODPILE`, task list `FULL`), `lua/dfllm/act.lua` (`I.wood_pile`), `lua/dfllm/util/contract.lua`, `dfpilot/schema.py` (ACT), `dfpilot/session.py` (QUIET_DECISIONS)

## Fix
The mechanism of `dfllm-tools` (BUG-053): `T.woodpile` (daily, PEACE / RECOVERY) places a 3x2 wood stockpile `dfllm-wood` (act.wood_pile: quickfort place key `w`, the cell `w{name=dfllm-wood}(3x2)`) on revealed plain floor within 12 tiles of the first built Carpenter's workshop that has a free site (`M.pile_site`: citizens' walk group, off the attack path, no building, no pending designation; nothing is dug). Conditions: no stockpile of any owner takes wood (`settings.flags.wood`), a built Carpenter's workshop stands, and wood is wanted (near logs below floor + wood on order + margin, or free logs lie far from every shop). One try per 28 days, a try that found no site again after 1 day. A pile that cannot be placed (no site, quickfort refusal) raises once per 28 days DECISION_NEEDED `wood_pile` (quiet: it does not wake the player) with the one existing command that helps meanwhile: `dfllm cmd trade.want '{"add":["wood"]}'`. A bp template for a dug storeroom is out of this round. `economy.wood.pile=false` switches the task off.

## Tests
`tests/lua/test_bug910_915_holz.lua` (placed beside the shop, once; no site and a refusal: the decision with the command, once; a player's wood pile: none; no Carpenter: none), `tests/test_bug910_915_holz.py` (act owner, quiet decision).

## Live-Erwartung
i1: within the day after the reload kern.log 'wood pile: dfllm-wood 3x2 at x,y,z beside the Carpenter's workshop'; `inspect` / `registering piles by tag` lists `dfllm-wood`; felled logs are hauled in (the status line's `woodf` falls, `wood` rises). Where no floor is free: DECISION_NEEDED wood_pile in events.jsonl with the `trade.want` command. Not promised: how fast haulers fill it (stockpile priority is DF's).
