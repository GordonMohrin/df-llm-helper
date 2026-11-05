# BUG-496 A citizen drowns: DEATH says only `drowned`, no place, no cause, five days late
Status: fixed (offline, live-untested)
Severity: high (the first of five brook deaths could have been the only one)
Found: 2026-11-05, Run 16b i2 Brotherarrow y372/y373 (FR-BUGS "Zwei Zwerge ertrunken ohne erkennbare Ursache"; round 31 note "i2 R9")
Module: `lua/dfllm/care.lua` (`drowned_event`, `M.on.UNIT_DEATH`, `death_recheck`), `lua/dfllm/sense.lua` (`M.scene`, `M.water_at`), `dfpilot/schema.py` (DROWNED)

## Actual
The death incident of a drowned citizen stays undiscovered until the body is found: DEATH `unknown (not found yet, missing in the unit list)`, then `drowned (incident DROWN)` days later, class B (digest), with a `pos` but no water tile, no creature, no hint at what to do.

## Fix
- New event DROWNED (A, urgent in dfpilot's wake), emitted when a citizen is found drowned (directly, or as the revised death after "missing"): `pos` of the body, `tile` (`water 5/7`, `beside water 2/7`, `dry`), `stream` (brook/river), `near` (the wild or other units within 8 tiles: race, size, distance, tame) and `cause` = `wild` (the incident names an attacker, or an untamed unit stood near), `water` (deep water, nothing near), `unknown` (no water at the body). The text names the tile and, for `wild`, tells to keep everybody off that water and to sortie the beast.
- An attacker named by the incident of a drowning is marked as a wild danger for sense (`mark_killer`, as for `killed` deaths since BUG-421).
- care reads neither tiles nor the unit list (lint): `sense.water_at` and `sense.scene` answer.
- Not done: a citizen who is still "missing" has no position yet; the event comes when the body is found, together with the DEATH revision.

## Tests
`tests/lua/test_care_deaths.lua` (+2: wild cause with the attacker marked, water cause, dry body unknown, missing then found announced once with `revised`, other causes make none), `tests/test_bug494_496_wild_water.py`.

## Live check
A drowned citizen found in a brook: `dfllm status` / the wake shows `DROWNED` with `pos`, `tile water N/7` and the creature near; kern.log has the DEATH line as before.
