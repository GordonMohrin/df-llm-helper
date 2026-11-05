# BUG-499 The manager validates nothing and nothing can be looked at (188 open orders, 93 hanging)
Status: fixed (offline, live-untested): the diagnosis; the live cause is not proven
Severity: high (brewing and cooking stop; drink fell from 291 to 123 days in two months)
Found: 2026-11-05, Run 16b i2 Roadvises y373/y374 ("Manager validiert keine Auftraege": manager Onget 'validates nothing (his office has a chair and a table)', 188 orders open, 93 stuck, 30 brews; the same as Roadvises' Moerul for 755 days); Run 16a i1 Syrupobeyed y386 (35 orders, 149 days)
Module: `lua/dfllm/economy.lua` (`M.manager_facts`, `M.inspect.manager`, `M.mgr_stuck`), `dfpilot/schema.py` (inspect `what`), `docs/v2/CONTRACTS.md`

## Actual
The DECISION manager_stuck / manager_office ended in ': inspect the manager (job, path to the office)' and no command did that (`inspect what=manager` was refused by the schema, `offices` lists vacant posts only). What the kernel knew (the manager's squad, mood, rest, the outside check, the office zone and its chair and table) was spread over four code paths; the walk path to the office, DF's room value for the post and the ManageWorkOrders jobs were not read at all. The logs say only 'complete office, nothing vacant', so the live cause cannot be named offline.

## Fix
- `economy.manager_facts(K, p, c)` (read only) and `inspect what=manager`: manager, unit, job, position, squad, mood, days outside the walk group, the office zone (box, chair, table, planned ones, `walk` = a walking path from him to a zone tile through `snapshot.reach`, DF's room description when `dfhack.buildings.getRoomDescription` answers, `required` = the post's required_office), the orders (unvalidated, age, brews, ManageWorkOrders jobs in the world and how many are his) and `causes[]` (most likely first: no post, soldier on duty, strange mood, resting, outside, no office zone, no chair, no table, no path; else 'nothing the kernel can read is wrong' with the required room value and the zone.place command) and `next[]` (commands).
- DECISION manager_stuck: `inspect what=manager` is the first command, `d.cause` carries the first finding (msg unchanged, d.q still <= 200 bytes).
- schema.py: `what` enum + `manager`; CONTRACTS.md (inspect row, appendix regenerated).

## Tests
`tests/lua/test_economy_drink.lua` (inspect what=manager for a complete office and for a manager in a squad; manager_stuck carries the cause and the command first), `tests/lua/test_bug497_500_material.lua` (answers without a post), `tests/test_bug497_500_f31.py` (verb arg).

## Live check
`dfllm cmd inspect what=manager` in i2/i1 prints the table above; `causes` names the real blocker (or 'nothing the kernel can read is wrong' and the required room value to compare with `zone.place type=office`). Open: if the answer is a too small office, a bigger zone is the fix and is not automated yet.
