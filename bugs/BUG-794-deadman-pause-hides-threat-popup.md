# BUG-794: under the dead-man / park pause a whitelisted popup hides a threat popup

Part of Neuausrichtung 1 / P3; full design, interactions and Live-Erwartung: [docs/v2/NEU1-wecken.md](../docs/v2/NEU1-wecken.md).

- **Symptom (found in verification, offline):** while `owners.pause` was `deadman` or `park`, a whitelisted popup (migrants) stayed on the screen; the arbiter reads only the front popup, so a threat popup queued behind it was never handed to the reflex.
- **Change:** `lua/dfllm/arbiter.lua` `track_pause`: under `deadman`/`park` a whitelisted popup is acknowledged, the game is not unpaused; the threat behind it is then announced (FR-36 order).
- **Test:** tests/lua/test_neu1_deadman.lua 'a whitelisted popup does not unpause the dead-man pause; a threat popup is still handed on'
- **Status:** fixed (offline, live-untested)

## Live-Erwartung
1. While `owners.pause` is `deadman` or `park`, a migrant (whitelisted) popup is acknowledged and the game stays paused (no tick movement until `dfllm cmd resume`).
2. A threat popup queued behind it is announced (ARRIVAL / INTRUDER event in events.jsonl) during the same pause, not only after the resume.
