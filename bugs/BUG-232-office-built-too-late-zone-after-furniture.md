# BUG-232 the manager's office comes too late: a P1 build after dining, its zone stage behind its chair and table
Status: fixed (offline, live-untested)
Severity: high (with BUG-231 the cause of the Guildcleans deadlock; any fresh fort reaching the manager's office line first)
Found: 2026-10-29, Run 15 Guildcleans (pop 20, y372), `runs/run-15-guildcleans/FR-BUGS.md` "Manager-Büro fehlt"
Module: `plans/year1.json`, `dfpilot/bp/rooms.py` (`office`), `lua/dfllm/economy.lua` (`M.office_zone`, `office_check`),
`lua/dfllm/zonelib.lua` (type `office`), `lua/dfllm/util/contract.lua` / `dfpilot/schema.py` (`zone_place` owners, ZONE_TYPES)

## Actual
The year-1 plan of a fresh fort is fortcore stage 1 only (BUG-197); the follow starter then placed P0's farms and workshops, and
P1 started dining before the office. The kernel ran at P1 with workshops, tombs and farms under way, but no office: at pop 20 the
manager validated nothing (BUG-231). The office template built its zone only after its build stage (door, chair, table), so even a
placed office had no zone while its furniture waited.

## Fix
`plans/year1.json`: the office is a P0 deliverable right after fortcore stage 1 (before farms; P1 keeps dining): the follow starter
places it at the first PLAN_EXHAUSTED after the core, and `plan propose` drafts it in year 1 once the core floor exists. The office
template's stages are dig, zone, build, burrow: the Office zone stands as soon as the room is dug. `zone.place` takes `type=office`
(quickfort key `o`). With no Office zone at all (none of the manager's, none free) economy draws one (act.zone_place, zonelib's
tile and conflict checks, outside a fight, at most every `office.retry_days`) over a built chair and the built table beside it that
stand outside every room zone; act.manager_office then gives the free zone to him; kern.log and MANAGER_OFFICE (B). Off with
`office.zone` false.

## Tests
`tests/lua/test_manager_bypass.lua` `BUG-232 ...` (zone over chair+table, a bedroom's chair left alone, once);
`tests/test_bug231_233_manager.py` (`test_the_office_is_a_p0_build_with_its_zone_first`, zone.place office);
`tests/test_cli_wake.py` (the P0 starter places the office after fortcore stage 1); `tests/lua/test_zone_place.lua`; golden
`tests/bp/golden/office.*`. All fail on 6dc0f19.

## Live check
A fresh embark: after fortcore stage 1, cli.log `auto:starter ... placing office`; `dfllm bp list` shows the office project with the
stage order dig, zone, build; once dug, the zones screen lists an Office zone (assigned to the manager after a day). In a fort without
any office zone and a lone chair+table: kern.log `manager has no office: Office zone N drawn over the chair at x,y-x,y zZ`.
