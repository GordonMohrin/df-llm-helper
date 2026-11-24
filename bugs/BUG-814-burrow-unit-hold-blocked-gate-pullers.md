# BUG-814 burrow.unit held the whole burrow and blocked gate's lever pullers
Status: fixed (NEU1 P7 verification retry, offline, live-untested)
Severity: high

Package design note (symptom, cause, change, test, Live-Erwartung): [docs/v2/NEU1-notausgang.md](../docs/v2/NEU1-notausgang.md),
section "Verification fixes (retry 1, BUG-812 to BUG-816)". One design note per package replaces the per-bug write-up (Neuausrichtung 1).

## Live-Erwartung
1. After a `burrow.unit` in an open exit, gate's lever-room pullers are still added in a BREACH (commands.log `act.burrow_units` by gate `ok`, never `held by the player`).
2. `EMERGENCY_END` gives the changed members their old membership back (`d.burrows` >= 1); pullers gate added meanwhile stay.
