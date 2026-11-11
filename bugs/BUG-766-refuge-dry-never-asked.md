# BUG-766 refuge_dry is never asked: the deep defense finds the refuge dry at the siege
Status: fixed (offline, live-untested)
Severity: medium
Found: 2026-11-11, Run 16a i1 Basementflew y509-y540: 'refuge_dry' in 47 events (SIEGE_UNREADY, status) over 31 game years, no DECISION; at the y540 surprise siege SIEGE_DEEP wanted Tiefe+ and REFUGE_FAIL #28913 'Tiefe+ refused (no drink (drink 0<50, no well)): confining to Kern+'
Module: `lua/dfllm/readiness.lua` (`ask_refuge_dry`)

## Actual
R0 named `refuge_dry` the whole time (R0 UNREADY in every STAND entry) and `plan` / `brief` named the drink store, but no DECISION_NEEDED asked for it, and in this fort the template could not be placed ('refuge_drink: no refuge in the fort manifest', FR-BUGS y455-y457). At the siege the confinement fell back to Kern+ (a cave dragon was in sight: 'the bridges are no barrier'), where the dragon and goblins killed citizens.

## Root cause
`readiness.evaluate` only filled `rt.rdry` (status text, SIEGE_UNREADY); the questions it asks in PEACE (`refuge_levers`, `bridge_levers`, `defense_gap`) had no counterpart for the refuge's drink.

## Fix
`ask_refuge_dry`: DECISION_NEEDED `refuge_dry` (A) in PEACE once the refuge has stood dry RDRY_GRACE (3600) ticks, again every DEF.ask_days (30) days while it does (persisted `rdt`, `rdq`). Text: what a fight does without it (REFUGE_FAIL, the civilians stay in Kern+, also against a building destroyer) and the fix by `cause`: `store` (the manifest has a refuge: `bp.place refuge_drink`), `barrels` (the store stands and waits for barrels), `pending` (a project is under way, no command), `no_room` (the manifest has no refuge room: Kern+ stays the confinement, keep it stocked; `inspect refuge`).

## Open
For a fort without a refuge room the question can only name the limit; nothing builds a drink store there. The seal's rule that a dry refuge with a way in is never the civilians' burrow in a fight (BUG-378) is unchanged.

## Tests
`tests/lua/test_bug766_refuge_dry_ask.lua` (3): asked once after the grace with the store command and again after ask_days (fails on the old code); the causes barrels / pending / no_room; no question with drink, in a SIEGE, or when it filled in time.

## Live check
DECISION_NEEDED id refuge_dry with `cause` in a PEACE fort whose R0 says refuge_dry for 3+ days.
