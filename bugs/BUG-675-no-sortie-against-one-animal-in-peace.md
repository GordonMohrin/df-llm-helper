# BUG-675 A giant bat killed two patients inside the fort while squad.sortie said "not allowed in PEACE"
Status: fixed (offline, live-untested)
Severity: high
Found: 2026-11-10, Run 16d i4 Trumpetrealms y447-y450 (`events.1.jsonl:23578`, `:23594` PREDATOR for BAT_GIANT 31961 with an offer, `:23626`; `commands.log:10189` `squad.sortie not allowed in PEACE`)
Module: `lua/dfllm/util/contract.lua` (`squad.sortie` modes), `lua/dfllm/military.lua` (`M.peace_sortie`, `squad.sortie`, `sortie_pass`), `dfpilot/schema.py`

## Root cause
`contract.lua:252`: `squad.sortie` lists ALERT / SIEGE / BREACH / RECOVERY. One wild animal in PEACE (the bat, PREDATOR_FAR for a while, 49 tiles from the nearest citizen but on the citizens' ground) got a PREDATOR event with a ready command that `kern.lua:1066` then refused; `military.lua:3057` would also have ended such a sortie at its next look (`the mode is PEACE`).

## Fix
`squad.sortie` lists PEACE. `M.peace_sortie`: in PEACE the verb needs `unit`, the unit in the fresh census as the ONLY hostile counted (`reflex.far_ids` left out), `k == 'danger'`, not a building destroyer, not `rc 0`, and `sortie_advice` recommending the sortie (worn >= `sortie.worn`, odds good or even); else `squad.sortie not allowed in PEACE (only for one wild animal inside the fort): <reason>`; a `gate` sortie in PEACE keeps `squad.sortie not allowed in PEACE`. The sortie carries `pe = true` and `sortie_pass` does not end it for the mode. SIEGE, BREACH, ALERT and RECOVERY are untouched.

## Tests
`tests/lua/test_bug672_676_lockdown.lua`: a PEACE sortie goes and keeps running; a group, an invader, a missing unit, a missing `unit`, a gate sortie and a weak squad are refused naming the reason; `tests/test_bug672_676_f44_lock.py` (schema modes).

## Live check
One animal on the citizens' ground in PEACE with a fit squad: the PREDATOR offer's command is accepted (`SORTIE go`), the squad kills it and `SORTIE dead` follows.
Open: military's PEACE posture upkeep may re-station the squad while the kill order stands (the order is `sortie:` tagged like any other, not proven live); the PREDATOR_FAR digest line carries no command (the player asks `inspect census`).
