# BUG-534 Caravans never brought stone, mechanisms or bars for years, `trade.want` changed nothing and nothing said so
Status: fixed (offline, live-untested) as a diagnosis; the liaison request is NOT written
Severity: medium (forts without hard stone or ore starve for mechanisms, levers, traps)
Found: 2026-11-06, Run 16a i1 Basementflew, Run 16d i4 Trumpetrealms (`runs/run-16*/FR-BUGS.md`; TRADE_LEDGER events `unmet stone:none mechanism:none`, read only)
Module: `lua/dfllm/trade.lua` (`L.unsupplied`, `pub.trade.nb`), `lua/dfllm/util/contract.lua` + `dfpilot/schema.py` (state `trade.nb`), `dfpilot/brief.py` (`trade_nb_note`)

## Actual
`plan propose` puts `mechanism`, `stone`, `bar:iron` first in `trade.want` (BUG-430 / BUG-438 / BUG-377); the ledger of every visit says `unmet ...:none` (the merchants had none), visit after visit.

## Root cause
Trade marks only what the merchants carry (trade.lua `step_mark`, `L.ledger` unmet `none`). What a dwarven caravan carries is its civilization's goods plus what the fort asked for through the liaison's trade agreement: `df.global.game.main_interface.diplomacy` (`environment.dipev.sell_requests.priority[category]`, DFHack `caravan.tradeagreement`), a screen that exists only inside the liaison's meeting (`dwarfmode/Diplomacy/Requests`). dfpilot never writes it (DOCTRINE says "use the liaison to request metal", nothing implements it), and a want of a good no merchant carries cannot be paid for.

## Fix (diagnosis, no live write)
The agreement screen is a UI write into a meeting that cannot be opened offline, and a wrong click there loses the meeting; it stays unwritten (open FR). Instead:
- `trade.L.unsupplied(ledger)`: the wants that were unmet `none` in every kept visit that asked for them (at least 2, `M.NOSUPPLY_MIN`) and were never bought. State `trade.nb` (at most 5 tokens, `M.NOSUPPLY_MAX`).
- Status / brief (`brief.trade_nb_note`, rank 2 in the supply items): `trade cannot supply mechanism, stone (the merchants had none in every visit; trade.want does not change it, the kernel does not write the liaison's trade agreement); make it: mechanism: mechanic's workshop from stone; stone: dig it (explore quarry, bedrooms)`, one alternative per kind (bar: smelt ore / melt metal gear, wood: fell trees, ...).

## Tests
`tests/lua/test_trade_ledger.lua` (+1), `tests/test_bug532_534_f33.py` (note text, supply item, schema accepts `trade.nb` and rejects 6 tokens).

## Live check
After two caravans with an unmet `stone` / `mechanism`: state `trade.nb` and the status line above. Open FR: write the liaison's trade agreement (`sell_requests.priority`) during the liaison meeting, researched live.
