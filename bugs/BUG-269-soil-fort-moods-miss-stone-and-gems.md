# BUG-269 Strange moods without stone or gems in a deep-soil fort
Status: fixed (offline, live-untested)
Severity: medium (moods failed; the player set trade.want gem by hand)
Found: 2026-10-29, Run 15 Guildcleans (FR-BUGS.md), fix6-econ-supply
Module: `lua/dfllm/economy.lua` (`M.rock_dig`, `M.supply_wants`), `lua/dfllm/trade.lua` (`econ_tokens`)

## Actual
#321/#326 Secretive mood: boulders 'none in the fort' ('moods missed rock'); #665-#672 Fey mood: gems. The bedrooms stone dig yields
nothing in deep soil; gems and stone were no trade wants; care.mood_wants reach trade only while a mood runs.

## Fix
`M.rock_dig` counts the stone digs it asked while not one free boulder existed (`p.rocksoil`); two such (`M.ROCK_SOIL`) mark the
fort soil (st.rock.soil) until a free boulder appears. `economy.supply_wants` then asks every caravan for `stone` (the rock need,
up to 30) and `gem` (up to 3 gems in the fort); trade puts these after economy.trade_wants and before plan.trade.want.
Not built: a mood_stock target for blocks.

## Tests
`tests/lua/test_economy_supply6.lua` BUG-269 (fails on 2b9c009).

## Live check
Guildcleans: `dfllm cmd inspect '{"what":"workload"}'` stone.soil true after two rock requests; `inspect what=trade` want list
holds `stone` and `gem` before the plan's tokens; the next caravan's ledger shows boulders/gems bought.
