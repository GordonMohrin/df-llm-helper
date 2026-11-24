# BUG-816 a tactical hold ended at a fixed grace end while the exit was still open
Status: fixed (NEU1 P7 verification retry, offline, live-untested)
Severity: medium

Package design note (symptom, cause, change, test, Live-Erwartung): [docs/v2/NEU1-notausgang.md](../docs/v2/NEU1-notausgang.md),
section "Verification fixes (retry 1, BUG-812 to BUG-816)". One design note per package replaces the per-bug write-up (Neuausrichtung 1).

## Live-Erwartung
1. A tactical hold (`squad.station`, `door.lock`) lasts while the emergency exit is open: no `squad.station` order taken back by the kernel before `EMERGENCY_END`.
2. After `EMERGENCY_END` the stationed squads return to the kernel's posture within a step.
