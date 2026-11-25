# BUG-880 Ladder named order.add MakeBarrel although the reserve orders the containers itself
Status: fixed (offline, live-untested)
Severity: low
Found: Run 17 i1/i4: NAECHST repeated `order.add MakeBarrel` while the kernel's reserve was ordering the same barrels.
Module: `lua/dfllm/economy.lua` (`M.rsv_works`, state `stock.rsv`), `dfpilot/leiter.py` (`t_versorgung`), `dfpilot/schema.py`

## Root cause
The ladder had no way to know the reserve was at work (`stock.dcx` only says DF names the containers).

## Fix
State `stock.rsv` = 1 when a batch stands or was ordered < 3 game days ago and the last look found a material (`st.rsvstuck` unset). `t_versorgung` then names no player command (`dfllm status (die Behaelter-Reserve bestellt selbst ...)`); without the flag (no material, DF refuses it) it names `order.add MakeBarrel mat=rock|wood` as before.

## Tests
`tests/test_bug880_ladder_reserve.py` (2), `tests/lua/test_bug878_880_stein.lua` (`rsv_works`).

## Live-Erwartung
i1: while kern.log shows 'container reserve: N rock barrels ordered', the Versorgung NAECHST line does not tell the player to order barrels; when the reserve says 'nothing to make them of' it does. NOT promised: that the player's own order.add is blocked.
