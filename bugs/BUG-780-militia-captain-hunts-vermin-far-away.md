# BUG-780 A squad member takes a HuntVermin job and walks 90 tiles into the cavern level
Status: fixed (offline, live-untested)
Severity: high
Found: 2026-11-11, Run 16c i3 Lancemoment y380 (militia captain 26415, walk group 2815 at 10,178,132, STRANDED 'no raised bridge leads to food', thirst 66,844, dead; earlier i3 Doorwings HuntVermin on wall crowns, BUG-751)
Module: `lua/dfllm/seal.lua` (`M.hunt_errands`, `M.hunt_job_of`, `M.job_stray`)

## Actual
The captain of squad B took a vermin hunt far out of the fort. BUG-740's labor switch (`economy.soldier_hunt_off`) runs only in the economy's own pass, once a day per unit, and the BUG-751 rule (`seal.stray_errands`) cancels a hunt only when its target group has no drink and food; a hunt across the cavern level goes through. No rescue exists for a citizen 90 tiles away (the BUG-769 ramp needs a one-level drop).

## Root cause
`seal.lua` `stray_errands` (only a target on a group without drink and food) and `economy.lua` `soldier_hunt_off` (pass-paced, the labor can come back).

## Fix
`seal.hunt_errands(K, t, cits, good)` after `stray_errands` in `job_stray` (every 600 ticks): a Hunt / HuntVermin job of a squad member is cancelled at once (`act.cancel_stray_job`) AND his Hunting labor is switched off (`act.labor_set 'hunt' off`, now also owned by seal in contract.lua), so the next vermin hunt does not start the same day; a HuntVermin job of a unit on a group with drink and food is cancelled when its target (`job.pos`, not verified on live data) OR the hunter himself is more than `CFG.hunt_far` (30) tiles (x, y) from every other citizen inside or more than ten levels off. The same unit is looked at again after `CFG.hunt_wait` (600 ticks), no longer after a day. A squad member on any other job (patrol, siege duty) is not touched.

## Open
A unit already stranded on another walk group gets no rescue here (a distant pocket; BUG-769 needs a one-level drop). Whether `job.pos` of a HuntVermin job is the vermin's tile is unverified; the check of the hunter's own position covers it. No siege traffic test: the rule touches only Hunt / HuntVermin jobs, which are no combat jobs. The caravan stuck 'Leaving' (2 traders at 13,42,141) was not examined: it blocks no trade in the notes. Not run live; Kernel reload needed.

## Tests
`tests/lua/test_bug780_hunt_far.lua` (3): a squad member's hunt is cancelled, his labor goes off, a new hunt is cancelled at the next look, a civilian's hunt in the fort stays; a squad member on another job is left alone; a vermin hunt 90 tiles out and one twelve levels down are cancelled.
