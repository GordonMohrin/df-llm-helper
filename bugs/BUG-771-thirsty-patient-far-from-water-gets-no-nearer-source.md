# BUG-771 a thirsty patient far from accepted water gets only a cistern request: no nearer source, no extra carers
Status: fixed (offline, live-untested)
Severity: high
Found: 2026-11-11, Run 16a i1 Basementflew y534-y538: patient 27129 over thirst 30,000 with '1 GiveWater job running' (#27541..#27624) and the nearest accepted water 91-96 tiles away, dead of thirst y535 spring; patient 31512 (thirst 25-30k, accepted water 46-117 tiles, 'no hospital zone') died y538 (berserk after a failed mood); kern.log 'patient 31348 (thirst 30608) has no accepted water within 40 tiles (nearest 62)'
Module: `lua/dfllm/water.lua` (`M.far_patient`, `M.zone_found`, `M.carers`, run step)

## Actual
With accepted water far from the patient the kernel asked for a cistern (PROJECT_REQUEST, once per 28 days) and sent a decision; the GiveWater carriers walk the whole way and back, so the patient's thirst rose past DF's service point meanwhile. The water the scan had found near the patient was zoned only while NO water was accepted at all (BUG-324).

## Root cause
`lua/dfllm/water.lua` run step: `local wz = wet == 0 and M.zone_found(...)`: the Water Source painter ran only at `wet == 0`; `M.carers` scaled by patient count only.

## Fix
`M.far_patient(c, r)`: the thirstiest patient over `thirst_watch` more than `patient_far` (40) tiles from accepted water (or none). While one exists: (1) the scan is queued if none is fresh; (2) `M.zone_found` runs with a `near` target: only scanned water that lies at least `wz_gain` (15) tiles nearer to the patient than the accepted source, nearest to him first, with every BUG-324 rule (no BREACH, only roofed outside PEACE / RECOVERY, never on the attack path, never cavern water, one zone per `wz_every`, `wz_max` spots per `wz_forget`); the zone is accepted by the next run, so the next GiveWater job fills there; the log / `wz.txt` names the distance; (3) `M.carers` wants `carers_far` (2) more caregivers (at most `carers_max`). `wz_gain` or `patient_far` 0 switches it off.

## Reading of the log (verifier)
kern.log (i1, y534-y538) says for patient 27129: 'has no accepted water within 40 tiles (nearest 91-96); 1 patient(s) over thirst 25000, 0 hospital zone(s): GiveWater needs water, not a zone'. With no hospital zone the fort had no place for the water to be given in; the first cause was BUG-770 (no hospital site). This fix helps only when a hospital exists, scanned safe water lies at least `wz_gain` nearer to the patient, and the zone is accepted in time; at `carers_max` (the log shows 41 carers) it adds nobody. It was not shown to change the Basementflew deaths; the GiveWater job's own route and bucket handling are DF's and unaddressed.

## Open
The scan must have found a safe water body near the patient (a fort with none stays on the cistern request); the carrier's real route and the bucket handling are the game's; the kernel's `served` still holds a hospital zone more than `water.near` from accepted water as dry (the new zone is accepted water, so it counts once the patient is near it). Not run live.

## Tests
`tests/lua/test_bug771_far_patient.lua` (5: the zone near the patient, none when the accepted water is near / the patient not thirsty / in BREACH, `far_patient` and `carers_far`).

## Live check
Next patient over 25,000 with accepted water > 40 tiles away: kern.log 'Water Source zone dfllm-water painted at ... N tiles from patient ...', `inspect water_sources` `wz`, and `carers.want` 2 above the old value.
