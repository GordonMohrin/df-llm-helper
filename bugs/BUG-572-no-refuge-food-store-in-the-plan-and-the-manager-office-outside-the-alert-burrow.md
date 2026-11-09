# BUG-572 the year plan builds refuge beds and a drink store but no refuge food; the manager's office lies outside the alert burrow and nothing says so
Status: fixed (offline, live-untested)
Severity: high (the cause of BUG-569's empty refuge; no meals cooked for 48 days because nothing was validated)
Found: 2026-11-06, Run 16b i2 Brotherarrow y406 (`runs/run-16b/FR-BUGS.md` "BUG (KRITISCH) SIEGE_DEEP-Refuge Tiefe+ hat 0 Essen", "Hungertod-Welle", "Patient 27722 verdurstet", "Manager Onget validiert 48 Tage nichts")
Module: `dfpilot/bp/rooms.py` (`refuge_drink` food=1, `refuge_store_n`), `dfpilot/plan.py` (`refuge_food_short`, `refuge_food_draft`, `refuge_food_gate`, `request_drafts`, `refuge_projects`), `lua/dfllm/seal.lua` (state `alert.ref.fd/fn`), `lua/dfllm/economy.lua` (`office_gap`, `unval_why`, `manager_facts`)

## Actual
The plan built `refuge_beds` and `refuge_drink` for Tiefe+, never food; `plan check` said nothing about a refuge with food 1. The manager (Onget) sat at the stair head in the refuge; his Office zone 17764 (82-84,124-126 z137) lay outside Tiefe+, so nine orders (MakeWeapon x4, ProcessPlants, MakeCharcoal, MakeAmmo) stood unvalidated for 48 days and `inspect what=manager` said `cause: nothing the kernel can read is wrong`; a `zone.place type=office` in the refuge had no furniture command.

## Root cause
- `rooms.refuge_drink` (rooms.py:606-621) always made a drink-only pile (`:=booze`); no template or plan rule existed for refuge food, and `plan.request_drafts` / `plan.check` knew only `refuge_dry` (drink).
- `economy.unval_why` / `manager_facts` knew the office's furniture and a walking path, never the civ alert's burrows: `snapshot.reach` does not see a burrow confinement.

## Fix
- `refuge_drink` takes `food` 1 (rooms.py): the same room and pile name `dfllm-drink`, but the pile keeps the stockroom's food default (no `:=booze`), sized by `refuge_store_n(citizens)` = ceil((drink units + citizens x food_per_cit) / 5) up to 40 barrels (`n` max 40; the drink-only store stays at 24); the manifest room id ends in `_food`.
- seal publishes the refuge's food and the food wanted (`alert.ref.fd`, `fn`). `plan.refuge_food_short` (food under `refuge.deep_pct` % = the point where BUG-569 refuses the refuge), `plan.refuge_food_gate` (a `plan check` warning with the draft: `holds food 1<52 ... add {"tpl":"refuge_drink","site":"S1","p":{"n":21,"food":1}}`), `plan.refuge_food_draft` and `request_drafts` (`plan propose` drafts it once; a drink store drafted at the same time becomes the food and drink store); a standing / under-way food store (`fort.refuge.food`, `food_room`) silences both.
- `economy.office_gap` (the civ alert sounds, the unit stands in one of its burrows, no tile of his office zone lies in any): `unval_why` (the `manager_office` DECISION after `orders.unval_days`, 2 days, long before the 48) and `inspect what=manager` name it: `the civ alert holds the manager in Tiefe+ and his office zone N lies outside it`, with the fix (an office inside the burrow; the starvation relief of BUG-570 also widens the burrow).
- Not done: the `office` template does not yet place the furniture for a refuge office; `plan propose` does not draft an office in the refuge.

## Tests
`tests/test_bug569_572_f36.py`: store sizing, `food=1` layout (no booze preset, room id `_food`, 40 barrels fit, 41 refused), `refuge_food_short` thresholds, `plan check` warning text and its silencers, `refuge_food_draft`, `request_drafts` (food store alone, folded into a refuge_dry drink store, nothing for a fed refuge). `tests/lua/test_bug569_572_seal.lua`: `alert.ref.fd/fn`. `tests/lua/test_manager_bypass.lua`: the decision and `inspect manager` name the alert and the office; alert off or office inside: no such cause.

## Live check
`dfllm plan check` with a refuge that holds little food: the warning with the `refuge_drink food=1` draft; `plan propose` drafts it; `bp sites refuge_drink n=21 food=1` finds a room. In a long siege with the manager in the refuge: `inspect what=manager` names the burrow and the office.
