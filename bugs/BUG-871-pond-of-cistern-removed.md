# BUG-871 the stall ladder removed the pond zone of a cistern room's well: three pond-fed cisterns on i1 lost their only fill, their wells were retired
Status: fixed (offline, live-untested)
Severity: high
Found: Run 17 i1 Diedplank y377-y395: kern.1.log '3 water job(s) stalled: 26273 FillPond 5d at 36,120,142 [pond zone 18426 removed]', events n=3638 [pond zone 18386 removed], n=3252 dry_well did='pond zone 18380 removed'; each cistern then got CISTERN_DRY, well.retire approve=true (18360, 18404 retired, 18340 stands dry).

## Root cause
`lua/dfllm/water.lua` `unstick` (the pond loop) removed every Pond zone within pond_near+1 of a stalled FillPond/GiveWater worker with no `cistern_room` test, while `pond_block` (held rows) keeps those ponds on purpose (`row.held = M.cistern_room(K, s) ~= nil`).

## Fix
`M.pond_feeds_cistern(K, r, pd, c)`: the built well of a manifest cistern room within pond_near+1 of the pond. `unstick` keeps such a pond (`pond zone N kept (it fills the cistern room's well M)`) and removes others as before.

## Tests
`tests/lua/test_bug871_877_water.lua` (BUG-871): the same stalled FillPond worker, a pond beside a cistern-room well is kept, a pond beside a plain well is removed.

## Live-Erwartung
On a fort with a pond-fed cistern whose FillPond worker stalls: kern.log shows no `pond zone ... removed` for the pond of a manifest cistern room (PROMISED). That the stalled worker then reaches the pond and the cistern fills is NOT promised (why the worker stands 4-8 days is unconfirmed).
