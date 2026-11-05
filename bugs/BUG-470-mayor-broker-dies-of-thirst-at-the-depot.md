# BUG-470 Run 16d i4 Mazelanterns y410: the mayor died of thirst (>= 61,000) beside 4899 days of drink, job TradeAtDepot
Status: fixed (offline, live-untested); open: a thirsty trader already at the job is not released
Severity: high
Found: 2026-11-05, round 29 notes (`runs/run-16a..16d/FR-BUGS.md`), main 59d6abb
Module: lua/dfllm/act.lua:TR.broker_job, dfpilot/wake.py:_request_access

## Actual
`thirst_unit: 29353 (thirst 54942, hunger 31088, job TradeAtDepot at 63,56,140)`, `PATIENT_DYING` at 61186; the player's note: the kernel looked only for accepted water zones (114 tiles), never at the barrels in the core.

## Root cause (kern.log, i4)
Not the water search. `economy: BROKER appointed: unit 29353 (mayor)` at tick 165442156; the unit was already a patient (thirst 25086 at 165467474). At 165525949 `trade: no TradeAtDepot job ... posted`, at 165526549 `TradeAtDepot job without a worker: assigned` = `act.lua TR.broker_job` gave the dehydrating broker the depot job (`dfhack.job.addWorker`), and the trade timed out in WAIT at 165557749 with the job still on him. A dwarf on that job does not leave to drink. GiveWater needs real water (a wet well or Water Source zone, BUG-434/449): barrels are no water for a GiveWater job, and the 114-tile source was out of the carriers' reach in time. The kernel's own assignment put him out of reach of the barrels.

## Fix
- `TR.broker_job` (assign): a broker with `thirst_timer >= 20000` or `hunger_timer >= 40000` is not assigned (`'broker thirsty or hungry (th/hu)'`, a no-op like 'broker busy'); the job waits until he has eaten and drunk, the visit times out at worst.
- Patients far from water: BUG-469 answers the request (the aquifer cistern, also without a tile); BUG-449 (patients on another walk group) is untouched.

## Not done
A worker already on the TradeAtDepot job is not taken off it (job removal is banned, DESIGN 5.9); GiveWater with barrel drink does not exist in DF; a hospital zone with a well is the BUG-434 cistern.

## Tests
`tests/lua/test_trade_act.lua` (thirsty and hungry broker refused, a fed one assigned).

## Live check
kern.log `trade: TradeAtDepot job without a worker: broker thirsty or hungry (N/M)` while a mayor-broker is a patient; no `thirst_unit` with job TradeAtDepot.
