# BUG-450 The manager validates nothing for 149 days; zone.place locked in a siege
Status: fixed (offline, live-untested)
Severity: high (brewing and cooking stop: drink 291 -> 123 days)
Found: 2026-11-05, Run 16a i1 Syrupobeyed y386 spring (`runs/run-16a/FR-BUGS.md` "Manager validiert nichts: 35 Auftraege 149 Tage unvalidiert")
Module: `lua/dfllm/economy.lua` (`manager_state`, `unval_watch`, new `mgr_stuck`), `lua/dfllm/zonelib.lua`, `lua/dfllm/util/contract.lua`, `dfpilot/schema.py`, `dfpilot/wake.py`

## Actual
`inspect orders`: orders 50/51/56 (prepare lavish meal, brew drink from plant, process plants) "unvalidated: manager Zuntir validates nothing (his office has a chair and a table)", 14 brews waiting, 195 open orders / 95 stuck.
`inspect offices` says "none vacant" (a manager is appointed), `zone.place` was refused in SIEGE. The kernel's only reaction was the standing DECISION_NEEDED manager_office, which tells the player to look at the manager.

## Root causes
1. `economy.lua unval_watch` ends in one standing question (`manager_office`, every 7 days, with the text "inspect the manager") however long the validation does not happen; nothing counted the days against a manager who is able and has a complete office.
2. `manager_state` knew injured / resting / mood / gone, not a manager who is a squad member (a soldier on a station or a drill does not walk to the office): that case fell into "validates nothing".
3. `contract.lua` `zone.place` modes PEACE/ALERT/RECOVERY: the office fix (a second Office zone for him) was impossible during the 150 days of SIEGE.

## Fix
- `manager_state`: a manager in a squad is `manager X is a soldier on duty` (feeds the existing manager_absent decision).
- `economy.mgr_stuck` (called from `unval_watch`): `orders.mgr_stuck_days` (14, 0 = off, `fairplay.ECONOMY_LIM`, config/baseline.json) of unvalidated orders with an able manager and a complete office raise DECISION_NEEDED `manager_stuck` (A, again after the same period):
  the manager, days, order and brew counts, his job and position, the office zone, DF's `required_office` room value, an acting-manager candidate, `cmds` (inspect unit / orders / offices). The kernel replaces nobody (the nobles screen's removal is the player's).
- `zone.place` is allowed in SIEGE for `type=office` only (contract.lua, schema VERBS, `zonelib.verb` refuses every other type there; BREACH stays closed). wake.py `manager_stuck_hint`. CONTRACTS.md, RULES.md, appendix.

## Tests
`tests/lua/test_economy_drink.lua` (manager_stuck once per period, 0 = off), `tests/lua/test_zone_place.lua` (BREACH refuses, SIEGE office ok, SIEGE pen refused), `tests/test_bug450_456_ops.py` (contract, wake line).

## Live check
Unvalidated orders with a complete office for 14 days: `dfllm events --cls A` shows `manager_stuck` with `cmds`; `dfllm cmd zone.place '{"type":"office","bbox":[...]}'` in a SIEGE is accepted, a pen is refused with "only type=office in SIEGE".
Open risk: the real cause of the 149 days (position, room value, burrow) is still unknown; the decision gathers the facts.
