# BUG-592 The manager is a squad member on duty and validates nothing for 58 days
Status: fixed (offline, live-untested)
Severity: high (no coffins, no forging, no brewing: orders wait unvalidated; 27 corpses lay)
Found: 2026-11-09, Run 16b i2 Brotherarrow y406-y407 (`no manager available (manager Erush is a soldier on duty) for 26 / 33 / 58 days`, ConstructCoffin x4, ProcessPlants x26, MakeHelm)
Module: `lua/dfllm/military.lua` (`manager_unit`, `M.manager_pull`, `M.step`), `lua/dfllm/economy.lua` (`M.manager_watch`)

## Actual
`economy.manager_state` named the cause (`manager <name> is a soldier on duty`) and DECISION_NEEDED `manager_absent` asked Gordon to use the nobles screen; no dfpilot command takes a manager out of a squad, so nothing happened for 58 days.

## Root cause
`military.recruits` leaves nobles out of a squad, but a soldier who becomes manager after he was seated (DF's election or an appointment) stayed in it, and nothing in military looked at the MANAGER post. A squad member on duty is at his station or drill and does not walk to the office.

## Fix
`M.manager_pull(K, force)` finds the MANAGER holder (fortress entity assignment -> historical figure -> unit) and removes him from his squad (`K.act.squad_remove`, the squads screen's remove), in any mode, at most every 1200 ticks from the upkeep; kern.log names it. `economy.manager_watch` asks it (`force`) before the `manager_absent` question and stays silent when it worked; refused, the question stands as before. A noble is no recruit, so he is not taken back.

## Tests
`tests/lua/test_bug591_594_kit.lua` (2: the manager leaves squad A and stays out; nobody holds the post), `tests/lua/test_economy_orders.lua` (+1: economy asks military; no `manager_absent` when it took him out, the question when it could not)

## Live check
A fort whose manager sits in squad A: kern.log `the manager (unit N) was a member of squad S: taken out`, `inspect what=military` `manager_in_squad` false, `inspect manager` validates again; the squad refills from the recruits.
