# BUG-008 GHOSTS and NO_DEPOT repeat every few game days and drown the stream
Status: fixed in b01bec4, 7006350 (offline, live-untested). Live (677bc3e): PARTLY. GHOSTS fired once in 20 real minutes (#11060); long-term cadence (days) not observed.
Severity: low (noise, but it hides new events; at timestream speed a game week is a few seconds)
Found: 2026-10-15, Run 9 save autosave 1, dfpilot main 3edc277
Module: `lua/dfllm/care.lua` (GHOSTS cadence), trade (NO_DEPOT / DEPOT_MISSING)

## Actual
`follow` woke for GHOSTS again and again with merge counts `x9`, `x14`, `x12`, `x11`, `x31` within 20 real minutes, each time the
same text ("N ghost(s), M citizen(s) unburied > 3 d: no_coffin 24, ..."); NO_DEPOT came with every caravan visit (four visits) and
with `DEPOT_MISSING (one is being built)` although nothing was being built (BUG-005). The documented cadence is "again when the set
grows, else weekly"; weekly is a few seconds at 400 ticks/s.

## Fix proposal
Weekly means wall clock at timestream speed: use `max(7 game days, 10 min wall clock)`; repeat only when the set grew or a cause
changed; one NO_DEPOT per caravan visit, not per frame batch.

Related: FR-38 (wall clock vs game clock), FR-26, BUG-005

## Fix (b01bec4, 7006350, offline)
New `lua/dfllm/util/cadence.lua`: the first announcement of an episode at once; a repeat only when the set grew or a
new cause appeared, and not before max(game cadence, 10 min wall clock) after the last one. Applied to GHOSTS
(ghost_every + `care.wake_wall_s`), MOOD_RISK (mood_risk_every + wall), the coffin DECISION_NEEDED, HOSPITAL_DRY
(new patient or cause), the patient_thirst reminder (wall clock; a fresh crossing still wakes at once), economy's
new `build_blocked` and the preventblocking ask. NO_DEPOT: once per caravan visit (reflex reads plotinfo.caravans);
DEPOT_MISSING was already once per visit. ORDER_BAD is once per order id (no change needed).
Not fixed here (seal.lua belongs to the seal work, BUG-001/002/006): SEAL_LEAK fires on every seal check while the gates
are up and a route remains (periodic check every 7 game days = 21 s at timestream, no signature); REFUGE_FAIL repeats
every game day (`fail_every = DAY`, 3 s at timestream) for the same refusal. Both should use util/cadence (key: the
leak tile / the burrow pair). CUTOFF only fires when the cut count grows (fine).

Also applied (merge, 2026-10-15): SEAL_LEAK (an unchanged leak once per episode, a new leak tile or state at once; the episode ends when sealed) and REFUGE_FAIL (once per refused burrow/fallback/reason, a change after at least max(1 game day, 60 s)) use `util/cadence` too; tests in `tests/lua/test_seal.lua`.
