# BUG-815 building.remove of a door or hatch without approval left an area hold on the perimeter
Status: fixed (NEU1 P7 verification retry, offline, live-untested)
Severity: medium

Package design note (symptom, cause, change, test, Live-Erwartung): [docs/v2/NEU1-notausgang.md](../docs/v2/NEU1-notausgang.md),
section "Verification fixes (retry 1, BUG-812 to BUG-816)". One design note per package replaces the per-bug write-up (Neuausrichtung 1).

## Live-Erwartung
1. `building.remove` of a door or hatch without `approve:true` is refused and leaves no `area:` hold (no later `held by the player (building.remove)` on that footprint).
2. With `approve:true` the door is removed and the kernel's later builds on its tile are refused as held for at most 28 days.
