# BUG-674 squad.uniform / create / add / leader are "not allowed in BREACH" while wild animals made the BREACH: the soldiers can never be equipped
Status: fixed (offline, live-untested)
Severity: medium
Found: 2026-11-10, Run 16b i2 Whirledrampart y414-y431 (player report: soldiers 2, `mil.kit armor 0`, the squads-screen verbs refused for 380 days of the mammoth BREACH)
Module: `lua/dfllm/util/contract.lua` (`C.VERBS`), `dfpilot/schema.py`, `lua/dfllm/military.lua` (`M.fight_free`)

## Root cause
`contract.lua:268-271`: the four squads-screen verbs list PEACE / ALERT / RECOVERY only (BUG-055: "not touched in a fight"); `kern.lua:1066` refuses the other modes before the handler runs. A BREACH or SIEGE made by animals is not a fight.

## Fix
The four verbs also list SIEGE and BREACH; `military.fight_free(K, verb)` (first line of each handler) refuses there, with the old text `<verb> not allowed in <mode>`, unless `threat.assess` is fresh and counts no invader, undead, great danger or building destroyer and gives no `siege` reason (it already leaves out the hostiles reflex cleared). Schema `VERBS` follows (`SQUAD_FIGHT_FREE_MODES`).

## Tests
`tests/lua/test_bug672_676_lockdown.lua` (uniform, create, add, leader work in an animals-only BREACH; 6 invaders, a great danger, undead, a destroyer, a siege reason, a stale reading: the old answer word for word), `tests/lua/test_a4_offices.lua` (the old SIEGE / BREACH refusal in a world without threat), `tests/test_bug672_676_f44_lock.py` (schema = contract).

## Live check
`squad.uniform` in a BREACH with only animals counted is ok; in a real siege it answers `squad.uniform not allowed in SIEGE`.
Open: the uniform order is given during a BREACH; the soldiers fetch the gear through the fort the animal stands in.
