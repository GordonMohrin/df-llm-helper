# BUG-812 door.lock could leave an entrance door forbidden for good
Status: fixed (NEU1 P7 verification retry 1 and retry 2 fail closed, offline, live-untested)
Severity: critical

Package design note (symptom, cause, change, test, Live-Erwartung): [docs/v2/NEU1-notausgang.md](../docs/v2/NEU1-notausgang.md),
section "Verification fixes (retry 1, BUG-812 to BUG-816)". One design note per package replaces the per-bug write-up (Neuausrichtung 1).

Retry 2 (second verification: the close unlocked the player's door under a reflex lockdown / in SIEGE, `door.lock on=false`
overrode a lockdown, a player unlock's hold blocked the next lockdown): section "Verification fixes (retry 2, BUG-812 fail
closed)" of the design note. Undo only in PEACE without a lockdown (else kept and retried), unlock refused then, no door hold.
