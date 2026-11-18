# BUG-782 the refuge stays dry when no cistern route and no refuge room exist; refuge_drink refused 'no refuge in manifest'
Status: fixed (offline, live-untested)
Severity: high
Found: 2026-11-11, Run 16b i2 Whirledrampart y446-y451 ('bp sites cistern core/refuge: no pipe route', refuge_dry the R0 blocker, BUG-766 only asks); Run 16a i1 Basementflew y457 / y543 (`bp.place refuge_drink` refused 'no refuge in the fort manifest', pop ceiling 29 held on refuge_dry)
Module: `lua/dfllm/economy.lua` (`T.drinkpile`, `M.drinkpile_n`, `M.pile_site` filter `q.ok`), `lua/dfllm/act.lua` (`drink_pile`), `dfpilot/bp/sites.py` (`kern_rooms`, `kern_store`), `dfpilot/bp/emit.py`

## Actual
The only drink source for the refuge besides wells and a cistern is the `refuge_drink` template, dug off the fortcore refuge room (stage 3). Without that room in the manifest (fortcore impossible under an aquifer, a phantom refuge cancelled) it is refused, and a cistern needs a pipe route to water. refuge_dry stayed for good, the ceiling stayed held and nothing but a DECISION asked.

## Fix
(a) Kernel: `T.drinkpile` (daily, PEACE/RECOVERY): after `M.DRINKPILE.days` (10) days of readiness `refuge_dry`, with no drink store on the refuge burrow (`seal.refuge_drink.store`) and no `refuge_drink` / `cistern` project pending, `act.drink_pile` puts a stockpile `dfllm-drink` (food pile, quickfort `:=booze`, barrels sized like `rooms.refuge_drink_n` from the need, `take_from=dfllm-stock`) on revealed plain floor of the refuge burrow (`pile_site` with the burrow tiles as filter; smaller sizes 9/6/4/2 when none fits). Nothing is dug, so never near water. The haulers fill it; seal's audit counts its drink on the burrow tiles, so `refuge_dry` (readiness) ends by itself and its fix text names the store ('its drink store (n tiles) waits for barrels'). A placed pile waits 30 days, a refused or site-less try 3.
(b) Plan side: with no refuge in the manifest `bp sites refuge_drink` ranks off the Kern+ fortcore rooms (`sites.kern_store`); `p.burrow=Kern+` makes the store join Z4 like a core room (`emit`). Without any Kern+ room the refusal stays and names the kernel's pile.

## Open
The Kern+ store does not feed the refuge burrow; the kernel's pile on the refuge floor does. `plan propose` does not draft the Kern+ variant by itself. A pile needs refuge floor free of buildings (else 'nosite' in `p.dpile`, debug log). A Kernel reload is needed.

## Tests
`tests/lua/test_bug782_drink_pile.lua` (2), `tests/lua/test_act_supply.lua` (`drink_pile`), `tests/test_bug782_kern_store.py` (3), `tests/bp/test_bp_refuge_drink.py` adjusted.
