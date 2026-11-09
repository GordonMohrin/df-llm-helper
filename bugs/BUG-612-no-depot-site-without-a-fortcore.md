# BUG-612 DEPOT_MISSING 'no known depot site' in a fort with no fortcore
Status: fixed (offline, live-untested)
Severity: high
Found: 2026-11-09, Run 16c i3 Wallfree y375-y376 (a caravan unloaded nothing, drink 201 -> 15 d, seeds and metal only by trade)
Module: `lua/dfllm/runner.lua` (`Q.depot_fallback`, `M.depot_keep`), `lua/dfllm/trade.lua` (DEPOT_MISSING text)

## Actual
DEPOT_MISSING 'no known depot site' in a fort with no fortcore.

## Root cause
`depot_keep` took its site from the manifest depot or the last depot the runner saw; both come from a fortcore. A fort with none had no site: `no known depot site (no fortcore depot): place one by hand`, and `bp sites depot` found no 5x5 either.

## Fix
`runner.lua` `Q.depot_fallback`: around the centre of the citizens' positions, nearest first (step 3, radius 30, at most 220 blocks), the first 5x5 block whose 25 tiles all lie on the citizens' walk group (`snapshot.groups`) and whose middle is plain floor becomes the depot project (`depot_keep` log `surface fallback beside the citizens`); none found: the reason is logged and the search waits 36,000 ticks. `trade.lua` DEPOT_MISSING: `no depot site (no fortcore, no flat 5x5 floor by the citizens): plan propose (depot) or by hand`.

## Tests
`tests/lua/test_bug608_612_runner.lua` (found, none, the manifest depot first), `tests/lua/test_trade_ledger.lua` (text)

## Live check
A fortcore-less fort with a caravan: `trade depot missing (caravan): project depot1 at x,y,z (surface fallback ...)`.
