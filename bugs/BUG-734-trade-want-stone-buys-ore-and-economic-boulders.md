# BUG-734 `trade.want stone` buys economic, ore and flux boulders; no way to free a stone type when nothing else exists
Status: fixed (offline, live-untested)
Severity: high
Found: 2026-11-11, Run 16c i3 Doorwings y385-y386 (trade ledger "bought stone BOULDER x4 (12)" every caravan, stone free 0, ConstructBlocks "Needs non-economic hard stone"; the fort holds CHALK 36 (flux), MAGNETITE 25 (ore), CONGLOMERATE 49 (53 boulders out of reach in a plugged shaft), SILTY_CLAY / CLAY (soft, economic))
Module: `lua/dfllm/trade.lua` (`L.match`, `item_info`, wants), `lua/dfllm/economy.lua` (`hard_report`, verb `stone.use`), `dfpilot/schema.py`, `lua/dfllm/util/contract.lua`, `dfpilot/wake.py`

## Root cause
`trade.lua` `L.KINDS.stone = {t = {'BOULDER'}}` matched every merchant boulder; the want carries no material, so the cheapest boulders of the caravan (clay, magnetite, hematite, chalk) were bought. `item_info` knew only flux (BUG-583). And for a fort with no plain hard stone at all there was no way to use what it holds: BUG-648 clears the economic mark of a plain hard stone by itself, but a flux or ore stone, or a stone the player prefers, stayed refused with no verb.

## Fix
`trade.lua` `item_info`: a BOULDER is `nouse` when it is flux, soft (no ITEMS_HARD), an ore (metal_ore) or marked economic in the stone-use screen; `L.match`: a plain `stone` / `boulder` token (no material, not a sell token, not `flux`) skips `nouse` boulders; `stone:magnetite`, `flux`, `bar:` keep asking for what they name; sell tokens are marked `sell` and never filter. New verb `stone.use {mat, economic?}` (`economy.lua`, any mode): the stone-use screen's mark of one stone type the fort holds as boulders (`economic` false, the default, frees it for furniture and blocks; true marks it again; soft stone is refused with the reason); it drops the denial memory and the material cache. The DECISION `no_hard_stone` (cause none) names the biggest hard flux / economic stone (an ore last) in `d.mat` and as the last of `d.cmds` (`dfllm cmd stone.use '{"mat":"chalk"}'`); `wake.no_hard_stone_hint` says so.

## Tests
`tests/lua/test_bug733_734_stone.lua`: the match table (conglomerate yes, magnetite no, `stone:magnetite` yes, `flux` yes, a sell token never filters), `item_info` nouse for plain / ore / flux / economic / soft, the verb (frees, marks again, unknown stone, soft stone) and the decision (`mat` chalk first, the command in `cmds`).

## Live check
`dfllm cmd trade.want '{"add":["stone"]}'` at a caravan with magnetite and conglomerate: only the conglomerate is bought (trade ledger). `dfllm cmd stone.use '{"mat":"chalk"}'`, then the next census counts the chalk usable. Open: schema, contract and CONTRACTS.md carry the new verb; freeing an ore stone lets the masons use the ore up (the smelter loses it); a Kernel reload is needed.
