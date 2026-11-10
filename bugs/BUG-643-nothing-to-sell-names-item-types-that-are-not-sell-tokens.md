# BUG-643 `nothing_to_sell` names DF item types (BACKPACK, FLASK, PANTS), not the sell tokens that take them
Status: fixed (offline, live-untested)
Severity: low (the trade stood still until the player found the tokens by hand, every caravan)
Found: 2026-11-10, Run 16a i1 Basementflew y457 (`kind=100(BACKPACK22+FLASK21+PANTS11)`, "BACKPACK / FLASK are no sell tokens (trade.lua L.KINDS)", pants / shoes / gloves added by hand)
Module: `lua/dfllm/trade.lua` (`L.KINDS`, `L.sell_name`, `step_mark`)

## Actual
The BUG-609 text listed raw `df.item_type` names. `backpack` / `flask` matched only through the fallback of `L.token` (any item type the game knows, trade.lua `L.token`), nothing said so, and the text did not tell which token to add.

## Fix
- `L.KINDS`: `backpack(s)`, `flask(s)`, `quiver(s)`, `clothing` (pants, shoes, gloves), `junk` (all six) are sell tokens by name.
- `L.sell_name(type)` (trade.lua:505): the sell token that takes an item type (`crafts` for the craft types, else the want token: backpack, flask, pants, tool, splint, meal, leather); the log line and the ledger cause of `nothing_to_sell` (`step_mark`, trade.lua:1986) count by token: `kind=100(backpack22+flask21+pants11)`, `off the sell list: 22 backpack, ...`.
- Build on round 40b's surplus list (`L.surplus_sell`, trade.lua:1055): BUG-644's learned kinds (`st.x`) join the list through its new `extra` argument; the spare gear that lies at the depot is sold without a hand edit (see BUG-644).

## Tests
`tests/lua/test_bug642_644_trade.lua` (tokens and `sell_name`; the log and the ledger name tokens, crafts counted together), `tests/lua/test_trade.lua` (BUG-609 test adapted: tool / splint stay off the list).

## Live check
Next `nothing_to_sell` in a fort with `plan.trade.sell = [ring]`: `inspect what=trade` ledger shows `kind=N(backpack..+flask..)`; `dfllm cmd trade.want '{"sell_add":["backpack","flask"]}'` is accepted.
