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
`seal.hunt_errands(K, t, cits, good)` after `stray_errands` in `job_stray` (every 600 ticks): a Hunt / HuntVermin job of a squad member is cancelled at once (`act.cancel_stray_job`); a HuntVermin job of a unit on a group with drink and food whose target is more than `CFG.hunt_far` (30) tiles (x, y) from every citizen inside or more than ten levels off is cancelled; per unit once a day, at most `stray_max` per look; kern.log names the reason.

## Open
A unit already stranded far away gets no rescue (a distant or deeper pocket); seal does not switch the labor off (economy owns it, `soldier_hunt_off` does that in its pass). The caravan stuck 'Leaving' for 36 days (2 traders at 13,42,141) was not examined: reported only, it blocks no trade in the notes. Not run live; Kernel reload needed.

## Tests
`tests/lua/test_bug780_hunt_far.lua` (2): a squad member's hunt near the fort is cancelled once, a civilian's hunt in the fort stays; a vermin hunt 90 tiles out and one twelve levels down are cancelled.
