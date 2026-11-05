# BUG-438 no hard stone: no mechanisms, traps / wells / hospital / levers hang for years; the stone digs lie in soil
Status: fixed (offline, live-untested)
Severity: high (wrong decision: the fort cannot finish its defence, water or hospital)
Found: 2026-11-05, Run 16a i1 Syrupobeyed y374-y379 (`runs/run-16a/FR-BUGS.md`: "Stein-Mangel blockiert alles", "Hartstein 0 in y375", "explore/stockroom bringen keinen Hartstein")
Module: `dfpilot/plan.py`, `lua/dfllm/economy.lua` (state `stock.rsoil`), `tools/embark/checklist.lua`

## Actual
`stone free 0 need 17..18` for four game years; "Make rock mechanisms" cancelled "Needs non-economic hard stone boulders"; 36 trapparts, the levers B1/B2/O1 (`needs 2 free reachable mechanisms, 0 found`), the well,
the hospital, the quern and the coffins waited. The kernel asked for a stone dig 20+ times (`PROJECT_REQUEST bedrooms why=rock`), the explore and stockroom digs (y377-y379) lay in soil
("soil": true), hard stone only deeper. The embark check `stone` said `pass`.

## Cause
- `plan.py` answered a stone shortage with `STONE_DIG` (bedrooms n=4: rooms in the core's floor = soil), and `fit_explore` tried depth 12 and shallower only; a fort whose first hard stone lies deeper than
  that dug only soil. The kernel knew (`economy.rock_dig`: `rocksoil` >= 2 marks the fort soil) but never published it, so propose could not react (`trade.want` stone/mechanism lived only in the kernel's own supply pass).
- `tools/embark/checklist.lua` passed every soil category up to `hard_stone_levels` (6) as "stone near the surface", although the soil_levels figures (some = 3) are estimates.

## Fix
- `economy.lua`: state `stock.rsoil` = 1 while the fort is marked soil (contract.lua, schema.py, CONTRACTS.md).
- `plan.soil_dig` (before `fit_explore` in propose / auto / CLI): in a soil fort the drafted bedrooms dig is replaced by an `explore` quarry with `p.avoid` = the known aquifer levels
  (`quarry_fallback(soil=True)`), and one is added when the rock is short and no explore is drafted or under way; `fit_explore` tries SOIL_DEPTHS (24, 20, 16) before the normal depths
  and sets `p.every` = 6 (a tunnel in soil gives no stone); the deepest depth with a site and no avoided level wins. `propose` puts `mechanism`, `stone` first in trade.want.
- embark `stone`: up to `stone_pass_levels` (2) levels of estimated soil pass, 3..6 warn with the estimated depth and "explore shaft of at least N+2 levels in the first season", over 6 fail (as before).
  `rules.json` `stone_pass_levels`.

## Tests
`tests/test_bug437_440_f27.py` (soil swap, depths, default forts untouched, trade want), `tests/lua/test_economy_supply6.lua` (rsoil in the state), `tests/lua/test_embark_fix6.lua` (warn / pass).

## Live check
A soil fort: `stock.rsoil` 1 in the state; `dfllm plan propose` drafts explore@S1 p.depth 24/20/16 p.every 6 instead of bedrooms and `trade.want mechanism, stone`; the shaft reaches rock. Open risks: the
soil figures stay estimates and a layer stone such as sandstone may not count as "hard" for mechanisms (not modelled); the explore ranking sees revealed tiles only, so the depth is the
deepest the sites snapshot and the avoided levels allow. The 16a evidence (no layer list of the embark panel survives) cannot say how deep that soil really was.
