# BUG-813 the labor hold key per unit blocked care's doctor and water's Orderlies
Status: fixed (NEU1 P7 verification retry, offline, live-untested)
Severity: high

Package design note (symptom, cause, change, test, Live-Erwartung): [docs/v2/NEU1-notausgang.md](../docs/v2/NEU1-notausgang.md),
section "Verification fixes (retry 1, BUG-812 to BUG-816)". One design note per package replaces the per-bug write-up (Neuausrichtung 1).

## Live-Erwartung
1. After `labor.set unit=<u> labor=clean_fish on=true` commands.log shows `held by the player (labor.set)` only for that unit's clean_fish labor, never for care's doctor or water's Orderlies on the same unit.
2. No ACT_FAIL for a held labor call.
