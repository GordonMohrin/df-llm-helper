# NEU2 Bruecke: the kernel's quiet PEACE raise of the inner gate waits for a quiet footprint (BUG-831..833)

Round: Neuausrichtung 2 (2026-11-24). Status: offline, live-untested. Follows docs/v2/NEU1-tore.md (D-14 `inner`).

## Evidence (Run 17d i4 Girderroots, region1-site97, events.jsonl / kern.log)
- Three deaths by the kernel's own PEACE raise of B1: #895 (citizen 26276), #1441 (soldier 26528), #1631 (citizen 26278), all `bridge B1 up ... last seen on it at 65,85,142`.
- Sequence of #1441: `GATE B1 opens for 600 ticks ... (return window)` 151489814; `LEVER pull B1 down`; `B1 down` 151490447; `LEVER pull B1 up` the same tick; pull taken 235 ticks later; `B1 moving` 151490682; `GATE_CRUSH_RISK ... soldier 26528 on the footprint` 151490979; `B1 up` 151490983 ("536 ticks after the pull was queued"); `BRIDGE_CRUSH` 151490983. The unit was NOT on the footprint when the pull was queued or taken (the holders found nobody within the margin or on a readable path) and stepped on during the ~300 ticks the bridge moves.
- 45 raises of B1 in the log, 9 with a unit on the footprint while it moved (20 %), 3 deaths. B1 is the main traffic path.

## Rule
Raise in PEACE only when nothing near the footprint can step on it during the queue-to-up window (measured, 536 ticks in i4): no unit within `gate.peace_clear_r` (20) tiles for `max(gate.peace_clear, latency)` ticks, a pending pull is cancelled for one, a risk locks the bridge down (3 days, doubled, 28 max). A busy inner gate (the main path) therefore stays DOWN in PEACE and goes up on a threat (the pre-NEU1 behaviour); a quiet fort keeps the NEU1 benefit. `gate.peace_raise` false pins the old behaviour. SIEGE/BREACH rules (close at once, crossers, forced raises) are untouched.

## Config
`config/reflex.json` gate: `peace_raise` (true), `peace_clear_r` (20, 2..24), `peace_clear` (600, 0..4800), `peace_lock_days` (3, 0..28). Player: `lever bridge=B1 want=down days=N` (1..120).

## Events
GATE (C) `peace_wait` (why a raise waits, once a game day), `peace_traffic` (a risk locked the bridge: days, n).
