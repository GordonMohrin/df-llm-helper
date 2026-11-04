# BUG-422 one citizen dies of thirst with 766 days of drink and no wake
Status: fixed (offline, live-untested); open: the cause of the stranding itself (stuck, locked in) is only named, not cured
Severity: high
Found: 2026-11-05, Run 16d i4 Mazelanterns y386 autumn d60-64 (events #4962/#4966, unit 26275; `runs/run-16d/FR-BUGS.md`), main b4087f4
Module: `lua/dfllm/economy.lua` (`M.solo_check`, `alarm_check`), `dfpilot/wake.py`

## Actual
Citizen 26275 died of thirst 75000 / hunger 87384 with `stock drink 766d`; no THIRSTY wake, no STARVING wake, the cause 'unknown' for 4 days.

## Root cause
`lua/dfllm/economy.lua` `alarm_check`: wakes (`DECISION_NEEDED thirst`) only for `alarm.units` (2) citizens over `alarm.thirst`, or low drink days; one citizen
cut off from a full stock is neither. siege's `dry_group` needs a walk group without drink; a unit locked in on a job, caged or unconscious is not one.

## Fix
`economy.M.solo_check` (called from `alarm_check`, pcall'd): any citizen over thirst 50000 or hunger 70000 gets `DECISION_NEEDED` A `thirst_unit`
(`q` = `N citizens dehydrating or starving with drink D d: <id> (thirst T, hunger H, caged | unconscious, job X | no job, at x,y,z)`, `units`, `cmds` =
`inspect what=unit key=<id>` x3, `inspect what=reach`), then again every 3 game days while he stays over the mark (at most 5 listed). `wake.py`:
`thirst_unit` is in `URGENT_DECISIONS` and gets the command hint like `no_water`. CONTRACTS documents the id under DECISION_NEEDED.

## Open
The 'unknown' death cause for 4 days (the unit missing from the list) is care's BUG-339/340 path, not changed here. The wake names what the unit does; it
does not walk him to water.

## Tests
`tests/lua/test_bug420_422_alarm.lua` (49000 quiet; 62000/87000 one wake with the id, job and cmd; not again within 3 days; again after; quiet when he drank).

## Live check
A citizen at thirst > 50000 with the other citizens fine: `dfllm events --cls A` shows `thirst_unit: 1 citizen dehydrating ...` within a day, in follow as an urgent wake.
