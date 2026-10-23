# BUG-082 A parked lever (BUG-068) still counts as a pull to wait for: the lockdown's civ alert waits up to 1500 ticks for it
Status: fixed in the I2 commit (offline, live-untested): `gate.lua` `NO_PULL.no_effect`; `gate.pulls()` counts the bridge in
`parked`, not in `left`
Severity: high (the alert of a lockdown sounds up to 1500 ticks late, citizens outside keep working while an invader comes)
Found: 2026-10-23, integration audit I2 (C2 BUG-068 against BUG-013)
Module: `lua/dfllm/gate.lua` (`NO_PULL`, `needs_pull`, `M.pulls`), read by `lua/dfllm/reflex.lua` (`alert_due`)

## Actual
BUG-068 parks a lever that was pulled `noeffect_max` times without moving its bridge (`r.park`) and the control pass then sets
`r.stuck = 'no_effect'`. `needs_pull` returned false for `no_lever`, `blocked`, `guard` and `manual` only, so `gate.pulls().left`
still counted the bridge. The reflex lockdown defers its civ alert while `left > 0` (BUG-013) up to its deadline
(`ALERT_LAT` x the last lever latency, 450..1500 ticks, 900 before the first measurement). With every lever of every wanted bridge
parked (300 ticks in a fight, 1200 in PEACE, doubling per parking up to 8x) nothing was going to be pulled, yet the alert waited
for the deadline; the gates line said "N pulls pending". The lever room `Hebel+` was listed for pulls that were not made.

## Cause
`needs_pull` (`gate.lua:676`, 9bcb14f) was written before the parking; C2's `no_effect` stuck state was never added to `NO_PULL`.

## Fix
`NO_PULL.no_effect = true`; `M.pulls()` counts such a bridge in the new optional `parked` (CONTRACTS `gate.pulls()` row). When
the park ends the next pass pulls again and `left` counts it again (the alert waits for a pull that is made).

## Tests
`tests/lua/test_i2_gate_parked.lua` (the siege world of `test_gate_noeffect.lua`: three bridges, every lever parked: `left` 0,
`parked` 3; 300 ticks later the park is over and `left` is 3 again). Fails on 9bcb14f.

## Related
BUG-013, BUG-068, FR-75
